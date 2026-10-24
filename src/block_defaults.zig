//! Vanilla defaults from https://github.com/misode/mcmeta, generated upstream
//! from Mojang's block reports. Catalogs are pinned to a commit and DataVersion,
//! cached atomically, and immutable for the duration of a render. No game data
//! or Java tooling is bundled with Vantage.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const max_bytes = 8 * 1024 * 1024;
const index_url = "https://raw.githubusercontent.com/misode/mcmeta/summary/versions/data.min.json";

pub const Fetcher = struct {
    context: ?*anyopaque = null,
    fetch: *const fn (?*anyopaque, Allocator, Io, []const u8) anyerror![]const u8 = httpGet,
};

pub const Warning = struct { data_version: i32, reason: anyerror, block: ?[]const u8 = null };
pub const Reporter = struct {
    context: ?*anyopaque = null,
    emit: *const fn (?*anyopaque, Warning) void = reportWarning,
};

fn reportWarning(_: ?*anyopaque, warning: Warning) void {
    if (warning.block) |block| {
        std.debug.print("warning: no verified default state for {s} (DataVersion {d}); using model fallback; orientation may be incorrect.\n", .{ block, warning.data_version });
    } else {
        std.debug.print("warning: mcmeta block defaults for DataVersion {d} unavailable ({s}); using model fallback; compact blocks may have incorrect orientations. Retry rendering when the registry is available.\n", .{ warning.data_version, @errorName(warning.reason) });
    }
}

const Block = struct { state: []const u8, pairs: [][]const u8 };

pub const Catalog = struct {
    blocks: std.StringHashMapUnmanaged(Block) = .empty,

    /// Validate the upstream [allowed properties, default properties] schema.
    pub fn parse(a: Allocator, bytes: []const u8) !Catalog {
        const root = try parseJson(a, bytes);
        if (root != .object or root.object.count() == 0) return error.InvalidRegistry;
        var out: Catalog = .{};
        var entries = root.object.iterator();
        while (entries.next()) |entry| {
            const name = entry.key_ptr.*;
            const pair = entry.value_ptr.*;
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, ':') != null or pair != .array or pair.array.items.len != 2) return error.InvalidRegistry;
            const allowed = pair.array.items[0];
            const defaults = pair.array.items[1];
            if (allowed != .object or defaults != .object or allowed.object.count() != defaults.object.count()) return error.InvalidRegistry;
            var props: std.ArrayList([]const u8) = .empty;
            var fields = defaults.object.iterator();
            while (fields.next()) |field| {
                const key = field.key_ptr.*;
                const val = field.value_ptr.*;
                if (!propertyToken(key) or val != .string or !propertyToken(val.string)) return error.InvalidRegistry;
                const choices = allowed.object.get(key) orelse return error.InvalidRegistry;
                if (choices != .array or choices.array.items.len == 0) return error.InvalidRegistry;
                var found = false;
                for (choices.array.items) |choice| {
                    if (choice != .string or !propertyToken(choice.string)) return error.InvalidRegistry;
                    if (std.mem.eql(u8, choice.string, val.string)) found = true;
                }
                if (!found) return error.InvalidRegistry;
                try props.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ key, val.string }));
            }
            std.mem.sort([]const u8, props.items, {}, less);
            try out.blocks.put(a, name, .{ .state = try std.mem.join(a, ",", props.items), .pairs = try props.toOwnedSlice(a) });
        }
        return out;
    }

    /// Explicit properties always win. A complete explicit state needs no copy.
    /// null distinguishes an unknown block from a known stateless block ("").
    pub fn expand(self: *const Catalog, a: Allocator, name: []const u8, explicit: []const u8) Allocator.Error!?[]const u8 {
        const id = if (std.mem.startsWith(u8, name, "minecraft:")) name[10..] else name;
        const block = self.blocks.get(id) orelse return null;
        if (explicit.len == 0) return block.state;
        var missing: std.ArrayList([]const u8) = .empty;
        for (block.pairs) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=').?;
            var supplied = false;
            var fields = std.mem.splitScalar(u8, explicit, ',');
            while (fields.next()) |field| {
                const split = std.mem.indexOfScalar(u8, field, '=') orelse continue;
                if (std.mem.eql(u8, field[0..split], pair[0..eq])) {
                    supplied = true;
                    break;
                }
            }
            if (!supplied) try missing.append(a, pair);
        }
        if (missing.items.len == 0) return explicit;
        var fields = std.mem.splitScalar(u8, explicit, ',');
        while (fields.next()) |field| try missing.append(a, field);
        std.mem.sort([]const u8, missing.items, {}, less);
        return try std.mem.join(a, ",", missing.items);
    }
};

fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn propertyToken(s: []const u8) bool {
    return s.len != 0 and std.mem.indexOfAny(u8, s, ",=") == null;
}

fn parseJson(a: Allocator, bytes: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
}

fn stringField(value: Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidRegistry;
    const field = value.object.get(name) orelse return error.InvalidRegistry;
    if (field != .string) return error.InvalidRegistry;
    return field.string;
}

fn integerField(value: Value, name: []const u8) !i64 {
    if (value != .object) return error.InvalidRegistry;
    const field = value.object.get(name) orelse return error.InvalidRegistry;
    if (field != .integer) return error.InvalidRegistry;
    return field.integer;
}

fn validVersion(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".-_+", c) == null) return false;
    return true;
}

fn validCommit(commit: []const u8) bool {
    if (commit.len != 40) return false;
    for (commit) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn checksum(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const Cache = struct {
    format: u32 = 1,
    data_version: i32,
    minecraft_version: []const u8,
    commit: []const u8,
    sha256: []const u8,
    blocks_json: []const u8,
};

pub const Store = struct {
    io: Io,
    /// Externally owned; must outlive this store.
    cache_root: []const u8,
    fetcher: Fetcher = .{},
    reporter: Reporter = .{},
    timeout: Io.Duration = .fromSeconds(30),
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    mutex: Io.Mutex = .init,
    catalogs: std.AutoHashMapUnmanaged(i32, ?*const Catalog) = .empty,
    unknown: std.StringHashMapUnmanaged(void) = .empty,
    version_index: ?Value = null,

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// One attempt per version per run, including failures. Protects the arena
    /// and first-use download from all tile workers; returned catalogs are immutable.
    pub fn catalog(self: *Store, data_version: i32) Allocator.Error!?*const Catalog {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.catalogs.get(data_version)) |cached| return cached;
        const result = self.loadWithDeadline(data_version) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                self.reporter.emit(self.reporter.context, .{ .data_version = data_version, .reason = err });
                break :blk null;
            },
        };
        try self.catalogs.put(self.arena.allocator(), data_version, result);
        return result;
    }

    pub fn warnUnknown(self: *Store, data_version: i32, name: []const u8) Allocator.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var buf: [1024]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{d}:{s}", .{ data_version, name }) catch return;
        if (self.unknown.contains(key)) return;
        try self.unknown.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, key), {});
        self.reporter.emit(self.reporter.context, .{ .data_version = data_version, .reason = error.UnknownBlock, .block = name });
    }

    fn loadWithDeadline(self: *Store, data_version: i32) anyerror!*const Catalog {
        const Result = union(enum) { loaded: anyerror!*const Catalog, timeout: Io.Cancelable!void };
        var buffer: [2]Result = undefined;
        var select = Io.Select(Result).init(self.io, &buffer);
        defer select.cancelDiscard();
        // concurrent (rather than async) prevents a blocking implementation
        // from running the download inline before the timeout can be observed.
        try select.concurrent(.timeout, Io.sleep, .{ self.io, self.timeout, .awake });
        try select.concurrent(.loaded, load, .{ self, data_version });
        return switch (try select.await()) {
            .loaded => |result| result,
            .timeout => error.RegistryTimeout,
        };
    }

    fn readCache(self: *Store, data_version: i32, path: []const u8, scratch: Allocator) !*const Catalog {
        const bytes = try Io.Dir.cwd().readFileAlloc(self.io, path, scratch, .limited(max_bytes));
        const cache = try std.json.parseFromSliceLeaky(Cache, scratch, bytes, .{});
        if (cache.format != 1 or cache.data_version != data_version or !validVersion(cache.minecraft_version) or !validCommit(cache.commit)) return error.InvalidRegistryCache;
        const hash = checksum(cache.blocks_json);
        if (!std.mem.eql(u8, &hash, cache.sha256)) return error.InvalidRegistryCache;
        const result = try self.arena.allocator().create(Catalog);
        result.* = try Catalog.parse(self.arena.allocator(), cache.blocks_json);
        return result;
    }

    fn get(self: *Store, a: Allocator, url: []const u8) ![]const u8 {
        return self.fetcher.fetch(self.fetcher.context, a, self.io, url);
    }

    fn version(self: *Store, scratch: Allocator, data_version: i32) ![]const u8 {
        if (self.version_index == null) {
            const bytes = try self.get(scratch, index_url);
            self.version_index = try parseJson(self.arena.allocator(), bytes);
        }
        const index = self.version_index.?;
        if (index != .array) return error.InvalidVersionIndex;
        var found: ?[]const u8 = null;
        for (index.array.items) |entry| {
            if (try integerField(entry, "data_version") != data_version) continue;
            const id = try stringField(entry, "id");
            if (!validVersion(id)) return error.InvalidVersionIndex;
            if (found != null and !std.mem.eql(u8, found.?, id)) return error.AmbiguousDataVersion;
            found = id;
        }
        return found orelse error.UnknownDataVersion;
    }

    fn load(self: *Store, data_version: i32) anyerror!*const Catalog {
        var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_arena.deinit();
        const a = scratch_arena.allocator();
        const cwd = Io.Dir.cwd();
        const path = try std.fmt.allocPrint(a, "{s}/{d}.json", .{ self.cache_root, data_version });
        if (self.readCache(data_version, path, a)) |cached| return cached else |err| if (err == error.OutOfMemory) return err;
        try cwd.createDirPath(self.io, self.cache_root);
        const lock_path = try std.fmt.allocPrint(a, "{s}/{d}.lock", .{ self.cache_root, data_version });
        var lock = try cwd.createFile(self.io, lock_path, .{ .truncate = false });
        defer lock.close(self.io);
        try lock.setLength(self.io, 1);
        try lock.lock(self.io, .exclusive);
        // Another Vantage process may have published while we waited.
        if (self.readCache(data_version, path, a)) |cached| return cached else |err| if (err == error.OutOfMemory) return err;

        const id = try self.version(a, data_version);
        const commit_url = try std.fmt.allocPrint(a, "https://api.github.com/repos/misode/mcmeta/commits/{s}-summary", .{id});
        const commit_doc = try parseJson(a, try self.get(a, commit_url));
        const commit = try stringField(commit_doc, "sha");
        if (!validCommit(commit)) return error.InvalidRegistryCommit;
        const base = try std.fmt.allocPrint(a, "https://raw.githubusercontent.com/misode/mcmeta/{s}", .{commit});
        const meta = try parseJson(a, try self.get(a, try std.fmt.allocPrint(a, "{s}/version.json", .{base})));
        if (try integerField(meta, "data_version") != data_version or !std.mem.eql(u8, try stringField(meta, "id"), id)) return error.RegistryVersionMismatch;
        const blocks = try self.get(a, try std.fmt.allocPrint(a, "{s}/blocks/data.min.json", .{base}));
        const result = try self.arena.allocator().create(Catalog);
        result.* = try Catalog.parse(self.arena.allocator(), blocks);
        const hash = checksum(blocks);
        const envelope = try std.json.Stringify.valueAlloc(a, Cache{
            .data_version = data_version,
            .minecraft_version = id,
            .commit = commit,
            .sha256 = &hash,
            .blocks_json = blocks,
        }, .{});
        const staging = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
        defer cwd.deleteFile(self.io, staging) catch {};
        try cwd.writeFile(self.io, .{ .sub_path = staging, .data = envelope });
        try cwd.rename(staging, cwd, path, self.io);
        return result;
    }
};

