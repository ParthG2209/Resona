import { useEffect, useRef } from 'react';

/**
 * useScrollShader — drives the fluid shader as a reactive actor
 * based on which scroll section the user is currently reading.
 * 
 * Maps scroll position to shader uniforms:
 *   - Wave Intensity section → ramp up speed/noise
 *   - Static Mode section → freeze + blur
 *   - Music Detection section → swap palette
 */
export default function useScrollShader(engineRef, peeled) {
  const sectionsRef = useRef({});

  useEffect(() => {
    if (!peeled) return;

    const handleScroll = () => {
      const engine = engineRef.current;
      if (!engine) return;

      const vh = window.innerHeight;
      const scrollY = window.scrollY;

      // Calculate which section dominates the viewport
      const sections = sectionsRef.current;

      // Default state — calm, fluid
      let speed = 0.5;
      let noise = 2.5;
      let blur = 0.0;
      let frozen = 0.0;
      let palette = null;

      for (const [name, el] of Object.entries(sections)) {
        if (!el) continue;
        const rect = el.getBoundingClientRect();
        const progress = 1 - (rect.top / vh);

        if (progress > 0.2 && progress < 1.5) {
          // This section is "active"
          const t = Math.min(Math.max((progress - 0.2) / 0.8, 0), 1);

          if (name === 'wave') {
            speed = 0.5 + t * 1.8; // ramp from calm to violent
            noise = 2.5 + t * 3.0;
          } else if (name === 'static') {
            frozen = t;
            blur = t * 0.9;
            speed = 0.5 * (1 - t);
          } else if (name === 'detection') {
            palette = t > 0.4 ? 'inRainbows' : 'kidA';
          } else if (name === 'canvas') {
            palette = 'currents';
            speed = 0.6;
            noise = 3.0;
          }
        }
      }

      engine.setSpeed(speed);
      engine.setNoise(noise);
      engine.setBlur(blur);
      engine.setFrozen(frozen);
      if (palette) engine.setPalette(palette);
    };

    window.addEventListener('scroll', handleScroll, { passive: true });
    return () => window.removeEventListener('scroll', handleScroll);
  }, [engineRef, peeled]);

  /** Register a named section element */
  const registerSection = (name, el) => {
    sectionsRef.current[name] = el;
  };

  return { registerSection };
}
