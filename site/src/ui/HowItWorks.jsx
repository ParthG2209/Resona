import { useEffect, useRef } from 'react';
import FluidEngine from '../engine/FluidEngine';
import './HowItWorks.css';

export default function HowItWorks() {
  const canvasRef = useRef(null);
  const engineRef = useRef(null);

  useEffect(() => {
    if (canvasRef.current && !engineRef.current) {
      engineRef.current = new FluidEngine(canvasRef.current, 'flowerboy');
      engineRef.current.start();
    }
    return () => {
      if (engineRef.current) {
        engineRef.current.stop();
        engineRef.current = null;
      }
    };
  }, []);

  return (
    <section className="process">
      <div className="process__container">
        
        {/* Step 1: SOURCE */}
        <div className="process__step process__step--source">
          <div className="process__card">
            <img 
              src="https://upload.wikimedia.org/wikipedia/en/c/c3/Tyler%2C_the_Creator_-_Flower_Boy.png" 
              alt="Flower Boy Album Art" 
              className="process__image"
            />
          </div>
          <div className="process__label">01 / SOURCE</div>
        </div>

        {/* Step 2: RENDER */}
        <div className="process__step process__step--render">
          <div className="process__card">
            <canvas ref={canvasRef} className="process__canvas" />
          </div>
          <div className="process__label">02 / RENDER</div>
        </div>

        {/* Step 3: EMOTION */}
        <div className="process__step process__step--emotion">
          <div className="process__card process__card--dark">
            <h3 className="process__text">FEEL<br/>THE<br/>SOUND.</h3>
          </div>
          <div className="process__label">03 / EMOTION</div>
        </div>

      </div>

      <div className="process__footer-track">
        35MM • f/1.4 • ISO 800 • RESONATE VISUAL ENGINE • VOL 1
      </div>
    </section>
  );
}
