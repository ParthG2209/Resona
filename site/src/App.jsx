import { useRef } from 'react';
import { Analytics } from '@vercel/analytics/react';
import { SpeedInsights } from '@vercel/speed-insights/react';
import HeroMonolith from './ui/HeroMonolith';
import Manifesto from './ui/Manifesto';
import SynesthesiaTunnel from './ui/SynesthesiaTunnel';
import HowItWorks from './ui/HowItWorks';
import Gallery from './ui/Gallery';
import Hardware from './ui/Hardware';
import Blueprint from './ui/Blueprint';
import Signals from './ui/Signals';
import Artifact from './ui/Artifact';
import Footer from './ui/Footer';

/**
 * App — the full Resona landing page orchestrator.
 */
export default function App() {
  const engineRef = useRef(null);

  return (
    <>
      <HeroMonolith engineRef={engineRef} />
      <Manifesto />
      <SynesthesiaTunnel />
      <HowItWorks />
      <Gallery />
      <Hardware />
      <Blueprint />
      <Signals />
      <Artifact />
      <Footer />
      <Analytics />
      <SpeedInsights />
    </>
  );
}
