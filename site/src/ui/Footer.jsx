import './Footer.css';

export default function Footer() {
  return (
    <footer className="footer">
      <div className="footer__credits">
        <div className="footer__column">
          <span className="footer__role">CREATOR & DIRECTOR</span>
          <span className="footer__name">PARTH GUPTA</span>
        </div>
        <div className="footer__column">
          <span className="footer__role">VISUAL ENGINE</span>
          <span className="footer__name">METAL & WEBGL</span>
        </div>
        <div className="footer__column">
          <span className="footer__role">STUDIO</span>
          <span className="footer__name">RESONA PRODUCTIONS</span>
        </div>
        <div className="footer__column">
          <span className="footer__role">LEGAL</span>
          <span className="footer__name">© 2026 ALL RIGHTS RESERVED</span>
        </div>
      </div>
      
      <div className="footer__bottom">
        <h1 className="footer__logo">RESONA</h1>
      </div>
    </footer>
  );
}
