import './Artifact.css';

import { useEffect, useRef, useState } from 'react';
import FluidEngine from '../engine/FluidEngine';
import { DOWNLOAD_URL, DOWNLOAD_META } from '../config/download';
import './Artifact.css';

export default function Artifact() {
  const canvasRef = useRef(null);
  const engineRef = useRef(null);
  const [isHovered, setIsHovered] = useState(false);

  useEffect(() => {
    if (canvasRef.current && !engineRef.current) {
      // Use the starboy palette for a striking red/purple glow when downloading
      engineRef.current = new FluidEngine(canvasRef.current, 'starboy');
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
    <section className="artifact">
      <div className="artifact__container">
        <a 
          href={DOWNLOAD_URL}
          download
          className={`artifact__monolith ${isHovered ? 'artifact__monolith--active' : ''}`}
          onMouseEnter={() => setIsHovered(true)}
          onMouseLeave={() => setIsHovered(false)}
        >
          <div className="artifact__fluid-wrapper">
            <canvas ref={canvasRef} className="artifact__canvas" />
            <div className="artifact__fluid-overlay"></div>
          </div>
          
          <div className="artifact__content">
            <span className="artifact__ghost-text">DOWNLOAD</span>
            <span className="artifact__sub-text">MACOS • {DOWNLOAD_META.arch} • v{DOWNLOAD_META.version}</span>
          </div>
        </a>
      </div>
    </section>
  );
}
