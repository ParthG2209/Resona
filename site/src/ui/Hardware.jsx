import { useEffect, useRef } from 'react';
import FluidEngine from '../engine/FluidEngine';
import './Hardware.css';

export default function Hardware() {
  const canvasRef = useRef(null);
  const engineRef = useRef(null);

  useEffect(() => {
    if (canvasRef.current && !engineRef.current) {
      engineRef.current = new FluidEngine(canvasRef.current, 'graduation');
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
    <section className="hardware">
      <div className="hardware__title-wrapper">
        <h2 className="hardware__title">NATIVE TO SILICON.</h2>
        <p className="hardware__subtitle">BUILT EXCLUSIVELY FOR macOS</p>
      </div>

      <div className="hardware__laptop-container">
        <div className="hardware__macbook">
          <div className="hardware__screen-bezel">
            <div className="hardware__notch"></div>
            <div className="hardware__screen">
              <canvas ref={canvasRef} className="hardware__canvas" />
            </div>
          </div>
          <div className="hardware__base">
            <div className="hardware__base-notch"></div>
          </div>
        </div>
      </div>
    </section>
  );
}