fn httpGet(_: ?*anyopaque, a: Allocator, io: Io, url: []const u8) ![]const u8 {
    // Client connection/CA bookkeeping requires a thread-safe allocator;
    // the response body alone belongs to the caller's scratch arena.
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .not_allowed,
        .headers = .{ .user_agent = .{ .override = "vantage-mc block-defaults" }, .accept_encoding = .{ .override = "identity" } },
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    switch (response.head.status) {
        .ok => {},
        .not_found => return error.RegistryNotPublished,
        .too_many_requests, .forbidden => return error.RegistryRateLimited,
        else => return error.RegistryHttpStatus,
    }
    var transfer: [8192]u8 = undefined;
    return try response.reader(&transfer).allocRemaining(a, .limited(max_bytes));
}

const test_registry = @embedFile("testdata/block_defaults.json");

test "verified defaults merge explicit overrides and distinguish stateless or unknown blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const registry = try Catalog.parse(a, test_registry);
    const cases = [_]struct { name: []const u8, explicit: []const u8 = "", expected: []const u8 }{
        .{ .name = "minecraft:oak_log", .expected = "axis=y" },
        .{ .name = "deepslate", .expected = "axis=y" },
        .{ .name = "oak_log", .explicit = "axis=x", .expected = "axis=x" },
        .{ .name = "oak_stairs", .explicit = "facing=east,waterlogged=true", .expected = "facing=east,half=bottom,shape=straight,waterlogged=true" },
        .{ .name = "oak_fence", .expected = "east=false,north=false,south=false,waterlogged=false,west=false" },
        .{ .name = "chest", .expected = "facing=north,type=single,waterlogged=false" },
        .{ .name = "red_bed", .expected = "facing=north,occupied=false,part=foot" },
        .{ .name = "water", .expected = "level=0" },
        .{ .name = "conduit", .expected = "waterlogged=true" },
        .{ .name = "stone", .expected = "" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, (try registry.expand(a, case.name, case.explicit)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try registry.expand(a, "mod:oak_log", ""));
    try std.testing.expectEqual(@as(?[]const u8, null), try registry.expand(a, "minecraft:unknown", ""));
}

test "registry rejects malformed schemas and impossible defaults" {
    const invalid = [_][]const u8{
        "{}",                                              "[]",                               "{\"stone\":{}}",                               "{\"stone\":[{},{} ,{}]}",
        "{\"log\":[{\"axis\":[\"x\"]},{\"axis\":\"y\"}]}", "{\"log\":[{}, {\"axis\":\"x\"}]}", "{\"log\":[{\"axis\":[1]}, {\"axis\":\"x\"}]}",
    };
    for (invalid) |bytes| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidRegistry, Catalog.parse(arena.allocator(), bytes));
    }
}

