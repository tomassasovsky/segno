// Segno's self-contained synthesis set. Pack installation is managed by the host.
(function (root) {
  'use strict';
  const percent = value => Math.round(value) + '%';
  const seconds = value => (.08 + value / 100 * 2.4).toFixed(2) + ' s';
  const frequency = value => Math.round(180 * Math.pow(70, value / 100)) + ' Hz';
  const control = (key, label, defaultValue, format = percent) => ({key, label, defaultValue, min: 0, max: 100, format});
  const controls = {
    Keys: [control('brightness', 'Brightness', 62), control('decay', 'Decay', 54, seconds), control('character', 'Character', 35)],
    Organs: [control('harmonics', 'Harmonics', 55), control('rotary', 'Rotary', 30), control('release', 'Release', 12, seconds)],
    Synths: [control('cutoff', 'Cutoff', 65, frequency), control('attack', 'Attack', 8, seconds), control('release', 'Release', 38, seconds)],
    Bass: [control('cutoff', 'Cutoff', 38, frequency), control('punch', 'Punch', 55), control('release', 'Release', 18, seconds)],
    Strings: [control('brightness', 'Brightness', 45), control('attack', 'Bow attack', 38, seconds), control('vibrato', 'Vibrato', 22)],
    Drums: [control('tone', 'Tone', 55), control('decay', 'Decay', 35, seconds), control('body', 'Body', 65)],
    Percussion: [control('hardness', 'Mallet hardness', 55), control('decay', 'Decay', 60, seconds), control('tremolo', 'Tremolo', 0)],
  };
  const entries = [
    ['piano', 'Grand piano', 'Keys', 'keys', 'triangle', 2, .12, [68, 72, 22], 'Rounded hammer attack and a falling harmonic tail.'],
    ['keys', 'Electric keys', 'Keys', 'keys', 'sine', 3, .18, [52, 60, 45], 'Bell-like tines with a soft electric body.'],
    ['clav', 'Clavinet', 'Keys', 'keys', 'sawtooth', 2, .06, [80, 18, 65], 'Short, bright plucked-keyboard response.'],
    ['organ', 'Tonewheel organ', 'Organs', 'keys', 'sine', 2, .65, [60, 35, 8], 'Steady tonewheel harmonics with rotary movement.'],
    ['reed', 'Reed organ', 'Organs', 'keys', 'triangle', 3, .5, [45, 12, 22], 'Breathy reed harmonics with a gentler release.'],
    ['lead', 'Analog lead', 'Synths', 'lead', 'sawtooth', 1.006, .48, [72, 2, 25], 'A detuned saw lead with a resonant low-pass filter.'],
    ['pad', 'Warm pad', 'Synths', 'lead', 'triangle', 1.004, .5, [42, 60, 72], 'A slowly opening, detuned triangle pad.'],
    ['pluck', 'Synth pluck', 'Synths', 'lead', 'square', 2, .035, [62, 0, 12], 'A short filtered square-wave pluck.'],
    ['bass', 'Fingered bass', 'Bass', 'lead', 'triangle', 2, .19, [35, 65, 18], 'A rounded fundamental with a finger-like transient.'],
    ['synth-bass', 'Synth bass', 'Bass', 'lead', 'sawtooth', 1.005, .35, [43, 75, 24], 'A dense saw bass with a punchy filter envelope.'],
    ['sub', 'Sub bass', 'Bass', 'lead', 'sine', 1, .5, [20, 20, 30], 'A clean sine foundation with adjustable attack punch.'],
    ['strings', 'String ensemble', 'Strings', 'keys', 'sawtooth', 1.008, .4, [42, 55, 28], 'A broad, gently detuned bowed ensemble.'],
    ['violin', 'Solo violin', 'Strings', 'keys', 'sawtooth', 2, .3, [64, 30, 38], 'A bright, expressive solo bowed voice.'],
    ['cello', 'Cello', 'Strings', 'keys', 'triangle', 2, .4, [30, 45, 20], 'A dark bowed voice with a full lower register.'],
    ['drums', 'Acoustic kit', 'Drums', 'drums', 'noise', 1, 0, [52, 40, 65], 'Synthesized kick, snare, closed hat and clap on GM notes.'],
    ['electronic-drums', 'Electronic kit', 'Drums', 'drums', 'noise', 1, 0, [75, 25, 80], 'Tuned electronic kick and sharply gated noise percussion.'],
    ['marimba', 'Marimba', 'Percussion', 'keys', 'sine', 4, .025, [35, 42, 0], 'A wooden mallet attack with a sparse overtone.'],
    ['vibes', 'Vibraphone', 'Percussion', 'keys', 'sine', 3, .065, [50, 80, 35], 'Long metal-bar tones with adjustable tremolo.'],
    ['bells', 'Bells', 'Percussion', 'keys', 'sine', 2.76, .025, [80, 90, 0], 'Inharmonic metallic partials with a long decay.'],
  ];
  const sounds = Object.fromEntries(entries.map(([id, name, family, icon, wave, ratio, level, values, description]) => [id, {
    id, name, label: name, family, icon, wave, ratio, level, description,
    engine: 'Segno synthesis', pack: family === 'Percussion' ? 'segno-mallets' : 'segno-core',
    expression: ['Pitch bend ±2 semitones', 'Modulation (CC 1)', 'Channel pressure'],
    defaults: Object.fromEntries(controls[family].map((parameter, index) => [parameter.key, values[index]])),
  }]));
  const families = Object.keys(controls);
  function parameters(type) {
    const sound = sounds[type];
    if (!sound) return [];
    return controls[sound.family].map(parameter => ({...parameter, defaultValue: sound.defaults[parameter.key]}));
  }
  function create(type, id) {
    if (!sounds[type]) throw new Error('Unknown Segno instrument: ' + type);
    return {id, type, name: sounds[type].name, params: {...sounds[type].defaults}, device: 'usb', channel: 'all', noteLow: 0, noteHigh: 127,
      midiEnabled: false, keysEnabled: false, mappings: [], triggerNotes: [sounds[type].family === 'Drums' ? 36 : 48]};
  }
  function noteName(note) {
    const n = Math.max(0, Math.min(127, Math.round(Number(note) || 0)));
    return ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'][n % 12] + (Math.floor(n / 12) - 1);
  }
  function art(type) {
    const sound = sounds[type];
    if (!sound) return '';
    const bars = (count, x, y, width, height) => Array.from({length: count}, (_, n) => `<rect x="${x + n * width}" y="${y + n % 3 * 3}" width="${width - 3}" height="${height - n % 3 * 6}" rx="3" fill="${n % 2 ? '#879aaf' : '#b3becb'}"/>`).join('');
    let content;
    switch (sound.family) {
      case 'Keys':
        content = type === 'piano' ? '<path d="M68 130V34q105-30 148 27l27 69Z" fill="#243144"/><path d="M73 38q103-24 136 24l-30 36H73Z" fill="#3c4c61"/>' : `<rect x="28" y="39" width="244" height="96" rx="${type === 'clav' ? 3 : 14}" fill="${type === 'clav' ? '#665246' : '#34465d'}"/><path d="M42 59h214M42 71h214" stroke="#869bb3"/>${type === 'keys' ? '<circle cx="237" cy="57" r="8" fill="#a2b6cd"/>' : '<rect x="45" y="46" width="72" height="12" fill="#272c32"/>'}`;
        content += bars(14, 44, 99, 15, 31);
        break;
      case 'Organs':
        content = `<rect x="24" y="22" width="252" height="123" rx="5" fill="${type === 'reed' ? '#665449' : '#3b4556'}"/>${bars(type === 'reed' ? 12 : 9, 53, 34, type === 'reed' ? 16 : 21, 25)}${bars(14, 45, 77, 15, 24)}${bars(14, 45, 109, 15, 24)}`;
        break;
      case 'Synths':
        content = `<rect x="22" y="29" width="256" height="109" rx="10" fill="#263950"/><rect x="37" y="43" width="151" height="74" rx="4" fill="#111d2a"/><path d="${type === 'lead' ? 'M46 98l22-38v38l24-38v38l24-38v38l24-38v38l24-38' : type === 'pad' ? 'M46 86q18-42 36 0t36 0t36 0t24 0' : 'M46 98V60h24v38h24V60h24v38h24V60h24v38'}" stroke="#9eb9d6" fill="none" stroke-width="3"/>${[56, 92].map((y, n) => `<circle cx="${218 + n * 24}" cy="${y}" r="13" fill="#617893"/>`).join('')}`;
        break;
      case 'Bass':
        content = type === 'sub' ? '<rect x="41" y="35" width="218" height="96" rx="14" fill="#243950"/><path d="M61 83q22-58 44 0t44 0t44 0t44 0" stroke="#9eb9d6" stroke-width="4" fill="none"/>' : `<path d="M48 96q-8-39 26-43l22 16 120-37 10 22-120 40-6 27q-29 28-52-25Z" fill="${type === 'bass' ? '#77604d' : '#536c8d'}"/><path d="m61 86 159-43m-156 50 159-43" stroke="#c2cedc"/><rect x="69" y="78" width="8" height="28" fill="#243144"/>`;
        break;
      case 'Strings':
        content = (type === 'strings' ? [83, 150, 217] : [150]).map((x, n) => `<g transform="translate(${x} ${type === 'cello' ? 4 : 13}) scale(${type === 'cello' ? 1 : .84})"><path d="M-17 38q-22 10-13 26l12 13q-33 24-7 44q25 16 50 0 26-20-7-44l12-13q9-16-13-26Z" fill="${['#80614b', '#6a5245', '#967359'][n]}"/><path d="M-5 12H5v94H-5Z" fill="#253242"/><path d="M-25 101h50M-2 15v109m5-109v109" stroke="#c4c3bb"/></g>`).join('');
        break;
      case 'Drums':
        content = type === 'electronic-drums' ? `<rect x="37" y="22" width="226" height="123" rx="12" fill="#223449"/>${Array.from({length: 8}, (_, n) => `<rect x="${50 + n % 4 * 51}" y="${36 + Math.floor(n / 4) * 50}" width="41" height="40" rx="5" fill="${n < 2 ? '#8ea6c2' : '#4a6483'}"/>`).join('')}` : '<g fill="#4b627d" stroke="#9bb0c7" stroke-width="3"><circle cx="150" cy="101" r="40"/><circle cx="108" cy="49" r="24"/><circle cx="192" cy="49" r="24"/><ellipse cx="58" cy="49" rx="33" ry="9"/><ellipse cx="242" cy="64" rx="32" ry="9"/><path d="M58 58v68m184-53v62"/></g>';
        break;
      default:
        content = type === 'bells' ? [91, 150, 209].map((x, n) => `<path d="M${x - 18} ${66 - n * 9}q0-23 18-23t18 23l10 48H${x - 28}Z" fill="${['#8b795c', '#b1a080', '#84765f'][n]}" stroke="#ced0c8"/>`).join('') : `<path d="M45 126h210" stroke="#52667e" stroke-width="8"/>${bars(11, 43, 36, 20, 80)}<path d="m98 19 47 72m58-72-47 72" stroke="${type === 'marimba' ? '#9b7957' : '#8199b7'}" stroke-width="7"/>${type === 'vibes' ? '<path d="M60 134v13m30-13v13m30-13v13m30-13v13m30-13v13m30-13v13m30-13v13" stroke="#8199b7" stroke-width="9"/>' : ''}`;
    }
    return `<svg viewBox="0 0 300 165" aria-hidden="true" data-sound="${type}">${content}</svg>`;
  }
  const catalogue = {sounds, families, create, parameters, art, noteName};
  root.SegnoInstrumentCatalogue = catalogue;
  if (typeof module !== 'undefined' && module.exports) module.exports = catalogue;
})(typeof window === 'undefined' ? globalThis : window);
