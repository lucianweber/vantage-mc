import * as THREE from 'three';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { LOWRES_EMPTY, type LowresLevel, type ManifestTile, type WorldManifest } from '../src/core/index.js';
import { TileManager, type TileManagerOptions } from '../src/three/tiles.js';

function manifest(extra: Partial<WorldManifest> = {}): WorldManifest {
  return {
    format: 6,
    tileChunks: 8,
    tileBlocks: 128,
    textures: 'terrain.vtexarr',
    biomes: [''],
    tiles: [],
    ...extra,
  };
}

/** A manager with no renderer (so no map memory) and no real GPU work — enough
 *  to exercise catalog reconciliation, which is pure bookkeeping. */
function manager(m: WorldManifest, options: Partial<TileManagerOptions> = {}): TileManager {
  return new TileManager({
    manifest: m,
    fetch: async () => new ArrayBuffer(0),
    scene: new THREE.Scene(),
    material: new THREE.ShaderMaterial(),
    waterMaterial: new THREE.ShaderMaterial(),
    lowresMaterial: new THREE.ShaderMaterial(),
    palette: [],
    ...options,
  });
}

function lowTile(x: number, z: number, revision: string): ManifestTile {
  return { x, z, path: `tiles/l1.${x}.${z}.vlr`, bytes: 1024, revision };
}

function level(tiles: ManifestTile[], lvl = 1): { grid: number; levels: LowresLevel[] } {
  return { grid: 129, levels: [{ level: lvl, tileBlocks: 128 * 2 ** lvl, span: 2 ** lvl, tiles }] };
}

describe('lowres pyramid reconciliation', () => {
  it('adopts a pyramid that appears mid-session, then stays quiet', () => {
    const tiles = manager(manifest({ dynamic: true, rendering: true }));
    // A live session's first manifests carry no pyramid at all.
    expect(tiles.syncLowres({ grid: 129, levels: [] })).toBe(false);

    expect(tiles.syncLowres(level([lowTile(0, 0, 'a1')]))).toBe(true);
    // Re-publishing the same overview must not churn the rings.
    expect(tiles.syncLowres(level([lowTile(0, 0, 'a1')]))).toBe(false);
  });

  it('notices new coordinates, rebuilt tiles, and coordinates that left', () => {
    const tiles = manager(manifest({ dynamic: true, rendering: true }));
    tiles.syncLowres(level([lowTile(0, 0, 'a1')]));

    // The pyramid grew as more of the world baked.
    expect(tiles.syncLowres(level([lowTile(0, 0, 'a1'), lowTile(1, 0, 'b1')]))).toBe(true);
    // One tile was rebuilt over newly baked terrain (same size, new content).
    expect(tiles.syncLowres(level([lowTile(0, 0, 'a2'), lowTile(1, 0, 'b1')]))).toBe(true);
    expect(tiles.syncLowres(level([lowTile(0, 0, 'a2'), lowTile(1, 0, 'b1')]))).toBe(false);
    // …and a coordinate disappeared (a shrinking world).
    expect(tiles.syncLowres(level([lowTile(0, 0, 'a2')]))).toBe(true);
  });

  it('falls back to size when a pyramid carries no fingerprints', () => {
    // A batch render's pyramid never changes and omits `revision`.
    const tiles = manager(manifest());
    const plain = (bytes: number): ManifestTile => ({ x: 0, z: 0, path: 'tiles/l1.0.0.vlr', bytes });
    expect(tiles.syncLowres(level([plain(10)]))).toBe(true);
    expect(tiles.syncLowres(level([plain(10)]))).toBe(false);
    expect(tiles.syncLowres(level([plain(20)]))).toBe(true);
  });

  it('keeps map memory on a live world but retires it for a finished bake', () => {
    // Without a renderer there is no impostor layer to inspect directly; what
    // is observable is that ingesting a pyramid stays safe either way and the
    // levels land.
    const live = manager(manifest({ dynamic: true, rendering: true }));
    live.ingestLowres(level([lowTile(0, 0, 'a1')]));
    expect(live.stats.lowres).toBe(0); // nothing resident yet, but indexed
    expect(live.syncLowres(level([lowTile(0, 0, 'a1')]))).toBe(false);

    const baked = manager(manifest());
    baked.ingestLowres(level([lowTile(0, 0, 'a1')]));
    expect(baked.syncLowres(level([lowTile(0, 0, 'a1')]))).toBe(false);
  });
});

