import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import FluidEngine from '../engine/FluidEngine';
import './SynesthesiaTunnel.css';

gsap.registerPlugin(ScrollTrigger);

export default function SynesthesiaTunnel() {
  const tunnelRef = useRef(null);
  const textRefs = useRef([]);
  const canvasRef = useRef(null);

  useEffect(() => {
    // 1. Initialize the massive background fluid
    let engine;
    if (canvasRef.current) {
      engine = new FluidEngine(canvasRef.current);
      // We can make this one run very slowly for a more ambient feel
      engine._intensity = 0.1; 
      engine.start();
    }

    // 2. Setup the GSAP Z-Axis Tunnel
    let ctx = gsap.context(() => {
      const tl = gsap.timeline({
        scrollTrigger: {
          trigger: tunnelRef.current,
          start: 'top top',
          end: '+=4000', 
          scrub: 1,
          pin: true,
        }
      });
      
      textRefs.current.forEach((text, i) => {
        gsap.set(text, {
          scale: 0.2,
          opacity: 0,
          filter: 'blur(20px)',
          zIndex: 10 - i,
          top: '50%',
          left: '50%',
          xPercent: -50,
          yPercent: -50,
          position: 'absolute'
        });

        const startTime = i * 2; 
        
        tl.to(text, {
          scale: 1,
          opacity: 1,
          filter: 'blur(0px)',
          ease: 'power1.inOut',
          duration: 2
        }, startTime);

        tl.to(text, {
          scale: 1.2,
          duration: 0.5,
          ease: 'none'
        }, startTime + 2);

        tl.to(text, {
          scale: 5,
          opacity: 0,
          filter: 'blur(30px)',
          ease: 'power2.in',
          duration: 1.5
        }, startTime + 2.5);
      });

    }, tunnelRef);

    return () => {
      ctx.revert();
      if (engine) engine.stop();
    };
  }, []);

  const features = [
    { title: "A LIVING CANVAS.", sub: "IT BREATHES WITH THE BASS." },
    { title: "LIQUID ARCHITECTURE.", sub: "LOSING YOURSELF IN SOUND." },
    { title: "THE GALLERY AWAKENS.", sub: "YOUR MUSIC, MANIFESTED." }
  ];

  return (
    <section className="tunnel" ref={tunnelRef}>
      {/* The Ambient Fluid Background */}
      <canvas ref={canvasRef} className="tunnel__fluid" />
      
      <div className="tunnel__container">
        {/* We keep the glass rings to refract the fluid underneath */}
        <div className="tunnel__rings">
          <div className="tunnel__ring tunnel__ring--1"></div>
          <div className="tunnel__ring tunnel__ring--2"></div>
          <div className="tunnel__ring tunnel__ring--3"></div>
        </div>

        {features.map((feat, idx) => (
          <div 
            key={idx} 
            className="tunnel__text-wrapper"
            ref={el => textRefs.current[idx] = el}
          >
            <h3 className="tunnel__title">{feat.title}</h3>
            <p className="tunnel__sub">{feat.sub}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
