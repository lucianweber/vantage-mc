import { describe, expect, it, vi } from 'vitest';
import { renderLabel } from '../demo/Hud.js';
import { VantageViewer } from '../src/three/viewer.js';
import type { WorldManifest } from '../src/core/manifest.js';

describe('render information', () => {
  it('formats dates locally and gives live/progressive status precedence', () => {
    const renderedAt = 1793188800000;
    expect(renderLabel({ renderedAt })).toBe(`Rendered: ${new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(renderedAt)}`);
    expect(renderLabel({ renderedAt, rendering: true })).toBe('Rendering…');
    expect(renderLabel({ renderedAt, rendering: false, dynamic: true })).toBe('Live rendering');
    for (const renderedAt of [undefined, 0, -1, NaN, Infinity, 8.64e15 + 1]) {
      expect(renderLabel({ renderedAt })).toBe('Render date unavailable');
    }
  });

  it('emits progress completion and date-only changes while deduplicating idle polls', () => {
    // Exercise the event path without constructing a WebGL renderer.
    const viewer = Object.create(VantageViewer.prototype) as {
      lastProgress: unknown;
      emitter: { emit: ReturnType<typeof vi.fn> };
      emitProgress: (m: WorldManifest) => boolean;
    };
    viewer.lastProgress = null;
    viewer.emitter = { emit: vi.fn() };
    const manifest = { tiles: [{}], rendering: true } as WorldManifest;
    expect(viewer.emitProgress(manifest)).toBe(true);
    expect(viewer.emitProgress(manifest)).toBe(false);
    const finished = { ...manifest, rendering: false, renderedAt: 1793188800000 };
    expect(viewer.emitProgress(finished)).toBe(true);
    expect(viewer.emitter.emit).toHaveBeenLastCalledWith('progress', expect.objectContaining({ rendering: false, renderedAt: finished.renderedAt }));
    expect(viewer.emitProgress({ ...finished, renderedAt: finished.renderedAt + 1000 })).toBe(true);
    expect(viewer.emitProgress({ ...finished, dynamic: true })).toBe(true);
  });
});
