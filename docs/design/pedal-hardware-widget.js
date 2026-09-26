// A scalable pedal face for the design study. Geometry comes from the populated
// Fusion assembly; label paths come from the manufacturing tile generator.
// Interaction belongs to the enclosing button, keeping one encoder focus stop.
(() => {
  let instance = 0;
  const circle = (x, y, r) => `M${x-r} ${y}a${r} ${r} 0 1 0 ${r*2} 0a${r} ${r} 0 1 0 ${-r*2} 0Z`;
  const body = 'M3.825 2H80.175L78.535 111.88H5.465Z';
  const pad = 'M11.73 5.45H72.27Q74.3 5.45 74.27 7.48L72.78 106.48Q72.75 108.45 70.75 108.45H13.25Q11.25 108.45 11.22 106.48L9.73 7.48Q9.7 5.45 11.73 5.45Z';
  const path = (name, d, fill, extra = '') => `<path data-part="${name}" d="${d}" fill="${fill}" ${extra}/>`;
  function face({label, selected = false, disabled = false}) {
    const id = `pedal-face-${instance++}`;
    const metal = selected ? ['#52647b', '#849ab4', '#38485e'] : ['#2b3035', '#737b83', '#333a42'];
    let grips = '';
    for (let row = 0; row < 6; row++) {
      for (let col = 0; col < 5; col++) {
        const x = 42 + (col - 2) * 11.6373, y = 39.47 + row * 12;
        grips += path('Grip base', circle(x, y, 4), '#101316');
        grips += path('Grip surface', circle(x, y - .18, 3.1), `url(#${id}-grip)`, 'stroke="#383d43" stroke-width=".15"');
      }
    }
    return `<svg class="pedal-face" data-widget="hardware-pedal" data-label="${label}" data-selected="${selected}" data-disabled="${disabled}" width="84" height="114" viewBox="0 0 84 114" aria-hidden="true" focusable="false">
      <defs>
        <linearGradient id="${id}-metal" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="${metal[0]}"/><stop offset=".18" stop-color="${metal[1]}"/><stop offset=".85" stop-color="${metal[2]}"/><stop offset="1" stop-color="${metal[1]}"/></linearGradient>
        <linearGradient id="${id}-grip" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#30353a"/><stop offset="1" stop-color="#202428"/></linearGradient>
      </defs>
      ${path('Left hinge', 'M3.8 20.9H2.7Q.5 21.1 .5 24V27Q.5 29.1 2.7 29.3H3.8Z', '#424a53', 'stroke="#777f88" stroke-width=".3"')}
      ${path('Right hinge', 'M80.2 20.9H81.3Q83.5 21.1 83.5 24V27Q83.5 29.1 81.3 29.3H80.2Z', '#424a53', 'stroke="#777f88" stroke-width=".3"')}
      ${path('Tapered metal body', body, `url(#${id}-metal)`, `stroke="${selected ? '#cbd8e9' : '#565f69'}" stroke-width="${selected ? 1 : .35}"`)}
      ${path('Left rolled edge', 'M3.825 2H6.5L8.1 111.88H5.465Z', '#343b43')}
      ${path('Right rolled edge', 'M77.5 2H80.175L78.535 111.88H75.9Z', '#242a31')}
      ${path('Textured rubber pad', pad, '#191d21', 'stroke="#13161a" stroke-width=".4"')}
      ${path('Trapezoid nameplate', 'M14.8205 10.53H69.1795L68.8775 30.43H15.1225Z', selected ? '#273449' : '#20252b', 'stroke="#3b4149" stroke-width=".22"')}
      ${path('Raised hardware label', window.SegnoPedalLabels[label], disabled ? '#a0a8b2' : '#e4e9ef', 'fill-rule="evenodd"')}
      ${grips}
    </svg>`;
  }
  function indicator({color = '#e6eef9', active = false, disabled = false}) {
    const state = disabled ? 'unavailable' : 'idle';
    return `<span class="pedal-led" data-state="${active ? 'active' : state}" data-rest="${state}" style="--led-color:${color}" aria-hidden="true"></span>`;
  }
  window.SegnoPedalWidget = {face, indicator};
})();
