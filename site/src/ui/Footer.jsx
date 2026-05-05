import RevealText from './RevealText';
import './Footer.css';

/**
 * Footer — sits underneath the fluid canvas on the Z-axis.
 * As the user scrolls to the bottom, the fluid slides up like a
 * theater curtain, revealing this stark, minimal footer.
 */
export default function Footer() {
  return (
    <footer className="footer" id="footer">
      <div className="footer__inner">
        <RevealText as="span" className="micro footer__label" delay={0}>
          macOS 14 Sonoma or later
        </RevealText>

        <RevealText as="h2" className="footer__cta" delay={100}>
          <a
            href="https://github.com/ParthG2209/Resona/releases"
            target="_blank"
            rel="noopener noreferrer"
            className="footer__link"
          >
            Download Resona
          </a>
        </RevealText>

        <RevealText delay={200}>
          <div className="footer__meta">
            <span className="footer__meta-item">MIT License</span>
            <span className="footer__meta-sep">·</span>
            <span className="footer__meta-item">Swift 5.9+</span>
            <span className="footer__meta-sep">·</span>
            <span className="footer__meta-item">Metal GPU</span>
          </div>
        </RevealText>

        <RevealText delay={300}>
          <div className="footer__bottom">
            <a
              href="https://github.com/ParthG2209/Resona"
              target="_blank"
              rel="noopener noreferrer"
              className="footer__github"
            >
              View on GitHub →
            </a>
          </div>
        </RevealText>
      </div>

      <div className="footer__credit">
        <span>Built with Metal shaders by Parth Gupta</span>
      </div>
    </footer>
  );
}
