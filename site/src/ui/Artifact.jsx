import './Artifact.css';

import { useEffect, useRef, useState, useCallback } from 'react';
import FluidEngine from '../engine/FluidEngine';
import { DOWNLOAD_URL, DOWNLOAD_META } from '../config/download';
import { FORMSPREE_ENDPOINT } from '../config/download';

// States: 'idle' | 'input' | 'submitting' | 'success' | 'error'

export default function Artifact() {
  const canvasRef = useRef(null);
  const engineRef = useRef(null);
  const inputRef  = useRef(null);

  const [phase, setPhase]     = useState('idle');
  const [email, setEmail]     = useState('');
  const [isHovered, setHovered] = useState(false);

  useEffect(() => {
    if (canvasRef.current && !engineRef.current) {
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

  // Focus the email input when we enter the 'input' phase
  useEffect(() => {
    if (phase === 'input') {
      setTimeout(() => inputRef.current?.focus(), 50);
    }
  }, [phase]);

  const handleMonolithClick = useCallback((e) => {
    if (phase === 'idle') {
      e.preventDefault();
      setPhase('input');
    }
  }, [phase]);

  const handleSubmit = useCallback(async (e) => {
    e.preventDefault();
    if (!email || !email.includes('@')) return;

    setPhase('submitting');

    try {
      const res = await fetch(FORMSPREE_ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ email, source: 'Resona Beta Download', _subject: `New Resona Beta Request: ${email}` }),
      });

      if (res.ok) {
        setPhase('success');
        // Trigger download automatically
        const link = document.createElement('a');
        link.href = DOWNLOAD_URL;
        link.download = 'Resona.dmg';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
      } else {
        setPhase('error');
      }
    } catch {
      setPhase('error');
    }
  }, [email]);

  const isActive = isHovered || phase !== 'idle';

  return (
    <section className="artifact" id="download">
      <div className="artifact__container">
        <div
          className={`artifact__monolith ${isActive ? 'artifact__monolith--active' : ''} artifact__monolith--phase-${phase}`}
          onMouseEnter={() => setHovered(true)}
          onMouseLeave={() => setHovered(false)}
          onClick={handleMonolithClick}
          role="button"
          tabIndex={0}
        >
          {/* Fluid background */}
          <div className="artifact__fluid-wrapper">
            <canvas ref={canvasRef} className="artifact__canvas" />
            <div className="artifact__fluid-overlay" />
          </div>

          {/* ── Phase: idle ── */}
          {phase === 'idle' && (
            <div className="artifact__content artifact__content--idle">
              <span className="artifact__ghost-text">DOWNLOAD</span>
              <span className="artifact__sub-text">MACOS • {DOWNLOAD_META.arch} • v{DOWNLOAD_META.version}</span>
            </div>
          )}

          {/* ── Phase: input ── */}
          {phase === 'input' && (
            <form
              className="artifact__content artifact__content--form"
              onSubmit={handleSubmit}
              onClick={(e) => e.stopPropagation()}
            >
              <p className="artifact__form-label">EARLY ACCESS</p>
              <p className="artifact__form-sub">Enter your email — we'll add you to the beta and you'll download instantly.</p>
              <div className="artifact__input-row">
                <input
                  ref={inputRef}
                  type="email"
                  className="artifact__email-input"
                  placeholder="your@email.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  required
                  autoComplete="email"
                />
                <button type="submit" className="artifact__submit-btn">
                  Get Access
                </button>
              </div>
              <p className="artifact__form-note">25 spots • No spam • Unsubscribe anytime</p>
            </form>
          )}

          {/* ── Phase: submitting ── */}
          {phase === 'submitting' && (
            <div className="artifact__content artifact__content--center">
              <div className="artifact__spinner" />
              <span className="artifact__sub-text">Securing your spot…</span>
            </div>
          )}

          {/* ── Phase: success ── */}
          {phase === 'success' && (
            <div className="artifact__content artifact__content--center">
              <span className="artifact__ghost-text artifact__ghost-text--sm">YOU'RE IN</span>
              <span className="artifact__sub-text">Your download has started. We'll be in touch.</span>
            </div>
          )}

          {/* ── Phase: error ── */}
          {phase === 'error' && (
            <div className="artifact__content artifact__content--center">
              <span className="artifact__ghost-text artifact__ghost-text--sm">OOPS</span>
              <span className="artifact__sub-text">
                Something went wrong.{' '}
                <button className="artifact__retry" onClick={(e) => { e.stopPropagation(); setPhase('input'); }}>
                  Try again
                </button>
              </span>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}
