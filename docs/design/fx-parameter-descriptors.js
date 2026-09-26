// The factory files serialize normalized numbers, not physical units.
// Native Looper X translator tables have not been recovered. Never derive a
// legal range, scale or enum table from the factory library's observed values.
(function (root) {
  'use strict';
  const powerKeys = Object.freeze({
    Amp: ['Amp'], Chorus: ['Chor'], Compressor: ['Compressor', 'Comp'],
    Degrade: ['Degrade'], Delay: ['Delay'], Distortion: ['Distort', 'Dist'],
    Doubler: ['Doubler'], 'Dub Delay': ['Dub Delay'], 'Four-band EQ': ['EQ 4-Band'],
    Harmonize: ['Harmonize'], 'HP / Gate': ['HP/Gate'], 'Low-pass Filter': ['LPF'],
    Modulation: ['Mod'], Octaver: ['Oct'], Overdrive: ['OvDrive'],
    'Parametric EQ': ['Para EQ', 'EQ'], 'Pitch Shift': ['Pitch'], Pumper: ['Pumper'],
    Reverb: ['Reverb'], Slicer: ['Slicer'], 'Smart Tune': ['Smart Tune'],
    'Spring Reverb': ['Spring'], Transient: ['Transient'], Vinyl: ['Vinyl'],
    Wah: ['Wah'], Whammy: ['Whammy'], 'Ambient Reverb': ['Amb-Verb'],
    'Dub Reverb': ['Dub-Verb'],
  });
  const label = key => key.replace(/^(Del |EQ |LPF |Pumper |Rev |Slic |Master )/, '')
    .replace(/\bReso\b/g, 'Resonance').replace(/\bFreq\b/g, 'Frequency')
    .replace(/\bVol\b/g, 'Level').replace(/\bPatt\b/g, 'Pattern')
    .replace(/\bStep Len\b/g, 'Step length');
  const finite = value => typeof value === 'number' && Number.isFinite(value);
  const clone = value => JSON.parse(JSON.stringify(value));
  function powerParameter(module) {
    return module.params.find(p => (Object.hasOwn(powerKeys, module.name) ? powerKeys[module.name] : []).includes(p[0]));
  }
  function enabled(module) {
    const power = powerParameter(module);
    return !module.bypass && (!power || power[1] >= 0.5);
  }
  function setEnabled(module, value) {
    const power = powerParameter(module);
    if (power) { power[1] = value ? 1 : 0; module.bypass = false; }
    else module.bypass = !value;
  }
  function describe(module, param) {
    const isPower = (Object.hasOwn(powerKeys, module.name) ? powerKeys[module.name] : []).includes(param[0]);
    const pan = param[0] === 'Pan' && !module.sourceValues;
    return {
      key: param[0], label: isPower ? module.name : label(param[0]),
      type: isPower ? 'switch' : pan ? 'continuous' : 'unresolved',
      role: isPower ? 'enable' : 'parameter', unit: pan ? 'balance' : null,
      min: 0, max: 1, step: isPower ? 1 : 0.001, encoderStep: isPower ? 1 : 0.01,
      defaultValue: finite(param[3]) ? param[3] : param[1],
      defaultKind: pan ? 'channel-default' : 'loaded-preset', factoryDefault: null,
      options: isPower ? [{value:0, label:'Off'}, {value:1, label:'On'}] : [],
      resolution: isPower ? 'module-enable' : pan ? 'segno-channel' : 'source-value',
      nativeRangeVerified: isPower, sourceFamily: module.sourceFamily || null,
      sourcePresetId: module.sourcePresetId || module.parameterSourcePresetId || null,
      sourceKey: param[0],
      note: isPower ? 'Module enable. Off = 0; On = 1.' : pan ? 'Segno channel balance.'
        : 'Source value 0–1. Native type, scale and option labels are unverified.',
    };
  }
  function coerce(descriptor, value) {
    if (!finite(value)) throw new TypeError('Parameter value must be a finite number.');
    const v = Math.max(descriptor.min, Math.min(descriptor.max, value));
    if (descriptor.type === 'switch') return v >= 0.5 ? 1 : 0;
    if (descriptor.type === 'enum') {
      if (!descriptor.options.length) throw new TypeError('An enum requires verified options.');
      return descriptor.options.reduce((best, o) => Math.abs(o.value-v) < Math.abs(best.value-v) ? o : best).value;
    }
    return v;
  }
  function format(descriptor, value) {
    if (!finite(value)) return 'Unavailable';
    if (descriptor.type === 'switch') return value >= 0.5 ? 'On' : 'Off';
    if (descriptor.type === 'enum') return descriptor.options.find(o => Math.abs(o.value-value) < 0.000001)?.label || 'Source ' + value;
    if (descriptor.unit === 'balance') return Math.abs(value-0.5) < 0.001 ? 'Centre'
      : (value < 0.5 ? 'L ' : 'R ') + Math.round(Math.abs(value-0.5)*200);
    if (descriptor.resolution === 'source-value') return 'Source ' + Number(value.toFixed(6));
    return Number(value.toFixed(3)) + (descriptor.unit ? ' ' + descriptor.unit : '');
  }
  function parse(descriptor, text) {
    const input = String(text).trim();
    const option = descriptor.options.find(o => o.label.toLowerCase() === input.toLowerCase());
    if (option) return option.value;
    if (descriptor.unit === 'balance') {
      if (/^cent(?:re|er)$/i.test(input)) return 0.5;
      const side = /^([lr])\s*(\d+(?:\.\d+)?)$/i.exec(input);
      if (side) { const n = Number(side[2]); if (n > 100) throw new RangeError('Balance must be 0–100 on either side.'); return 0.5 + (side[1].toLowerCase() === 'l' ? -n : n)/200; }
    }
    const raw = input.replace(/^Source\s+/i, '');
    if (!/^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$/i.test(raw)) throw new TypeError('Enter a valid source number.');
    const value = Number(raw);
    if (!finite(value) || value < descriptor.min || value > descriptor.max) throw new RangeError('Source value must be between 0 and 1.');
    if (descriptor.type === 'switch' && value !== 0 && value !== 1) throw new RangeError('Choose Off or On.');
    if (descriptor.type === 'enum' && !descriptor.options.some(o => o.value === value)) throw new RangeError('Choose a listed option.');
    return value;
  }
  function turn(descriptor, value, delta) {
    if (!finite(delta) || delta === 0) return value;
    if (descriptor.type === 'enum') {
      const current = descriptor.options.findIndex(o => o.value === coerce(descriptor, value));
      return descriptor.options[Math.max(0, Math.min(descriptor.options.length-1, current + Math.sign(delta)))].value;
    }
    if (descriptor.type === 'switch') return delta > 0 ? 1 : 0;
    return coerce(descriptor, Number((value + delta*descriptor.encoderStep).toFixed(9)));
  }
  function write(module, param, value) {
    const d = describe(module, param);
    param[1] = coerce(d, value);
    if (d.role === 'enable') module.bypass = false;
    return param[1];
  }
  function targets(rig, {locationLabel = value => value, artworkRoot = ''} = {}) {
    const list = [];
    for (const rack of rig.racks) for (const module of rack.modules) {
      module.expressionId ||= 'module-' + (rig.nextExpressionModuleId = (rig.nextExpressionModuleId || 0) + 1);
      for (const param of module.params) {
        const d = describe(module, param);
        list.push({
          key: JSON.stringify(['fx', rack.id, module.expressionId, param[0]]),
          destination: rack.source, detail: locationLabel(rack.source) + ' / ' + rack.name,
          label: module.name + ' · ' + (d.role === 'enable' ? 'Enable' : d.label),
          art: module.icon ? artworkRoot + 'stomps/' + module.icon : null,
          type: d.type, min: 0, max: 1, step: d.step, encoderStep: d.encoderStep, options: clone(d.options),
          defaultValue: d.defaultValue, descriptor: d, resolution: d.resolution,
          format: value => format(d, value), parse: text => parse(d, text),
          coerce: value => coerce(d, value), get: () => param[1],
          set: value => write(module, param, value),
          persist: (state, value) => {
            const m = state.racks.find(r => r.id === rack.id)?.modules.find(m => m.expressionId === module.expressionId);
            const p = m?.params.find(p => p[0] === param[0]);
            if (p) write(m, p, value);
          },
        });
      }
    }
    return list;
  }
  const api = {powerKeys, powerParameter, enabled, setEnabled, describe, label, format, parse, coerce, turn, write, targets,
    // Source storage is normalized already. These are not physical-unit conversions.
    toNormalized: (d, value) => coerce(d, value), fromNormalized: (d, value) => coerce(d, value)};
  root.SegnoFxParameters = Object.freeze(api);
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