const TestSource = struct {
    calls: usize = 0,
    warnings: usize = 0,
    reason: ?anyerror = null,
    mode: enum { ok, offline, mismatch, malformed, slow } = .ok,

    fn fetch(ctx: ?*anyopaque, a: Allocator, io: Io, url: []const u8) ![]const u8 {
        const self: *TestSource = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        switch (self.mode) {
            .offline => return error.NetworkUnavailable,
            .slow => try Io.sleep(io, .fromSeconds(60), .awake),
            else => {},
        }
        const bytes = if (std.mem.eql(u8, url, index_url))
            "[{\"id\":\"26.3\",\"data_version\":5023}]"
        else if (std.mem.endsWith(u8, url, "/commits/26.3-summary"))
            "{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"
        else if (std.mem.endsWith(u8, url, "/version.json"))
            (if (self.mode == .mismatch) "{\"id\":\"26.3\",\"data_version\":5024}" else "{\"id\":\"26.3\",\"data_version\":5023}")
        else if (std.mem.endsWith(u8, url, "/blocks/data.min.json"))
            (if (self.mode == .malformed) "{}" else test_registry)
        else
            return error.UnexpectedUrl;
        // Both files must be fetched from the pinned commit, never summary/latest.
        if (std.mem.endsWith(u8, url, "/version.json") or std.mem.endsWith(u8, url, "/blocks/data.min.json"))
            try std.testing.expect(std.mem.indexOf(u8, url, "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/") != null);
        return try a.dupe(u8, bytes);
    }

    fn warn(ctx: ?*anyopaque, warning: Warning) void {
        const self: *TestSource = @ptrCast(@alignCast(ctx.?));
        self.warnings += 1;
        self.reason = warning.reason;
    }

    fn store(self: *TestSource, root: []const u8) Store {
        return .{ .io = std.testing.io, .cache_root = root, .fetcher = .{ .context = self, .fetch = fetch }, .reporter = .{ .context = self, .emit = warn } };
    }
};

