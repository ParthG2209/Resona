import { useEffect, useRef, useState } from 'react';

/**
 * useRevealLine — split-line scroll reveal hook.
 * Each child line is masked and translates up from an invisible baseline
 * as it enters the viewport, creating a cinematic staggered reveal.
 */
export default function useRevealLine(options = {}) {
  const ref = useRef(null);
  const [isVisible, setIsVisible] = useState(false);
  const { threshold = 0.15, rootMargin = '0px 0px -60px 0px' } = options;

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true);
          observer.unobserve(el);
        }
      },
      { threshold, rootMargin }
    );

    observer.observe(el);
    return () => observer.disconnect();
  }, [threshold, rootMargin]);

  return { ref, isVisible };
}
