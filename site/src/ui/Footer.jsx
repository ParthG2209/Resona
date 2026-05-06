import './Footer.css';

export default function Footer() {
  return (
    <footer className="footer">
      
      {/* Left Side: Glowing Vibrant Logo & Brand */}
      <div className="footer__left">
        <div className="footer__forge">
          {/* Static Ambient Glow */}
          <div className="footer__forge-glow"></div>
          {/* Final state vibrant logo */}
          <img 
            src="/resona_logo.png" 
            alt="Resona Logo" 
            className="footer__forge-img" 
          />
        </div>
        <div className="footer__brand-group">
          <span className="footer__brand">RESONA</span>
          <span className="footer__copyright">© 2026 Resona Utility</span>
        </div>
      </div>

      {/* Right Side: Replaced cinematic tags with real-world footer links */}
      <div className="footer__right">
        <div className="footer__info-group">
          <span className="footer__label">PRODUCT</span>
          <a href="#" className="footer__link">Download Beta</a>
          <a href="#" className="footer__link">Release Notes</a>
        </div>
        <div className="footer__info-group">
          <span className="footer__label">OPEN SOURCE</span>
          <a href="#" className="footer__link">GitHub Repository</a>
        </div>
        <div className="footer__info-group">
          <span className="footer__label">LEGAL</span>
          <a href="#" className="footer__link">Privacy Policy</a>
          <a href="#" className="footer__link">Terms of Service</a>
        </div>
      </div>

    </footer>
  );
}
