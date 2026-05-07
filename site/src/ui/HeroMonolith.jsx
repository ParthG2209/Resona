import { useEffect, useRef, useCallback } from 'react';
import FluidEngine from '../engine/FluidEngine';
import './HeroMonolith.css';

/**
 * HeroCinematic — The Living Gradient (Refined).
 * Full-viewport fluid shader at maximum intensity.
 * Dark scrim + edge vignette for readability.
 * Accent rules frame the title. No text halos.
 */
export default function HeroMonolith({ engineRef }) {
  const canvasRef = useRef(null);
  const internalEngineRef = useRef(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const engine = new FluidEngine(canvas, 'nomoreparties');
    engine.start();
    internalEngineRef.current = engine;

    if (engineRef) engineRef.current = engine;

    return () => {
      engine.stop();
    };
  }, [engineRef]);

  return (
    <section className="hero-cinematic">
      
      {/* Top Navigation */}
      <nav className="hero-cinematic__nav">
        <div className="hero-cinematic__nav-brand">
          <img src="/resona_logo.png" alt="Resona" className="hero-cinematic__logo" />
        </div>
        <a href="#download" className="hero-cinematic__nav-btn">
          <span className="hero-cinematic__nav-btn-text">GET RESONΛ</span>
        </a>
      </nav>

      {/* Full-Bleed Fluid */}
      <canvas
        ref={canvasRef}
        className="hero-cinematic__fluid-canvas"
        width="1920"
        height="1080"
      />

      {/* Dark scrim — center readability zone */}
      <div className="hero-cinematic__scrim" />

      {/* Edge vignette — cinematic framing */}
      <div className="hero-cinematic__vignette" />

      {/* Title lockup — accent rules + title + tagline */}
      <div className="hero-cinematic__lockup">
        <div className="hero-cinematic__rule hero-cinematic__rule--top" />
        <h1 className="hero-cinematic__title">RESONΛ</h1>
        <div className="hero-cinematic__rule hero-cinematic__rule--bottom" />
        <div className="hero-cinematic__tagline">
          Audio Reactive Visualizer for macOS
        </div>
      </div>

      {/* Film grain */}
      <div className="hero-cinematic__grain" />

      {/* Scroll hint */}
      <div className="hero-cinematic__scroll-hint">
        <div className="hero-cinematic__scroll-line" />
      </div>

      {/* Billing Block */}
      <div className="hero-cinematic__billing">
        A NATIVE MACOS UTILITY <span>&middot;</span> REAL-TIME METAL GPU RENDERING <span>&middot;</span> AUDIO REACTIVE VISUALIZER
      </div>
      
    </section>
  );
}
