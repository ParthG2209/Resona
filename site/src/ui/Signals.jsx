import './Signals.css';

export default function Signals() {
  // Repeating the text enough times so it can seamlessly loop on ultra-wide monitors
  const content = "APPLE MUSIC • SPOTIFY • APPLE MUSIC • SPOTIFY • APPLE MUSIC • SPOTIFY • APPLE MUSIC • SPOTIFY • ";
  
  return (
    <section className="signals">
      <div className="signals__label">SUPPORTED PROTOCOLS</div>
      <div className="signals__marquee">
        <div className="signals__marquee-inner">
          <span className="signals__text">{content}</span>
          <span className="signals__text">{content}</span>
        </div>
      </div>
    </section>
  );
}