test "cache is reusable offline and corruption is repaired atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var source: TestSource = .{};
    {
        var store = source.store(path);
        defer store.deinit();
        const first = (try store.catalog(5023)).?;
        try std.testing.expect(first == (try store.catalog(5023)).?);
        try std.testing.expectEqual(@as(usize, 4), source.calls);
        try std.testing.expectEqual(@as(usize, 0), source.warnings);
    }
    source = .{ .mode = .offline };
    {
        var store = source.store(path);
        defer store.deinit();
        try std.testing.expect(try store.catalog(5023) != null);
        try std.testing.expectEqual(@as(usize, 0), source.calls);
    }
    // A syntactically valid envelope with a modified payload must not be used.
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "5023.json", std.testing.allocator, .limited(max_bytes));
    defer std.testing.allocator.free(bytes);
    const index = std.mem.indexOf(u8, bytes, "axis").?;
    bytes[index] = 'X';
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "5023.json", .data = bytes });
    source = .{};
    {
        var store = source.store(path);
        defer store.deinit();
        try std.testing.expect(try store.catalog(5023) != null);
        try std.testing.expectEqual(@as(usize, 4), source.calls);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "5023.json.tmp", .{}));
}

test "unavailable, wrong-version and invalid registries warn once and do not retry" {
    for ([_]@FieldType(TestSource, "mode"){ .offline, .mismatch, .malformed }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root: [std.fs.max_path_bytes]u8 = undefined;
        const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
        var source: TestSource = .{ .mode = mode };
        var store = source.store(path);
        defer store.deinit();
        try std.testing.expectEqual(@as(?*const Catalog, null), try store.catalog(5023));
        const calls = source.calls;
        for (0..8) |_| try std.testing.expectEqual(@as(?*const Catalog, null), try store.catalog(5023));
        try std.testing.expectEqual(calls, source.calls);
        try std.testing.expectEqual(@as(usize, 1), source.warnings);
        try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "5023.json", .{}));
    }
}

test "retrieval deadline cancels stalled work and retains fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var source: TestSource = .{ .mode = .slow };
    var store = source.store(path);
    defer store.deinit();
    store.timeout = .fromMilliseconds(10);
    try std.testing.expectEqual(@as(?*const Catalog, null), try store.catalog(5023));
    try std.testing.expectEqual(error.RegistryTimeout, source.reason.?);
    try std.testing.expectEqual(@as(usize, 1), source.warnings);
}

test "unknown versions and unknown namespaces retain fallback and warn only once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var source: TestSource = .{};
    var store = source.store(path);
    defer store.deinit();
    try std.testing.expectEqual(@as(?*const Catalog, null), try store.catalog(999999));
    try std.testing.expectEqual(error.UnknownDataVersion, source.reason.?);
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    _ = try store.catalog(999999);
    try std.testing.expectEqual(@as(usize, 1), source.warnings);
    const catalog = (try store.catalog(5023)).?;
    try std.testing.expectEqual(@as(?[]const u8, null), try catalog.expand(std.testing.allocator, "mod:oak_log", ""));
    for (0..3) |_| try store.warnUnknown(5023, "mod:oak_log");
    try std.testing.expectEqual(@as(usize, 2), source.warnings);
}

test "concurrent workers share one immutable catalog and one download" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var source: TestSource = .{};
    var store = source.store(path);
    defer store.deinit();
    const Worker = struct {
        fn run(s: *Store, result: *?*const Catalog) void {
            result.* = s.catalog(5023) catch unreachable;
        }
    };
    var results: [4]?*const Catalog = @splat(null);
    var threads: [4]std.Thread = undefined;
    for (&threads, &results) |*thread, *result| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &store, result });
    for (threads) |thread| thread.join();
    for (results) |result| try std.testing.expect(result != null and result == results[0]);
    try std.testing.expectEqual(@as(usize, 4), source.calls);
}
