// Controller routing and browser synthesis are independent of the inspected UI.
(function (root) {
  'use strict';
  const catalogue = root.SegnoInstrumentCatalogue || (typeof require === 'function' ? require('./instrument-catalogue.js') : null);
  const clamp = (value, low, high) => Math.max(low, Math.min(high, Number(value) || 0));
  const sourceController = source => /^midi:/.test(source) ? 'midi' : /^keys?:/.test(source) ? 'keys' : 'trigger';
  function createInstrumentRuntime(host) {
    const voices = new Map(), sustain = new Map(), activity = new Map(), configurations = new Map();
    const computerHeld = new Map(), midiHeld = new Map(), expression = new Map(), auditions = new Map(), buses = new Map();
    let context, audioReady, serial = 0, refreshing = false;
    const instruments = () => host.instruments() || [];
    const instrument = id => instruments().find(item => item.id === id);
    const changed = () => { if (!refreshing) host.changed?.(); };
    const now = () => host.now?.() ?? Date.now();
    const route = id => host.routes?.(id) || {open: true, level: 75};
    const isDrums = item => catalogue.sounds[item.type]?.family === 'Drums';
    const keyFor = (id, token) => JSON.stringify([id, token]);
    const online = device => !host.ports || host.ports().some(port => port.id === device && port.online !== false);
    function deviceFromSource(source) {
      const prefix = String(source).startsWith('assignment:midi:') ? 'assignment:midi:' : String(source).startsWith('midi:') ? 'midi:' : null;
      if (!prefix) return undefined;
      const port = (host.ports?.() || []).find(port => String(source).startsWith(prefix + port.id + ':') || String(source).startsWith(prefix + encodeURIComponent(port.id) + ':'));
      const encoded = String(source).slice(prefix.length).split(':')[0];
      if (port) return port.id;
      try { return decodeURIComponent(encoded); } catch { return encoded; }
    }
    const patch = item => {
      const type = auditions.get(item.id) || item.type;
      return {...item, type, params: {...catalogue.sounds[type]?.defaults, ...(type === item.type ? item.params : {})}};
    };
    function expressionFor(id) {
      const values = [...(expression.get(id)?.values() || [])].sort((a, b) => a.order - b.order);
      return Object.assign({bend: 0, mod: 0, pressure: 0}, ...values.map(({bend, mod, pressure}) => ({...(bend !== undefined ? {bend} : {}), ...(mod !== undefined ? {mod} : {}), ...(pressure !== undefined ? {pressure} : {})})));
    }
    function busFor(id) {
      let bus = buses.get(id);
      if (!bus) {
        const monitor = context.createGain(), analyser = context.createAnalyser();
        analyser.fftSize = 256;
        monitor.connect(analyser).connect(context.destination);
        bus = {monitor, analyser, data: new Uint8Array(analyser.fftSize)};
        buses.set(id, bus);
      }
      const output = route(id);
      bus.monitor.gain.setTargetAtTime(output.open ? clamp(output.level, 0, 100) / 100 : 0, context.currentTime, .01);
      return bus;
    }
    async function ready() {
      if (host.startAudio) return host.startAudio();
      if (!context) {
        const Constructor = root.AudioContext || root.webkitAudioContext;
        if (!Constructor && !host.audioContext) return;
        context = host.audioContext || new Constructor();
      }
      if (context.state === 'suspended') {
        if (!audioReady) audioReady = Promise.resolve(context.resume()).finally(() => { audioReady = null; });
        await audioReady;
      }
    }
    function synthVoice(item, note, velocity, onEnded) {
      if (!context) return {release() {}, update() {}};
      const sound = catalogue.sounds[item.type], params = item.params, drums = isDrums(item);
      const time = context.currentTime, oscillators = [], partials = [], nodes = [];
      const filter = context.createBiquadFilter(), gain = context.createGain(), pressureGain = context.createGain();
      filter.type = drums && note !== 36 ? 'highpass' : 'lowpass';
      filter.Q.value = item.type === 'lead' || item.type === 'synth-bass' ? 2.8 : .7;
      filter.connect(gain).connect(pressureGain).connect(busFor(item.id).monitor);
      nodes.push(filter, gain, pressureGain);
      let ended = false, stopping = false, cleanupTimer;
      const cleanup = () => {
        if (ended) return;
        ended = true;
        clearTimeout(cleanupTimer);
        for (const node of [...oscillators, ...nodes]) { try { node.disconnect(); } catch {} }
        onEnded();
      };
      const stopAt = at => {
        for (const oscillator of oscillators) { try { oscillator.stop(at); } catch {} }
        clearTimeout(cleanupTimer);
        cleanupTimer = setTimeout(cleanup, Math.max(0, at - context.currentTime) * 1000 + 40);
        cleanupTimer.unref?.();
      };
      const oscillator = (wave, frequency, level) => {
        const source = context.createOscillator(), partial = context.createGain();
        source.type = wave; source.frequency.value = frequency; partial.gain.value = level;
        source.connect(partial).connect(filter); source.start(time);
        oscillators.push(source); partials.push(partial); nodes.push(partial);
        return source;
      };
      const hz = 440 * Math.pow(2, (note - 69) / 12);
      const decay = .08 + (params.decay ?? 45) / 100 * 2.4;
      const duration = drums ? (note === 42 ? .04 + decay * .13 : note === 36 ? .15 + decay * .55 : .08 + decay * .3) : 0;
      if (drums) {
        const electronic = item.type === 'electronic-drums';
        if (note === 36) {
          const kick = oscillator('sine', electronic ? 180 : 135, .8);
          kick.frequency.exponentialRampToValueAtTime(electronic ? 38 : 47, time + duration * .5);
        } else {
          const buffer = context.createBuffer(1, Math.ceil(context.sampleRate * duration), context.sampleRate);
          const data = buffer.getChannelData(0);
          for (let index = 0; index < data.length; index++) data[index] = Math.random() * 2 - 1;
          const noise = context.createBufferSource(); noise.buffer = buffer; noise.connect(filter); noise.start(time); oscillators.push(noise);
          oscillator('triangle', note === 38 ? 180 : 320, .1 + params.body / 250);
        }
        gain.gain.setValueAtTime((.35 + params.body / 160) * velocity / 127, time);
        gain.gain.exponentialRampToValueAtTime(.0001, time + duration);
      } else {
        oscillator(sound.wave, hz, .62);
        oscillator(sound.wave === 'sine' ? 'sine' : 'triangle', hz * sound.ratio, .2);
        if (sound.family === 'Organs') oscillator('sine', hz * 4, .14);
        if (item.type === 'bells') oscillator('sine', hz * 5.4, .12);
        const attack = sound.family === 'Strings' || sound.family === 'Synths' ? .008 + (params.attack || 0) / 100 * .9 : .008;
        const peak = .5 * velocity / 127;
        gain.gain.setValueAtTime(.0001, time);
        gain.gain.linearRampToValueAtTime(peak, time + attack);
        const transient = ['Keys', 'Percussion', 'Bass'].includes(sound.family) || item.type === 'pluck';
        gain.gain.exponentialRampToValueAtTime(Math.max(.0001, peak * (transient ? sound.level : .8)), time + attack + (transient ? decay : .4));
      }
      const lfo = context.createOscillator(), modulation = context.createGain(), tremolo = context.createGain();
      lfo.frequency.value = sound.family === 'Organs' ? 5.8 : 5;
      lfo.connect(modulation); lfo.connect(tremolo); tremolo.connect(pressureGain.gain);
      for (const source of oscillators) if (source.detune) modulation.connect(source.detune);
      lfo.start(time); oscillators.push(lfo); nodes.push(modulation, tremolo);
      // Stop one-shot voices after attaching every oscillator.
      if (drums) {
        stopAt(time + duration + .02);
      }
      function update({instrument: next, expression: expressive}) {
        const values = next.params;
        const brightness = values.cutoff ?? values.brightness ?? values.hardness ?? values.tone ?? 65;
        const frequency = drums && note !== 36 ? 300 + brightness * (note === 42 ? 85 : 22) : 180 * Math.pow(70, brightness / 100);
        filter.frequency.setTargetAtTime(Math.min(19000, frequency), context.currentTime, .02);
        const character = (values.character ?? values.harmonics ?? values.hardness ?? 35) / 100;
        if (partials[1]) partials[1].gain.setTargetAtTime(.03 + character * .34, context.currentTime, .02);
        if (sound.family === 'Organs' && partials[2]) partials[2].gain.setTargetAtTime(character * .22, context.currentTime, .02);
        if (sound.family === 'Bass') filter.Q.setTargetAtTime(.7 + values.punch / 24, context.currentTime, .02);
        const pitch = expressive.bend * 200;
        for (const source of oscillators) if (source !== lfo && source.detune) source.detune.setTargetAtTime(pitch, context.currentTime, .015);
        modulation.gain.setTargetAtTime(expressive.mod * 45 + (values.vibrato || 0) * .35, context.currentTime, .02);
        tremolo.gain.setTargetAtTime(((values.tremolo ?? values.rotary ?? 0) / 100) * .25, context.currentTime, .02);
        pressureGain.gain.setTargetAtTime(1 + expressive.pressure * .25, context.currentTime, .02);
      }
      update({instrument: item, expression: expressionFor(item.id)});
      return {update, release(cut) {
        if (ended || stopping && !cut) return;
        if (drums && !cut) return;
        stopping = true;
        const current = instrument(item.id), values = current ? patch(current).params : params;
        const release = cut ? .025 : .08 + (values.release ?? values.decay ?? 35) / 100 * 2.4;
        gain.gain.cancelScheduledValues(context.currentTime);
        gain.gain.setTargetAtTime(.0001, context.currentTime, release / 5);
        stopAt(context.currentTime + release + .04);
      }};
    }
    function removeVoice(voice, cut = false) {
      if (voices.get(voice.key) !== voice) return;
      voices.delete(voice.key);
      voice.cancelled = true;
      voice.audio?.release(cut);
    }
    function hasSustain(id) { return !!sustain.get(id)?.size; }
    function releaseUnheld(id) {
      if (hasSustain(id)) return;
      for (const voice of voices.values()) if (voice.id === id && voice.sustained) removeVoice(voice);
    }
    async function startNote(id, token, note, velocity, source) {
      const item = instrument(id);
      if (!item || host.available?.(id) === false || !catalogue.sounds[item.type] || !Number.isInteger(note) || note < 0 || note > 127) return false;
      const key = keyFor(id, String(token)) + ':' + (++serial);
      for (const previous of voices.values()) if (previous.id === id && previous.token === String(token) && !previous.sustained) removeVoice(previous, true);
      const voice = {id, key, token: String(token), note, velocity: clamp(velocity ?? 100, 1, 127), sustained: false,
        controller: source?.controller || sourceController(String(token)), source: source?.source || String(token), device: source?.device || deviceFromSource(token), channel: source?.channel,
        pending: true, audition: auditions.has(id), type: patch(item).type, patch: patch(item)};
      voices.set(key, voice);
      activity.set(id, {...activity.get(id), lastNote: note, velocity: voice.velocity, device: source?.device || voice.controller, channel: source?.channel, kind: 'note', at: now()});
      // Publish ownership before awaiting the browser's audio unlock.
      changed();
      try {
        await ready();
        if (voices.get(key) !== voice || !instrument(id)) return false;
        if (voice.device && !online(voice.device)) { removeVoice(voice, true); changed(); return false; }
        const current = patch(instrument(id));
        if (current.type !== voice.type) { removeVoice(voice, true); changed(); return false; }
        const payload = {instrument: current, note, velocity: voice.velocity, route: route(id), expression: expressionFor(id), onEnded: () => {
          if (voices.get(key) === voice) { voices.delete(key); changed(); }
        }};
        voice.audio = host.createVoice ? host.createVoice(payload) : synthVoice(current, note, voice.velocity, payload.onEnded);
        voice.pending = false;
        activity.set(id, {...activity.get(id), error: undefined});
        if (!voice.audition) host.signal?.(id);
        changed();
        return true;
      } catch (error) {
        removeVoice(voice, true);
        activity.set(id, {...activity.get(id), error: 'Audio could not start', at: now()});
        host.audioError?.(error); changed(); return false;
      }
    }
    function noteOn(id, token, note, velocity = 100) { return startNote(id, token, note, velocity); }
    function noteOff(token, cut = false) {
      for (const voice of voices.values()) {
        if (voice.token !== String(token)) continue;
        const item = instrument(voice.id);
        if (!cut && item && !isDrums(patch(item)) && hasSustain(voice.id)) voice.sustained = true;
        else removeVoice(voice, cut);
      }
      changed();
    }
    function setSustain(id, source, on) {
      const item = instrument(id);
      if (!item) return;
      let sources = sustain.get(id);
      if (on && !isDrums(patch(item))) {
        if (!sources) sustain.set(id, sources = new Map());
        sources.set(String(source), {controller: sourceController(String(source)), device: deviceFromSource(source)});
      } else sources?.delete(String(source));
      if (!sources?.size) sustain.delete(id);
      releaseUnheld(id); changed();
    }
    function releaseTokens(tokens, cut = false) { for (const token of tokens || []) noteOff(token, cut); }
    function silenceController(id, controller) {
      for (const voice of voices.values()) if (voice.id === id && voice.controller === controller) removeVoice(voice, true);
      for (const [source, value] of sustain.get(id) || []) if (value.controller === controller) sustain.get(id).delete(source);
      if (!sustain.get(id)?.size) sustain.delete(id);
      if (controller === 'midi') expression.delete(id);
      releaseUnheld(id); updateVoices(id); changed();
    }
    function silenceInstrument(id) {
      for (const voice of voices.values()) if (voice.id === id) removeVoice(voice, true);
      sustain.delete(id); expression.delete(id); auditions.delete(id); changed();
    }
    function cutSound() {
      for (const voice of voices.values()) removeVoice(voice, true);
      sustain.clear(); expression.clear(); computerHeld.clear(); midiHeld.clear(); changed();
    }
    function cancelControl(sourcePrefix) {
      const prefix = (String(sourcePrefix).startsWith('assignment:') ? String(sourcePrefix) : 'assignment:' + sourcePrefix).replace(/:$/, '');
      const matchesSource = source => source === prefix || source.startsWith(prefix + ':');
      for (const voice of voices.values()) if (matchesSource(voice.token)) removeVoice(voice, true);
      for (const [id, sources] of sustain) {
        for (const source of sources.keys()) if (matchesSource(source)) sources.delete(source);
        if (!sources.size) sustain.delete(id);
        releaseUnheld(id);
      }
      changed();
    }
    function computerDown(event) {
      if (!event?.code || computerHeld.has(event.code)) return [];
      const tokens = []; computerHeld.set(event.code, tokens);
      for (const item of instruments()) {
        if (!item.keysEnabled) continue;
        const mapping = (item.mappings || []).find(mapping => mapping.source?.type === 'key' && mapping.source.code === event.code && !!mapping.source.shift === !!event.shift);
        for (const [index, note] of (mapping?.notes || []).entries()) {
          const token = `key:${event.code}:${item.id}:${index}`; tokens.push(token);
          void startNote(item.id, token, note, 100, {controller: 'keys', source: 'key:' + event.code});
        }
      }
      return tokens;
    }
    function computerUp(code) { releaseTokens(computerHeld.get(code)); computerHeld.delete(code); }
    function midiBase(event) { return `midi:${encodeURIComponent(event.device)}:${event.channel}:${event.kind}:${event.number ?? 0}`; }
    function midiSource(event) { return `midi:${encodeURIComponent(event.device)}:${event.channel}`; }
    function matches(item, event) {
      return item.midiEnabled && item.device === event.device && (item.channel === 'all' || Number(item.channel) === event.channel);
    }
    function midiMapping(item, event) {
      return (item.mappings || []).find(mapping => {
        const mapped = mapping.source;
        return mapped?.type === 'midi' && mapped.device === event.device && (mapped.channel === 'all' || Number(mapped.channel) === event.channel) && mapped.kind === event.kind && mapped.number === event.number;
      });
    }
    function updateVoices(id) {
      const item = instrument(id);
      if (!item) return;
      if (context && buses.has(id)) busFor(id);
      for (const voice of voices.values()) if (voice.id === id) voice.audio?.update?.({instrument: voice.type === item.type && !voice.audition ? {...item, params: {...catalogue.sounds[item.type].defaults, ...item.params}} : voice.patch, route: route(id), expression: expressionFor(id)});
    }
    function receiveMidi(event) {
      if (!event || typeof event.device !== 'string' || !Number.isInteger(event.channel) || event.channel < 1 || event.channel > 16 || !['note', 'cc', 'bend', 'pressure'].includes(event.kind)) return [];
      if (!Number.isFinite(event.value) || ['note', 'cc'].includes(event.kind) && (!Number.isInteger(event.number) || event.number < 0 || event.number > 127)) return [];
      const base = midiBase(event), source = midiSource(event), noteMessage = event.kind === 'note', ccMessage = event.kind === 'cc';
      const down = noteMessage ? event.value > 0 : event.value >= 64;
      if ((noteMessage || ccMessage) && !down) { releaseTokens(midiHeld.get(base)?.tokens); midiHeld.delete(base); }
      // Always allow releases; only a fresh incoming event can restart after reconnect.
      if (!online(event.device)) { disconnect(event.device); return []; }
      const recipients = instruments().filter(item => item.midiEnabled && (matches(item, event) || midiMapping(item, event)));
      for (const item of recipients) {
        const ordinaryControl = matches(item, event) && !midiMapping(item, event);
        activity.set(item.id, {...activity.get(item.id), device: event.device, channel: event.channel, kind: event.kind, number: event.number, value: event.value, online: true, at: now()});
        if (ordinaryControl && ccMessage && event.number === 64) setSustain(item.id, source, down);
        if (ordinaryControl && (event.kind === 'bend' || event.kind === 'pressure' || ccMessage && event.number === 1)) {
          let sources = expression.get(item.id);
          if (!sources) expression.set(item.id, sources = new Map());
          const expressive = {...sources.get(source), device: event.device, order: ++serial};
          if (event.kind === 'bend') expressive.bend = clamp((event.value - 8192) / 8192, -1, 1);
          else if (event.kind === 'pressure') expressive.pressure = clamp(event.value / 127, 0, 1);
          else expressive.mod = clamp(event.value / 127, 0, 1);
          sources.set(source, expressive); updateVoices(item.id);
          activity.set(item.id, {...activity.get(item.id), ...expressionFor(item.id)});
        }
      }
      if ((!noteMessage && !ccMessage) || !down) { changed(); return []; }
      if (ccMessage && midiHeld.has(base)) return [];
      if (noteMessage && midiHeld.has(base)) releaseTokens(midiHeld.get(base).tokens, true);
      const tokens = [];
      midiHeld.set(base, {device: event.device, tokens});
      for (const item of recipients) {
        const mapping = midiMapping(item, event);
        if (!mapping && noteMessage && (event.number < (item.noteLow ?? 0) || event.number > (item.noteHigh ?? 127))) continue;
        const notes = mapping ? mapping.notes : noteMessage ? [event.number] : [];
        for (const [index, note] of (notes || []).entries()) {
          const token = `${base}:${item.id}:${index}`; tokens.push(token);
          void startNote(item.id, token, note, noteMessage ? event.value : 100, {controller: 'midi', source, device: event.device, channel: event.channel});
        }
      }
      changed(); return tokens;
    }
    function disconnect(device) {
      for (const voice of voices.values()) if (voice.device === device) removeVoice(voice, true);
      for (const [id, sources] of sustain) {
        for (const [source, value] of sources) if (value.device === device) sources.delete(source);
        if (!sources.size) sustain.delete(id);
        releaseUnheld(id);
      }
      for (const [base, value] of midiHeld) if (value.device === device) midiHeld.delete(base);
      for (const [id, sources] of expression) {
        for (const [source, value] of sources) if (value.device === device) sources.delete(source);
        if (!sources.size) expression.delete(id);
        updateVoices(id);
      }
      for (const item of instruments()) if (item.device === device) activity.set(item.id, {...activity.get(item.id), online: false, bend: 0, mod: 0, pressure: 0, at: now()});
      changed();
    }
    function configuration(item) {
      return {type: item.type, midi: JSON.stringify([!!item.midiEnabled, item.device, item.channel, item.noteLow, item.noteHigh, (item.mappings || []).filter(mapping => mapping.source?.type === 'midi')]),
        keys: JSON.stringify([!!item.keysEnabled, (item.mappings || []).filter(mapping => mapping.source?.type === 'key')])};
    }
    function refresh() {
      refreshing = true;
      try {
      const all = instruments(), ids = new Set(all.map(item => item.id));
      for (const voice of voices.values()) if (!ids.has(voice.id)) silenceInstrument(voice.id);
      for (const id of configurations.keys()) if (!ids.has(id)) {
        silenceInstrument(id); configurations.delete(id); activity.delete(id);
        const bus = buses.get(id); bus?.monitor.disconnect(); bus?.analyser.disconnect(); buses.delete(id);
      }
      for (const item of all) {
        const before = configurations.get(item.id), after = configuration(item);
        configurations.set(item.id, after);
        if (before?.type !== undefined && before.type !== after.type) silenceInstrument(item.id);
        if (before && before.midi !== after.midi || !item.midiEnabled) silenceController(item.id, 'midi');
        if (before && before.keys !== after.keys || !item.keysEnabled) silenceController(item.id, 'keys');
        if (!online(item.device)) disconnect(item.device);
        updateVoices(item.id);
      }
      } finally { refreshing = false; }
    }
    function audition(id, type) {
      if (!instrument(id) || !catalogue.sounds[type]) return false;
      for (const voice of voices.values()) if (voice.id === id && voice.audition) removeVoice(voice, true);
      auditions.set(id, type); changed(); return true;
    }
    function endAudition(id) {
      for (const voice of voices.values()) if (voice.id === id && voice.audition) removeVoice(voice, true);
      auditions.delete(id); updateVoices(id); changed();
    }
    function meter(id) {
      const bus = buses.get(id);
      if (!bus || !route(id).open) return 0;
      bus.analyser.getByteTimeDomainData(bus.data);
      return Math.min(1, Math.sqrt(bus.data.reduce((sum, sample) => sum + ((sample - 128) / 128) ** 2, 0) / bus.data.length) * 3);
    }
    function snapshot() {
      return {voices: [...voices.values()].map(({id, token, note, velocity, sustained, pending, controller, device, channel, audition}) => ({id, token, note, velocity, sustained, pending, controller, device, channel, audition})),
        pending: [...voices.values()].filter(voice => voice.pending).map(({id, token, note}) => ({id, token, note})),
        sustain: [...sustain].flatMap(([id, sources]) => [...sources.keys()].map(source => ({id, source}))),
        activity: Object.fromEntries([...activity].map(([id, value]) => [id, {...value}]))};
    }
    for (const item of instruments()) configurations.set(item.id, configuration(item));
    return {noteOn, noteOff, setSustain, receiveMidi, computerDown, computerUp, disconnect, cutSound, cancelControl, silenceInstrument, silenceController, refresh, snapshot, audition, endAudition, meter};
  }
  root.createInstrumentRuntime = createInstrumentRuntime;
  if (typeof module !== 'undefined' && module.exports) module.exports = createInstrumentRuntime;
})(typeof window === 'undefined' ? globalThis : window);
