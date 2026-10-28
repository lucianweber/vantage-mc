import { useEffect, useState } from 'react';
import { useVantage } from '../src/react/index.js';
import type { TileInfo } from '../src/three/index.js';

export function renderLabel(info: Pick<TileInfo, 'renderedAt' | 'rendering' | 'dynamic'>): string {
  if (info.dynamic) return 'Live rendering';
  if (info.rendering) return 'Rendering…';
  const stamp = info.renderedAt;
  if (stamp === undefined || !Number.isFinite(stamp) || stamp <= 0 || stamp > 8.64e15) return 'Render date unavailable';
  return `Rendered: ${new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(stamp)}`;
}

/** A small HUD overlay showing render information + the control legend — a
 *  custom child that reads the shared engine state via useVantage(). */
export function Hud() {
  const { viewer, info } = useVantage();
  const [flying, setFlying] = useState(false);
  useEffect(() => {
    if (!viewer) return;
    setFlying(viewer.isFlying);
    return viewer.on('mode', ({ fly }) => setFlying(fly));
  }, [viewer]);
  if (!info) return null;
  const title = document.querySelector<HTMLMetaElement>('meta[name="vantage-page-title"]')?.content.trim() || 'vantage';
  const k = (t: string) => <b style={{ color: '#93a9cc' }}>{t}</b>;
  return (
    <div
      style={{
        padding: '12px 15px',
        font: '12px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
        color: '#e6eefb',
        pointerEvents: 'none',
        overflowWrap: 'anywhere',
        flexShrink: 0,
      }}
      className="vtg-glass"
    >
      <div style={{ fontWeight: 700, letterSpacing: '0.04em', color: '#eef4ff' }}>
        {title}
      </div>
      <div style={{ color: '#93a9cc', marginTop: 4, fontSize: 11 }}>
        {renderLabel(info)}
      </div>
      <div style={{ color: '#6f86ab', marginTop: 8, fontSize: 11, lineHeight: 1.6 }}>
        {flying ? (
          <>
            {k('WASD')} fly · {k('Space/Shift')} up·down
            <br />
            {k('mouse')} look (click to capture) · {k('scroll')} speed · {k('Esc')} exit
          </>
        ) : (
          <>
            {k('drag')} pan · {k('right-drag')} orbit · {k('scroll')} zoom
            <br />
            {k('WASD')} move · {k('Q/E')} turn · {k('R/F')} tilt
            <br />
            {k('B')} biomes · {k('C')} caves · {k('P')} players
          </>
        )}
      </div>
    </div>
  );
}

