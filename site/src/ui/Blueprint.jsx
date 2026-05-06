import './Blueprint.css';

export default function Blueprint() {
  const specs = [
    { label: 'RENDER ENGINE', value: 'VOLUMETRIC FLUID DYNAMICS' },
    { label: 'AUDIO PIPELINE', value: 'SYSTEM LEVEL INTEGRATION' },
    { label: 'ALGORITHM', value: 'DYNAMIC SATURATION MAPPING' },
    { label: 'ARCHITECTURE', value: 'LIQUID STATE MACHINE' },
  ];

  return (
    <section className="blueprint">
      <div className="blueprint__container">
        <div className="blueprint__header">
          <h3 className="blueprint__title">SYSTEM ARCHITECTURE</h3>
        </div>

        <ul className="blueprint__list">
          {specs.map((spec, idx) => (
            <li className="blueprint__item" key={idx}>
              <span className="blueprint__label">{spec.label}</span>
              <span className="blueprint__value">{spec.value}</span>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
