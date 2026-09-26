'use strict';
const assert = require('node:assert/strict');
const catalogue = require('./instrument-catalogue.js');
const createRuntime = require('./instrument-runtime.js');
const flush = async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); };
function fakeAudioContext() {
  const nodes = [];
  const parameter = () => ({value: 0, setTargetAtTime(value) { assert.ok(Number.isFinite(value)); this.value = value; },
    setValueAtTime(value) { assert.ok(Number.isFinite(value)); this.value = value; },
    linearRampToValueAtTime(value) { assert.ok(Number.isFinite(value)); this.value = value; },
    exponentialRampToValueAtTime(value) { assert.ok(Number.isFinite(value) && value > 0); this.value = value; }, cancelScheduledValues() {}});
  const node = type => {
    const value = {type, gain: parameter(), frequency: parameter(), detune: parameter(), Q: parameter(), connections: [],
      connect(target) { this.connections.push(target); return target; }, disconnect() { this.disconnected = true; }, start() {}, stop() {},
      getByteTimeDomainData(data) { data.fill(140); }};
    nodes.push(value); return value;
  };
  return {nodes, currentTime: 0, sampleRate: 48000, state: 'running', destination: node('destination'),
    createGain: () => node('gain'), createAnalyser: () => node('analyser'), createOscillator: () => node('oscillator'),
    createBiquadFilter: () => node('filter'), createBufferSource: () => node('buffer-source'),
    createBuffer: (_, size) => ({getChannelData: () => new Float32Array(size)})};
}
function fixture(options = {}) {
  let items = [catalogue.create('keys', 'keys'), catalogue.create('drums', 'drums')];
  items[0].midiEnabled = true; items[0].channel = 1;
  items[0].keysEnabled = true; items[0].mappings = [{source: {type: 'key', code: 'KeyA', shift: false}, notes: [48]}];
  items[1].midiEnabled = true; items[1].channel = 10;
  const ports = [{id: 'usb', name: 'Keyboard + pads', online: true}, {id: 'din', name: 'DIN MIDI', online: true}];
  const outputs = {keys: {open: true, level: 75}, drums: {open: false, level: 25}};
  const started = [], signalled = [];
  const host = {instruments: () => items, routes: id => outputs[id] || {open: true, level: 75}, ports: () => ports,
    signal: id => signalled.push(id), changed() {}, ...options,
    createVoice(payload) { const voice = {payload, releases: [], updates: [], release(cut) { this.releases.push(cut); }, update(value) { this.updates.push(value); }}; started.push(voice); return voice; }};
  const runtime = createRuntime(host);
  const midi = (channel, number, value = 100, kind = 'note', device = 'usb') => runtime.receiveMidi({device, channel, kind, number, value});
  return {runtime, midi, started, signalled, outputs, ports, get items() { return items; }, set items(value) { items = value; }};
}
async function run() {
  assert.equal(Object.keys(catalogue.sounds).length, 19);
  assert.equal(catalogue.families.length, 7);
  assert.equal(new Set(Object.keys(catalogue.sounds).map(catalogue.art)).size, 19);
  for (const [type, sound] of Object.entries(catalogue.sounds)) {
    const created = catalogue.create(type, 'test');
    assert.equal(created.midiEnabled, false); assert.equal(created.keysEnabled, false);
    assert.deepEqual(created.mappings, []); assert.equal(created.channel, 'all');
    assert.equal(sound.engine, 'Segno synthesis');
    assert.equal(catalogue.parameters(type).length, 3);
    for (const parameter of catalogue.parameters(type)) {
      assert.equal(created.params[parameter.key], parameter.defaultValue);
      assert.ok(parameter.defaultValue >= 0 && parameter.defaultValue <= 100);
      assert.ok(parameter.format(0)); assert.ok(parameter.format(100));
    }
  }
  assert.equal(catalogue.noteName(0), 'C-1'); assert.equal(catalogue.noteName(127), 'G9');

  const f = fixture();
  f.midi(1, 0, 23); f.midi(10, 36, 119); f.midi(1, 127, 97); await flush();
  assert.deepEqual(f.runtime.snapshot().voices.map(v => [v.id, v.note, v.velocity]), [['keys', 0, 23], ['drums', 36, 119], ['keys', 127, 97]]);
  assert.deepEqual(f.started.map(v => v.payload.route), [{open: true, level: 75}, {open: false, level: 25}, {open: true, level: 75}]);
  f.items = f.items.map(item => ({...item})); // Host rereads and selection/navigation do not change ownership.
  f.runtime.refresh();
  assert.equal(f.runtime.snapshot().voices.length, 3);
  f.outputs.keys = {open: false, level: 60}; f.outputs.drums = {open: true, level: 92}; f.runtime.refresh();
  assert.deepEqual(f.started[0].updates.at(-1).route, {open: false, level: 60});
  assert.deepEqual(f.started[1].updates.at(-1).route, {open: true, level: 92});
  f.midi(1, 0, 0); assert.equal(f.runtime.snapshot().voices.length, 2);
  assert.equal(f.runtime.snapshot().voices.find(v => v.id === 'drums').note, 36);
  f.runtime.cutSound();

  // Splits use incoming pitch; overlap deliberately layers instruments.
  f.items[1].channel = 'all'; f.items[1].noteLow = 60; f.items[0].noteHigh = 72;
  f.runtime.refresh(); f.midi(1, 64); f.midi(2, 80); await flush();
  assert.deepEqual(f.runtime.snapshot().voices.map(v => [v.id, v.note]), [['keys', 64], ['drums', 64], ['drums', 80]]);
  f.midi(1, 64, 0); assert.deepEqual(f.runtime.snapshot().voices.map(v => [v.id, v.note]), [['drums', 80]]);
  f.runtime.cutSound();

  // All held/sustain contributions belong to an instrument, including retriggers.
  f.runtime.setSustain('keys', 'assignment:pedal:1:sustain', true);
  f.midi(1, 60); await flush(); f.midi(1, 60, 0);
  assert.equal(f.runtime.snapshot().voices[0].sustained, true);
  f.runtime.setSustain('keys', 'midi:usb:1', true);
  f.runtime.setSustain('keys', 'assignment:pedal:1:sustain', false);
  assert.equal(f.runtime.snapshot().voices.length, 1);
  f.midi(1, 60); await flush(); assert.equal(f.runtime.snapshot().voices.length, 3); // Previous sustained strike and drum layer are separate.
  assert.equal(f.runtime.snapshot().voices.filter(v => v.id === 'keys').at(-1).sustained, false);
  f.midi(1, 60, 0); f.runtime.setSustain('keys', 'midi:usb:1', false);
  assert.equal(f.runtime.snapshot().voices.length, 0);
  f.runtime.setSustain('drums', 'pedal', true); assert.equal(f.runtime.snapshot().sustain.length, 0);

  f.runtime.setSustain('keys', 'assignment:pedal:1:sustain', true);
  for (let strike = 0; strike < 2; strike++) {
    f.runtime.computerDown({code: 'KeyA', shift: false}); await flush(); f.runtime.computerUp('KeyA');
  }
  assert.equal(f.runtime.snapshot().voices.filter(v => v.id === 'keys' && v.note === 48 && v.sustained).length, 2);
  f.runtime.setSustain('keys', 'assignment:pedal:1:sustain', false);
  assert.equal(f.runtime.snapshot().voices.length, 0);

  f.items[1].channel = 10; f.runtime.refresh();
  f.runtime.computerDown({code: 'KeyA', shift: false}); f.midi(1, 65); await flush();
  f.midi(1, 64, 127, 'cc'); f.midi(1, 65, 0);
  f.runtime.silenceController('keys', 'midi');
  assert.deepEqual(f.runtime.snapshot().voices.map(v => v.note), [48]);
  assert.equal(f.runtime.snapshot().sustain.length, 0);
  f.runtime.computerUp('KeyA'); assert.equal(f.runtime.snapshot().voices.length, 0);
  f.runtime.computerDown({code: 'KeyA', shift: true}); await flush(); assert.equal(f.runtime.snapshot().voices.length, 0); f.runtime.computerUp('KeyA');
  f.items[1].keysEnabled = true; f.items[1].mappings = [{source: {type: 'key', code: 'KeyA', shift: false}, notes: [36, 38]}]; f.runtime.refresh();
  f.runtime.computerDown({code: 'KeyA', shift: false}); f.runtime.computerDown({code: 'KeyA', shift: false}); await flush();
  assert.equal(f.runtime.snapshot().voices.length, 3);
  f.runtime.computerUp('KeyA'); assert.equal(f.runtime.snapshot().voices.length, 0);

  // MIDI note remaps are exact device/channel messages; unmapped notes pass through.
  f.items[0].mappings.push({source: {type: 'midi', device: 'usb', channel: 1, kind: 'note', number: 12}, notes: [24, 84, 127]});
  f.items[0].mappings.push({source: {type: 'midi', device: 'usb', channel: 1, kind: 'cc', number: 20}, notes: [42, 49]});
  f.runtime.refresh(); f.midi(1, 12, 88); await flush();
  assert.deepEqual(f.runtime.snapshot().voices.map(v => v.note), [24, 84, 127]);
  f.midi(1, 12, 0); f.midi(1, 20, 127, 'cc'); f.midi(1, 20, 126, 'cc'); await flush();
  assert.equal(f.runtime.snapshot().voices.length, 2); f.midi(1, 20, 0, 'cc');
  assert.equal(f.runtime.snapshot().voices.length, 0);

  const explicit = fixture();
  explicit.items[0].noteLow = 60; explicit.items[0].noteHigh = 72;
  explicit.items[0].mappings = [
    {source: {type: 'midi', device: 'usb', channel: 10, kind: 'note', number: 36}, notes: [60, 64, 67]},
    {source: {type: 'midi', device: 'din', channel: 3, kind: 'note', number: 5}, notes: [84]},
    {source: {type: 'midi', device: 'usb', channel: 1, kind: 'cc', number: 64}, notes: [72]},
  ];
  explicit.runtime.refresh(); explicit.midi(10, 36); await flush();
  assert.deepEqual(explicit.runtime.snapshot().voices.map(v => [v.id, v.note]), [['keys', 60], ['keys', 64], ['keys', 67], ['drums', 36]]);
  explicit.midi(3, 5, 111, 'note', 'din'); await flush();
  assert.equal(explicit.runtime.snapshot().voices.at(-1).note, 84);
  explicit.midi(1, 64, 127, 'cc'); await flush();
  assert.equal(explicit.runtime.snapshot().voices.at(-1).note, 72);
  assert.equal(explicit.runtime.snapshot().sustain.length, 0);
  explicit.midi(1, 64, 0, 'cc');
  explicit.runtime.disconnect('din'); assert.equal(explicit.runtime.snapshot().voices.length, 4);
  explicit.runtime.cutSound();

  f.midi(1, 62); await flush();
  f.midi(1, 0, 16383, 'bend'); f.midi(1, 1, 127, 'cc'); f.midi(1, 0, 64, 'pressure');
  const expressive = f.started.at(-1).updates.at(-1).expression;
  assert.ok(expressive.bend > .99); assert.equal(expressive.mod, 1); assert.equal(expressive.pressure, 64 / 127);
  assert.equal(f.runtime.snapshot().activity.keys.lastNote, 62);
  assert.equal(f.runtime.snapshot().activity.keys.pressure, 64 / 127);
  f.runtime.computerDown({code: 'KeyA', shift: false}); await flush();
  f.runtime.disconnect('usb');
  assert.equal(f.runtime.snapshot().voices.some(v => v.controller === 'midi'), false);
  assert.equal(f.runtime.snapshot().voices.filter(v => v.controller === 'keys').length, 3);
  assert.deepEqual(f.started.filter(voice => voice.payload.instrument.id === 'keys').at(-1).updates.at(-1).expression, {bend: 0, mod: 0, pressure: 0});
  f.ports[0].online = false; f.midi(1, 63); await flush(); assert.equal(f.runtime.snapshot().voices.length, 3);
  f.ports[0].online = true; f.runtime.refresh(); assert.equal(f.runtime.snapshot().voices.length, 3);
  f.runtime.computerUp('KeyA');

  // Deferred audio cannot resurrect after release, panic, controller changes, or deletion.
  for (const action of ['release', 'panic', 'disable', 'delete', 'disconnect', 'retire']) {
    let unlock; const pending = new Promise(resolve => { unlock = resolve; });
    const p = fixture({startAudio: () => pending});
    const token = action === 'retire' ? 'assignment:midi:usb:map-1:press:keys:notes:48' : 'midi:usb:1:note:48:keys:0';
    const result = p.runtime.noteOn('keys', token, 48);
    assert.equal(p.runtime.snapshot().pending.length, 1);
    if (action === 'release') p.runtime.noteOff(token);
    if (action === 'panic') p.runtime.cutSound();
    if (action === 'disable') { p.items[0].midiEnabled = false; p.runtime.refresh(); }
    if (action === 'delete') { p.items = []; p.runtime.refresh(); }
    if (action === 'disconnect') p.runtime.disconnect('usb');
    if (action === 'retire') p.runtime.cancelControl('midi:usb:map-1');
    unlock(); assert.equal(await result, false, action); assert.equal(p.started.length, 0, action); assert.equal(p.runtime.snapshot().pending.length, 0);
  }

  const shared = fixture();
  shared.runtime.setSustain('keys', 'assignment:midi:usb:map-1:press:keys:sustain', true);
  await shared.runtime.noteOn('keys', 'assignment:midi:usb:map-1:press:keys:notes:48', 48);
  await shared.runtime.noteOn('keys', 'assignment:pedal:2:press:keys:notes:62', 62);
  shared.runtime.disconnect('usb');
  assert.deepEqual(shared.runtime.snapshot().voices.map(v => v.note), [62]);
  assert.equal(shared.runtime.snapshot().sustain.length, 0);
  shared.runtime.setSustain('keys', 'assignment:pedal:3:press:keys:sustain', true);
  shared.runtime.noteOff('assignment:pedal:2:press:keys:notes:62');
  shared.runtime.cancelControl('pedal:3'); assert.equal(shared.runtime.snapshot().voices.length, 0);

  const audition = fixture();
  const saved = JSON.stringify(audition.items);
  await audition.runtime.noteOn('drums', 'pad', 36);
  await audition.runtime.noteOn('keys', 'held-original', 60);
  const signalCount = audition.signalled.length;
  assert.equal(audition.runtime.audition('keys', 'pad'), true);
  await audition.runtime.noteOn('keys', 'audition', 64);
  assert.equal(audition.started.at(-1).payload.instrument.type, 'pad');
  assert.equal(audition.signalled.length, signalCount);
  assert.equal(JSON.stringify(audition.items), saved);
  audition.runtime.endAudition('keys');
  assert.deepEqual(audition.runtime.snapshot().voices.map(v => v.token), ['pad', 'held-original']);
  assert.equal(audition.started[1].updates.at(-1).instrument.type, 'keys');
  assert.equal(audition.started[1].releases.length, 0);
  assert.equal(JSON.stringify(audition.items), saved);
  audition.runtime.cutSound(); assert.equal(audition.runtime.snapshot().sustain.length, 0);
  assert.equal(audition.runtime.meter('keys'), 0);

  const failed = fixture({startAudio: () => Promise.reject(new Error('Audio denied'))});
  assert.equal(await failed.runtime.noteOn('keys', 'touch:48', 48), false);
  assert.equal(failed.runtime.snapshot().voices.length, 0);
  assert.equal(failed.runtime.snapshot().activity.keys.error, 'Audio could not start');

  // Exercise real synthesis construction and parameter automation through a fake
  // AudioContext. This checks graph isolation, not physical audio output.
  const audioContext = fakeAudioContext();
  const synthItems = Object.keys(catalogue.sounds).map(type => ({...catalogue.create(type, type), midiEnabled: true}));
  const synthRoutes = Object.fromEntries(synthItems.map((item, index) => [item.id, {open: true, level: 20 + index * 4}]));
  const synth = createRuntime({instruments: () => synthItems, routes: id => synthRoutes[id], audioContext});
  for (const item of synthItems) assert.equal(await synth.noteOn(item.id, 'touch:' + item.id, item.type.includes('drums') ? 36 : 60), true);
  const analysers = audioContext.nodes.filter(node => node.type === 'analyser');
  assert.equal(analysers.length, 19);
  for (let index = 0; index < analysers.length; index++) {
    const inputs = audioContext.nodes.filter(node => node.connections.includes(analysers[index]));
    assert.equal(inputs.length, 1);
    assert.equal(inputs[0].gain.value, (20 + index * 4) / 100);
    assert.equal(analysers[index].connections[0], audioContext.destination);
  }
  synthRoutes.keys = {open: false, level: 80}; synth.refresh();
  assert.equal(synth.meter('keys'), 0); assert.ok(synth.meter('piano') > 0 && synth.meter('piano') <= 1);
  synth.receiveMidi({device: 'usb', channel: 1, kind: 'bend', value: 16383});
  synth.receiveMidi({device: 'usb', channel: 1, kind: 'cc', number: 1, value: 127});
  synth.receiveMidi({device: 'usb', channel: 1, kind: 'pressure', value: 127});
  for (const item of synthItems) for (const value of [0, 100]) {
    for (const control of catalogue.parameters(item.type)) item.params[control.key] = value;
    synth.refresh();
  }
  await synth.noteOn('drums', 'snare', 38);
  await synth.noteOn('electronic-drums', 'hat', 42);
  synth.cutSound(); assert.equal(synth.snapshot().voices.length, 0);
  console.log('PASS: 19 patches; independent sources/routes and audio buses; splits/layers; sustain; remaps; MIDI expression; disconnect/reconnect; pending-start retirement; audition persistence; audio failure.');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
