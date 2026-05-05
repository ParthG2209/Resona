import { useEffect, useRef } from 'react';
import FluidEngine from '../engine/FluidEngine';
import './HeroMonolith.css';

/**
 * HeroCinematic — The "A24 / Editorial" approach.
 * Completely abandons SaaS conventions. Uses an ultra-widescreen cinematic strip
 * for the fluid shader, with the album art breaking the letterbox boundaries.
 * Typography is treated like a film's billing block.
 */
export default function HeroMonolith({ engineRef }) {
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
    <section className="hero-cinematic">
      
      {/* Top Navigation / Technical Badges */}
      <nav className="hero-cinematic__nav">
        <div className="hero-cinematic__nav-brand">
          <img src="/resona_logo.png" alt="Resona" className="hero-cinematic__logo" />
        </div>
        <div className="hero-cinematic__nav-item">"MUSIC IS LIQUID ARCHITECTURE."</div>
      </nav>

      {/* The Ultra-Widescreen Shader Strip */}
      <div className="hero-cinematic__strip">
        <canvas
          ref={canvasRef}
          className="hero-cinematic__fluid-canvas"
          width="1920"
          height="400"
        />
        {/* Shadow vignette to blend the edges into the black void */}
        <div className="hero-cinematic__strip-overlay"></div>
      </div>

      {/* The Album Art — Breaking the cinematic strip's boundaries */}
      <div className="hero-cinematic__album">
        <img 
          src="https://upload.wikimedia.org/wikipedia/en/7/70/Graduation_%28album%29.jpg" 
          alt="Graduation" 
        />
        {/* Subtle physical reflection/glare */}
        <div className="hero-cinematic__album-glare"></div>
      </div>

      {/* The Billing Block Typography (Bottom) */}
      <div className="hero-cinematic__billing">
        A NATIVE MACOS UTILITY <span>&middot;</span> REAL-TIME METAL GPU RENDERING <span>&middot;</span> AUDIO REACTIVE VISUALIZER
      </div>
      
    </section>
  );
}