function deferredTile() {
  let resolve!: (buffer: ArrayBuffer) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<ArrayBuffer>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

/** A real VLR1 payload; sparse samples can decode successfully without forming
 *  any complete quad, as happens around the End's isolated islands. */
function overview(ref: ManifestTile, lvl: number, kind: 'solid' | 'sparse' | 'empty' = 'solid'): ArrayBuffer {
  const width = 129;
  const count = width * width;
  const buffer = new ArrayBuffer(Math.ceil((28 + count * 5) / 4) * 4);
  const view = new DataView(buffer);
  new Uint8Array(buffer, 0, 4).set([86, 76, 82, 49]); // VLR1
  view.setUint32(4, 1, true);
  view.setUint32(8, width, true);
  view.setUint32(12, width, true);
  view.setInt32(16, ref.x * 128 * 2 ** lvl, true);
  view.setInt32(20, ref.z * 128 * 2 ** lvl, true);
  view.setUint32(24, 2 ** lvl, true);
  const heights = new Int16Array(buffer, 28, count);
  heights.fill(kind === 'solid' ? 64 : LOWRES_EMPTY);
  if (kind === 'sparse') heights[0] = 64;
  new Uint8Array(buffer, 28 + count * 2, count * 3).fill(128);
  return buffer;
}

function overviewRef(lvl: number, x: number, z: number): ManifestTile {
  return { x, z, path: `tiles/l${lvl}.${x}.${z}.vlr`, bytes: 1024, revision: 'v1' };
}

/** Finish asynchronous fetch/parse work, then advance the public frame loop. */
async function tick(tiles: TileManager): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, 0));
  tiles.update(0, 0);
}

