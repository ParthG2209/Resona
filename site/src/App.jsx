import { useRef } from 'react';
import HeroMonolith from './ui/HeroMonolith';

/**
 * App — the full Resona landing page orchestrator.
 */
export default function App() {
  const engineRef = useRef(null);

  return (
    <>
      <HeroMonolith engineRef={engineRef} />
      
      {/* 
        We will redesign the remaining scroll sections later.
        For now, we are locking down the Prismatic Monolith hero.
      */}
      <div style={{ height: '200vh', background: 'var(--surface-desktop)' }}></div>
    </>
  );
}
