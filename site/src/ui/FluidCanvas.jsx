import { useEffect, useRef } from 'react';
import FluidEngine from '../engine/FluidEngine';

/**
 * FluidCanvas — full-viewport WebGL canvas running the fluid shader.
 * Exposes the engine instance via a forwarded ref so parent components
 * can drive the shader (speed, palette, freeze) from scroll events.
 */
export default function FluidCanvas({ engineRef }) {
  const canvasRef = useRef(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const engine = new FluidEngine(canvas);
    engine.start();

    if (engineRef) engineRef.current = engine;

    return () => engine.stop();
  }, [engineRef]);

  return (
    <canvas
      ref={canvasRef}
      id="fluid-canvas"
      style={{
        position: 'fixed',
        top: 0,
        left: 0,
        width: '100vw',
        height: '100vh',
        zIndex: 'var(--z-fluid)',
        display: 'block',
      }}
    />
  );
}