describe('resolved empty tile coverage', () => {
  let now = 0;
  const managers: TileManager[] = [];

  beforeEach(() => {
    now = 0;
    vi.spyOn(performance, 'now').mockImplementation(() => now);
  });

  afterEach(() => {
    for (const tiles of managers.splice(0)) tiles.dispose();
    vi.restoreAllMocks();
  });

  async function fixture(hires = false) {
    const fine = deferredTile();
    const scene = new THREE.Scene();
    const parent = overviewRef(hires ? 1 : 4, hires ? 0 : -1, 0);
    const child = hires
      ? { x: 0, z: 0, path: 'tiles/t.0.0.vtile', bytes: 1024, revision: 'v1' }
      : overviewRef(1, -3, 2);
    // The intermediate LOD tiles sit inside the scheduler's annular gaps:
    // coverage must propagate through their indices without loading meshes.
    const levels = hires ? level([parent]).levels : [
      ...level([child]).levels,
      ...level([overviewRef(2, -2, 1)], 2).levels,
      ...level([overviewRef(3, -1, 0)], 3).levels,
      ...level([parent], 4).levels,
    ];
    const fetch = vi.fn(async (path: string) => {
      if (path === parent.path) return overview(parent, hires ? 1 : 4);
      if (path === child.path) return fine.promise;
      throw new Error(`Unexpected request: ${path}`);
    });
    const tiles = manager(manifest({
      // The distant hires tile prevents the empty LOD's area from already
      // counting as covered merely because all children are absent.
      tiles: [hires ? child : { x: -6, z: 5, path: 'distant.vtile', bytes: 1024 }],
      lowres: { grid: 129, levels },
    }), { scene, fetch });
    managers.push(tiles);
    tiles.update(0, 0);
    await tick(tiles);
    expect(scene.children).toHaveLength(1);
    const coarse = scene.children[0]!;
    now += TileManager.FADE_MS + 1;
    tiles.update(0, 0);
    expect(coarse.visible).toBe(true);
    return { tiles, scene, coarse, parent, child, levels, fine, fetch };
  }

  it.each(['sparse', 'empty'] as const)('hides coarse ancestors after the last tile resolves with %s geometry', async (kind) => {
    const { tiles, scene, coarse, parent, child, fine, fetch } = await fixture();
    const changed = vi.fn();
    tiles.on('change', changed);
    expect(tiles.stats.loading).toBe(1); // prime the cached loading count

    fine.resolve(overview(child, 1, kind));
    await tick(tiles);

    expect(coarse.visible).toBe(false);
    expect(scene.children).toHaveLength(1); // no mesh or extra LOD requests needed
    expect(tiles.stats).toMatchObject({ loaded: 0, lowres: 1, loading: 0 });
    expect(changed).toHaveBeenCalledWith(expect.objectContaining({ loading: 0 }));
    now += 10000; // completed empty tiles must not enter the retry sweep
    for (let i = 0; i < 3; i++) tiles.update(0, 0);
    expect(fetch.mock.calls.map(([path]) => path).sort()).toEqual([child.path, parent.path].sort());
  });

  it('counts an empty live hires response as resolved and refreshes loading statistics', async () => {
    const { tiles, coarse, child, fine, fetch } = await fixture(true);
    const changed = vi.fn();
    tiles.on('change', changed);
    expect(tiles.stats.loading).toBe(1);
    fine.resolve(new ArrayBuffer(0));
    await tick(tiles);
    expect(coarse.visible).toBe(false);
    expect(tiles.stats).toMatchObject({ loaded: 0, lowres: 1, loading: 0 });
    expect(changed).toHaveBeenCalledWith(expect.objectContaining({ loading: 0 }));
    tiles.update(0, 0);
    expect(fetch.mock.calls.filter(([path]) => path === child.path)).toHaveLength(1);
  });

  it('keeps the coarse fallback while a finer tile is pending or failed', async () => {
    const { tiles, coarse, fine } = await fixture();
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect(coarse.visible).toBe(true);
    fine.reject(new Error('network unavailable'));
    await tick(tiles);
    expect(warn).toHaveBeenCalled();
    expect(coarse.visible).toBe(true);
  });

  it('keeps the coarse fallback until nonempty finer geometry finishes fading', async () => {
    const { tiles, coarse, scene, child, fine } = await fixture();
    fine.resolve(overview(child, 1));
    await tick(tiles);
    expect(scene.children).toHaveLength(2);
    expect(tiles.fading).toBe(true);
    expect(coarse.visible).toBe(true);
    const changed = vi.fn();
    tiles.on('change', changed);
    now += TileManager.FADE_MS + 1;
    tiles.update(0, 0);
    expect(tiles.fading).toBe(false);
    expect(coarse.visible).toBe(false);
    expect(changed).toHaveBeenCalledTimes(1); // the idle viewer draws the final coverage change
  });

  it('restores the ancestor while a resolved empty tile is replaced', async () => {
    const { tiles, coarse, child, levels, fine, fetch } = await fixture();
    fine.resolve(overview(child, 1, 'sparse'));
    await tick(tiles);
    expect(coarse.visible).toBe(false);

    const replacement = deferredTile();
    fetch.mockImplementation(async (path) => {
      expect(path).toBe(child.path);
      return replacement.promise;
    });
    const revised = levels.map((lvl) => lvl.level === 1
      ? { ...lvl, tiles: [{ ...child, revision: 'v2' }] }
      : lvl);
    expect(tiles.syncLowres({ grid: 129, levels: revised })).toBe(true);
    tiles.update(0, 0);
    expect(coarse.visible).toBe(true);
    replacement.resolve(overview(child, 1, 'empty'));
    await tick(tiles);
    expect(coarse.visible).toBe(false);
  });

  it('restores the ancestor when an empty finer tile is evicted', async () => {
    const { tiles, coarse, child, fine } = await fixture();
    fine.resolve(overview(child, 1, 'empty'));
    await tick(tiles);
    expect(coarse.visible).toBe(false);
    tiles.configure({ viewDistance: 256 });
    tiles.update(0, 0); // evict the now-distant empty tile
    tiles.update(0, 0); // propagate the changed coverage
    expect(coarse.visible).toBe(true);
  });
});
