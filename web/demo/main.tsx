// Demo app — the reference consumer of the React package entry. This is how a
// server-admin web app would drop Vantage in: one <VantageViewer> with a
// <BiomeLayer> child. Tiles are served from web/public/ (regenerate with
// `just render <save>`). Deep-links: #top frames top-down, #biome opens the
// biome layer.

import { StrictMode } from 'react';
import { Hud } from './Hud.js';
import { createRoot } from 'react-dom/client';
import { worldFromVantageServer } from '../src/core/index.js';
import type { WorldSource } from '../src/core/index.js';
import { BiomeLayer, DepthSlider, DimensionPicker, LightPanel, MapNav, PlayerList, Reticle, SettingsPanel, VantageViewer } from '../src/react/index.js';
import type { ViewMode } from '../src/react/index.js';

const view: ViewMode = /top/i.test(location.hash) ? 'top' : 'orbit';
const biomeOpen = /biome/i.test(location.hash);
const viteEnv = (import.meta as ImportMeta & { readonly env: Record<string, string | undefined> }).env;
const serverEndpoint = viteEnv['VITE_VANTAGE_SERVER_ENDPOINT']?.trim();

/** What the viewer loads: a multi-dimension world index, a single manifest, a
 *  server world source, or the classic standalone tile. */
type Entry = 'world' | 'manifest' | 'tile';

function App({ entry, serverWorld }: { entry: Entry; serverWorld?: WorldSource }) {
  // Dev-only: expose the engine for manual poking in the console.
  const ref = (e: import('../src/three/index.js').VantageViewer | null) => {
    (window as unknown as { __vantage?: unknown }).__vantage = e;
  };
  // A world index (`world.json`, every dimension) when the render has one, else
  // a single streamed manifest, else the classic single tile (`vantage meshtex`).
  const source = serverWorld
    ? ({ world: serverWorld } as const)
    : entry === 'world'
    ? ({ world: '/world.json' } as const)
    : entry === 'manifest'
    ? ({ world: '/manifest.json' } as const)
    : ({ tile: '/terrain.vtile', textures: '/terrain.vtexarr' } as const);
  return (
    <VantageViewer ref={ref} {...source} view={view}>
      <div style={{ position: 'absolute', top: 16, left: 16, display: 'flex', flexDirection: 'column', gap: 16, width: 'max-content', maxWidth: 'calc(100% - 32px)', maxHeight: 'calc(100% - 32px)', pointerEvents: 'none' }}>
        <Hud />
        <PlayerList style={{ position: 'relative', top: 'auto', left: 'auto', right: 'auto', maxWidth: '100%', minHeight: 0, flexShrink: 1, pointerEvents: 'auto' }} />
      </div>
      <Reticle />
      <DimensionPicker />
      <BiomeLayer legend hover defaultEnabled={biomeOpen} />
      <LightPanel />
      <SettingsPanel />
      <MapNav />
      <DepthSlider />
    </VantageViewer>
  );
}

function mount(entry: Entry, serverWorld?: WorldSource): void {
  // Survive Vite HMR re-evaluation: reuse the root instead of re-creating it.
  const holder = window as unknown as { __vantageRoot?: ReturnType<typeof createRoot> };
  holder.__vantageRoot ??= createRoot(document.getElementById('root')!);
  holder.__vantageRoot.render(
    <StrictMode>
      <App entry={entry} serverWorld={serverWorld} />
    </StrictMode>,
  );
}

/** Whether a JSON file sits at `path` — how the viewer decides which entry
 *  point a render directory offers without fetching a body it may not use.
 *  An on-demand server answers this for its synthesized manifest too: HEAD
 *  reaches the producer, which serves cheap resources and declines the ones a
 *  probe should never be able to trigger. */
async function hasJson(path: string): Promise<boolean> {
  try {
    const r = await fetch(path, { method: 'HEAD' });
    return r.ok && (r.headers.get('content-type') ?? '').includes('json');
  } catch {
    return false;
  }
}

if (serverEndpoint) {
  const accessToken = viteEnv['VITE_VANTAGE_SERVER_TOKEN']?.trim();
  if (!accessToken) {
    throw new Error('VITE_VANTAGE_SERVER_TOKEN is required with VITE_VANTAGE_SERVER_ENDPOINT');
  }
  // Development walkthrough mode: the token is injected by the local Vite
  // process, never placed in the URL. Production launchers should supply their
  // existing session through a same-origin proxy or custom fetch transport.
  void worldFromVantageServer(serverEndpoint, { accessToken }).then(
    (world) => mount('manifest', world),
    (error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      const output = document.createElement('pre');
      output.style.cssText = 'color:#ff8797;padding:24px;white-space:pre-wrap';
      output.textContent = message;
      document.getElementById('root')!.replaceChildren(output);
    },
  );
} else {
  // Prefer the whole world (every dimension) when the render has an index,
  // then a single streamed manifest, then the standalone tile.
  void (async () => {
    if (await hasJson('/world.json')) return mount('world');
    mount((await hasJson('/manifest.json')) ? 'manifest' : 'tile');
  })();
}
