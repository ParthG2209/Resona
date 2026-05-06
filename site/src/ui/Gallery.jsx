import { useEffect, useRef } from 'react';
import FluidEngine from '../engine/FluidEngine';
import './Gallery.css';

const ALBUMS = [
  {
    id: 'starboy',
    title: 'STARBOY',
    palette: 'starboy',
    art: 'https://upload.wikimedia.org/wikipedia/en/3/39/The_Weeknd_-_Starboy.png',
  },
  {
    id: 'graduation',
    title: 'GRADUATION',
    palette: 'graduation',
    art: 'https://upload.wikimedia.org/wikipedia/en/7/70/Graduation_%28album%29.jpg',
  },
  {
    id: 'takecare',
    title: 'TAKE CARE',
    palette: 'takecare',
    art: 'https://upload.wikimedia.org/wikipedia/en/a/ae/Drake_-_Take_Care_cover.jpg',
  }
];

export default function Gallery() {
  const canvasRefs = useRef([]);

  useEffect(() => {
    const engines = [];
    ALBUMS.forEach((album, idx) => {
      const canvas = canvasRefs.current[idx];
      if (canvas) {
        const engine = new FluidEngine(canvas, album.palette);
        engine.start();
        engines.push(engine);
      }
    });

    return () => {
      engines.forEach(engine => engine.stop());
    };
  }, []);

  return (
    <section className="gallery">
      {/* Global Left Tracking Text */}
      <div className="gallery__global-tracking gallery__global-tracking--left">
        DIRECTED BY PARTH GUPTA • VISUAL EFFECTS ENGINE: METAL / WEBGL • AUDIO REACTIVE SIMULATION FRAMEWORK
      </div>

      <div className="gallery__track">
        {ALBUMS.map((album, idx) => (
          <div className="gallery__item" key={album.id}>
            <div className="gallery__monolith">
              <canvas 
                ref={el => canvasRefs.current[idx] = el} 
                className="gallery__canvas" 
              />
              <h3 className="gallery__album-title">{album.title}</h3>
              <img src={album.art} alt={album.title} className="gallery__album-art" />
            </div>
          </div>
        ))}
      </div>

      {/* Global Right Tracking Text */}
      <div className="gallery__global-tracking gallery__global-tracking--right">
        A RESONA PRODUCTION • VOLUMETRIC FLUID DYNAMICS • HIGH FIDELITY AUDIO RENDERER
      </div>
    </section>
  );
}
