import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import './Blueprint.css';

gsap.registerPlugin(ScrollTrigger);

export default function Blueprint() {
  const containerRef = useRef(null);
  const laserRef = useRef(null);
  const nodesRef = useRef([]);

  const specs = [
    { label: 'RENDER ENGINE', value: 'VOLUMETRIC FLUID DYNAMICS' },
    { label: 'AUDIO PIPELINE', value: 'SYSTEM LEVEL INTEGRATION' },
    { label: 'ALGORITHM', value: 'DYNAMIC SATURATION MAPPING' },
    { label: 'ARCHITECTURE', value: 'LIQUID STATE MACHINE' },
  ];

  useEffect(() => {
    let ctx = gsap.context(() => {
      // Laser line animation (draws down as you scroll)
      gsap.fromTo(laserRef.current,
        { scaleY: 0 },
        {
          scaleY: 1,
          ease: 'none',
          scrollTrigger: {
            trigger: containerRef.current,
            start: 'top 30%',
            end: 'bottom 80%',
            scrub: true,
          }
        }
      );

      // Node illumination (lights up as laser hits them)
      nodesRef.current.forEach((node, index) => {
        gsap.fromTo(node,
          { opacity: 0.1, filter: 'blur(10px)', x: index % 2 === 0 ? -20 : 20 },
          {
            opacity: 1,
            filter: 'blur(0px)',
            x: 0,
            ease: 'power2.out',
            scrollTrigger: {
              trigger: node,
              start: 'top 60%',
              end: 'top 40%',
              scrub: true,
            }
          }
        );
      });
    }, containerRef);

    return () => ctx.revert();
  }, []);

  return (
    <section className="blueprint" ref={containerRef}>
      <div className="blueprint__grid-background"></div>
      
      <div className="blueprint__laser-container">
        <div className="blueprint__laser-line" ref={laserRef}></div>
      </div>

      <div className="blueprint__content">
        <h3 className="blueprint__title">M-SERIES SCHEMATIC</h3>

        <div className="blueprint__nodes">
          {specs.map((spec, idx) => (
            <div 
              className="blueprint__node" 
              key={idx}
              ref={el => nodesRef.current[idx] = el}
            >
              <div className="blueprint__node-point"></div>
              <div className="blueprint__node-data">
                <span className="blueprint__label">{spec.label}</span>
                <span className="blueprint__value">{spec.value}</span>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
