const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const repair = require('./session-connection-repair.js');
const ownership = require('./session-field-ownership.js');
const copy = value => structuredClone(value);
const target = JSON.stringify(['mix', 'Guitar', 'level']);
const control = {kind:'control', port:0};
const midi = {kind:'midi', id:'old'};
const switchState = hardware => ({hardware, press:'none', hold:'none', change:'none', mappings:[]});
const port = (type = 'expression') => ({type, calibration:{heel:.15, toe:.85}, mappings:[],
  switches:[switchState('momentary'), switchState('latching')]});
function freeze(value) {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}
function fixture(type = 'expression') {
  const source = {racks:[], expressionSettings:{nextId:8, ports:[port(type), port(type), port('single')]},
    midiMappings:[], recordedParts:{'Track 1':['Guitar']}, trackLabels:{'Track 1':'Verse'},
    trackLength:{'Track 1':{durationBeats:16}}, loopSettings:{mode:'multi', tempo:117},
    pedalSettings:{leds:['Blue']}, audioLibrary:{prepared:[], backing:null, trackImports:{}}};
  if (type === 'expression') source.expressionSettings.ports[0].mappings = [
    {id:'expression-1', target, detail:'Guitar', label:'Volume', heel:.2, toe:.9}];
  else {
    source.expressionSettings.ports[0].switches[0].press = 'command:undo';
    source.expressionSettings.ports[0].switches[0].hold = 'command:redo';
    source.expressionSettings.ports[0].switches[1].change = 'command:stop';
    source.expressionSettings.ports[0].switches[1].mappings = [
      {id:'switch-2', target, detail:'Guitar', label:'Volume', condition:'on', active:.8, inactive:.1}];
    source.racks = [
      {id:'a', name:'Space', source:'Guitar', rule:{pedal:'external:0:0', condition:'held'}, modules:[]},
      {id:'b', name:'Texture', source:'Track 1', rule:{pedal:'external:0:1', condition:'on'}, modules:[]},
      {id:'c', name:'Unrelated', source:'Master', rule:{pedal:'external:2:0', condition:'always'}, modules:[]}
    ];
  }
  const snapshot = ownership.capture(source), current = copy(source);
  current.expressionSettings.ports[1].calibration = {heel:.3, toe:.75};
  current.expressionSettings.ports[1].mappings = [{id:'current-only', target, heel:0, toe:1}];
  current.audioDeviceConfig = {id:'physical-interface', rate:48000};
  current.inputLabels = {Guitar:'Current input alias'};
  current.midiControlSettings = {enabled:false};
  current.syncSettings = {source:'din'};
  current.audioLibrary.files = [{id:'global-file'}];
  const available = {controlConnected:[false, true, true], midiPorts:[], targetKeys:[target], mediaIssues:[],
    actions:[{key:'command:undo', label:'Undo'}, {key:'command:redo', label:'Redo'}, {key:'command:stop', label:'Stop'}]};
  return {snapshot, current, available};
}
function midiFixture() {
  const f = fixture();
  f.snapshot.expressionSettings.ports[0].mappings = [];
  f.snapshot.sessionRequirements.controlPorts = [];
  f.snapshot.midiMappings = [
    {id:'one', device:'old', source:{kind:'cc', channel:3, number:21}, behavior:'continuous', enabled:true,
      controls:[{kind:'parameter', key:target, detail:'Guitar', label:'Volume', low:.2, high:.9}]},
    {id:'two', device:'old', source:{kind:'note', channel:5, number:60}, behavior:'momentary', enabled:false,
      controls:[{kind:'action', key:'command:undo', trigger:'release'}]},
    {id:'other', device:'din', source:{kind:'program', channel:1, number:4}, behavior:'trigger', enabled:true,
      controls:[{kind:'parameter', key:target, low:0, high:.6}]}
  ];
  f.available.midiPorts = [{id:'old', name:'Keyboard', online:false},
    {id:'usb', name:'Keyboard', online:true}, {id:'din', name:'MIDI In', online:true}];
  return f;
}
const choices = (f, source = control) => repair.options(f.snapshot, f.current, f.available, source);
const apply = (f, destination = 1, source = control) => repair.repair(f.snapshot, f.current, f.available, source, destination);

test('expression repair moves every musical reference without changing physical setup or the archived snapshot', () => {
  const f = fixture(), before = copy(f);
  freeze(f);
  const option = choices(f).find(row => row.id === 1);
  assert.equal(option.enabled, true);
  assert.deepEqual(option.affected, ['Guitar · Volume']);
  const result = apply(f);
  assert.deepEqual(result.snapshot.expressionSettings.ports[0], {mappings:[], switches:[]});
  assert.deepEqual(result.snapshot.expressionSettings.ports[1].mappings, before.snapshot.expressionSettings.ports[0].mappings);
  assert.deepEqual(result.snapshot.sessionRequirements.controlPorts, [{port:1, type:'expression', switches:[]}]);
  assert.equal(result.snapshot.expressionSettings.nextId, 8);
  assert.equal(result.snapshot.expressionSettings.ports[1].type, undefined);
  assert.equal(result.snapshot.expressionSettings.ports[1].calibration, undefined);
  assert.equal(result.snapshot.expressionSettings.ports[1].switches[0].hardware, undefined);
  for (const key of ['recordedParts', 'trackLength', 'loopSettings', 'pedalSettings', 'audioLibrary']) assert.deepEqual(result.snapshot[key], before.snapshot[key]);
  assert.deepEqual(result.changes, ['CTRL 1 → CTRL 2 · Expression', 'Guitar · Volume']);
  const projected = ownership.project(f.current, result.snapshot, f.available);
  assert.equal(projected.ready, true);
  assert.deepEqual(projected.rig.expressionSettings.ports[1].calibration, {heel:.3, toe:.75});
  for (const key of ['audioDeviceConfig', 'inputLabels', 'midiControlSettings', 'syncSettings']) assert.deepEqual(projected.rig[key], before.current[key]);
  assert.deepEqual(f, before);
});

test('browsing and cancel-by-discard leave all input state unchanged and outputs share no mutable references', () => {
  const f = fixture(), before = copy(f), list = choices(f), result = apply(f);
  list[1].affected.push('Draft-only label');
  result.snapshot.expressionSettings.ports[1].mappings[0].heel = .7;
  result.changes.push('Discarded proposal');
  assert.deepEqual(f, before);
  assert.deepEqual(choices(f)[1].affected, ['Guitar · Volume']);
  assert.equal(apply(f).snapshot.expressionSettings.ports[1].mappings[0].heel, .2);
});

test('CTRL options explain wrong type, disconnected and uncalibrated replacements and apply refuses each', () => {
  for (const [change, expected] of [
    [f => f.current.expressionSettings.ports[1].type = 'dual', /expression setup/],
    [f => f.available.controlConnected[1] = false, /not connected/],
    [f => delete f.available.controlConnected, /not connected/],
    [f => f.current.expressionSettings.ports[1].calibration = null, /Calibrate/],
    [f => f.current.expressionSettings.ports[1].calibration = {heel:.3, toe:.35}, /Calibrate/],
    [f => f.current.expressionSettings.ports[1].calibration = {heel:NaN, toe:1}, /Calibrate/]
  ]) {
    const f = fixture(); change(f); const before = copy(f);
    const option = choices(f).find(row => row.id === 1);
    assert.equal(option.enabled, false); assert.match(option.reason, expected);
    assert.match(apply(f).error, expected); assert.deepEqual(f, before);
  }
});

test('an inverted but valid current expression calibration is retained', () => {
  const f = fixture(); f.current.expressionSettings.ports[1].calibration = {heel:.9, toe:.2};
  const result = apply(f);
  assert(result.snapshot);
  const projected = ownership.project(f.current, result.snapshot, f.available);
  assert.equal(projected.ready, true);
  assert.deepEqual(projected.rig.expressionSettings.ports[1].calibration, {heel:.9, toe:.2});
});

test('no incoming assigned port is overwritten, including dormant actions and rack-only dependencies', () => {
  for (const occupy of [
    f => f.snapshot.expressionSettings.ports[1].mappings.push({id:'occupied', target}),
    f => f.snapshot.expressionSettings.ports[1].switches[0].press = 'command:stop',
    f => f.snapshot.expressionSettings.ports[1].switches[0].mappings.push({id:'occupied', target}),
    f => f.snapshot.racks.push({rule:{pedal:'external:1:0', condition:'always'}}),
    f => f.snapshot.sessionRequirements.controlPorts.push({port:1, type:'expression', switches:[]})
  ]) {
    const f = fixture(); occupy(f); const before = copy(f);
    assert.equal(choices(f)[1].enabled, false);
    assert.match(apply(f).error, /already has assignments/);
    assert.deepEqual(f, before);
  }
});

test('dual-switch repair relocates actions, ranges, all rack activation references and hardware requirements together', () => {
  const f = fixture('dual'), before = copy(f.snapshot); freeze(f);
  const result = apply(f);
  assert(result.snapshot);
  assert.deepEqual(result.snapshot.expressionSettings.ports[1], before.expressionSettings.ports[0]);
  assert.deepEqual(result.snapshot.expressionSettings.ports[0], {mappings:[], switches:[]});
  assert.deepEqual(result.snapshot.racks.map(r => r.rule.pedal), ['external:1:0', 'external:1:1', 'external:2:0']);
  assert.deepEqual(result.snapshot.racks.map(r => r.rule.condition), ['held', 'on', 'always']);
  assert.deepEqual(result.snapshot.sessionRequirements.controlPorts, [{port:1, type:'dual',
    switches:[{index:0, hardware:'momentary'}, {index:1, hardware:'latching'}]}]);
  assert.deepEqual(choices(f)[1].affected, ['Button 1 · Press · Undo', 'Button 1 · Hold · Redo',
    'Button 2 · On change · Stop', 'Button 2 · Guitar · Volume',
    'Button 1 · Guitar · Space · Activation', 'Button 2 · Track 1 · Texture · Activation']);
  assert.equal(ownership.project(f.current, result.snapshot, f.available).ready, true);
  assert.deepEqual(f.snapshot, before);
});

test('required switch hardware is rechecked after selection and cannot silently change at apply', () => {
  const f = fixture('dual'); assert.equal(choices(f)[1].enabled, true);
  f.current.expressionSettings.ports[1].switches[1].hardware = 'momentary';
  const before = copy(f);
  assert.match(apply(f).error, /Button 2 needs latching hardware/);
  assert.deepEqual(f, before);
});

test('a single-switch requirement stays single and preserves its one assigned button', () => {
  const f = fixture('dual');
  f.snapshot.racks = [f.snapshot.racks[0]];
  f.snapshot.expressionSettings.ports[0].switches = [f.snapshot.expressionSettings.ports[0].switches[0]];
  f.snapshot.sessionRequirements.controlPorts = [{port:0, type:'single', switches:[{index:0, hardware:'momentary'}]}];
  f.current.expressionSettings.ports[1] = port('single');
  const result = apply(f);
  assert(result.snapshot);
  assert.deepEqual(result.snapshot.sessionRequirements.controlPorts, [{port:1, type:'single', switches:[{index:0, hardware:'momentary'}]}]);
  assert.equal(result.snapshot.expressionSettings.ports[1].switches.length, 1);
  assert.equal(result.snapshot.expressionSettings.ports[1].switches[0].press, 'command:undo');
  assert.equal(result.snapshot.racks[0].rule.pedal, 'external:1:0');
  assert.equal(ownership.project(f.current, result.snapshot, f.available).ready, true);
  f.current.expressionSettings.ports[1].type = 'dual';
  assert.match(apply(f).error, /single switch setup/);
});

test('stale CTRL disconnection, calibration, type and incoming occupation invalidate an earlier enabled choice', () => {
  for (const change of [
    f => f.available.controlConnected[1] = false,
    f => f.current.expressionSettings.ports[1].calibration = null,
    f => f.current.expressionSettings.ports[1].type = 'single',
    f => f.snapshot.expressionSettings.ports[1].mappings.push({id:'arrived', target})
  ]) {
    const f = fixture(); assert.equal(choices(f)[1].enabled, true); change(f);
    const before = copy(f); assert(apply(f).error); assert.deepEqual(f, before);
  }
});

test('repair requires an exact explicit destination and a currently assigned saved source', () => {
  const f = fixture(), before = copy(f);
  for (const destination of [undefined, '1', -1, 9, 0]) assert(repair.repair(f.snapshot, f.current, f.available, control, destination).error);
  for (const source of [null, {kind:'unknown'}, {kind:'control', port:2}, {kind:'control', port:-1}]) {
    assert.deepEqual(choices(f, source), []); assert(apply(f, 1, source).error);
  }
  const repaired = apply(f).snapshot;
  assert(repair.repair(repaired, f.current, f.available, control, 1).error);
  assert.deepEqual(f, before);
});

test('unreadable hardware requirements are refused without changing the saved data', () => {
  for (const change of [r => r.type = null, r => r.switches = null,
    r => r.switches = [{index:0, hardware:'unknown'}], r => r.switches = [{index:3, hardware:'momentary'}]]) {
    const f = fixture('dual'); change(f.snapshot.sessionRequirements.controlPorts[0]); const before = copy(f);
    assert(apply(f).error); assert.deepEqual(f, before);
  }
});

test('MIDI replacement preserves all mappings, channels, messages, ranges, targets and disabled state', () => {
  const f = midiFixture(), before = copy(f); freeze(f);
  const result = apply(f, 'usb', midi);
  assert(result.snapshot);
  assert.deepEqual(result.snapshot.midiMappings, before.snapshot.midiMappings.map(m => m.device === 'old' ? {...m, device:'usb'} : m));
  assert.deepEqual(choices(f, midi)[1].affected, ['CC 21 · Ch 3 · Guitar · Volume', 'Note 60 · Ch 5 · Undo']);
  assert.deepEqual(result.snapshot.expressionSettings, before.snapshot.expressionSettings);
  assert.equal(ownership.project(f.current, result.snapshot, f.available).ready, true);
  assert.deepEqual(f, before);
});

test('same-name MIDI inventory never guesses a replacement or treats the original ID as repaired', () => {
  const f = midiFixture(), before = copy(f);
  assert.equal(choices(f, midi)[1].label, 'Keyboard');
  assert.deepEqual(f, before);
  assert(repair.repair(f.snapshot, f.current, f.available, midi, undefined).error);
  assert(apply(f, 'Keyboard', midi).error);
  assert(apply(f, 'old', midi).error);
  assert.equal(apply(f, 'usb', midi).snapshot.midiMappings[0].device, 'usb');
});

test('MIDI source collisions include exact channels, Omni overlap in both directions and disabled mappings', () => {
  for (const [incomingChannel, destinationChannel, enabled] of [[3, 3, true], ['omni', 8, true], [3, 'omni', true], [3, 3, false]]) {
    const f = midiFixture(); f.snapshot.midiMappings[0].source.channel = incomingChannel;
    f.snapshot.midiMappings.push({id:'occupied', device:'usb', source:{kind:'cc', channel:destinationChannel, number:21}, enabled, controls:[]});
    const before = copy(f); assert.equal(choices(f, midi)[1].enabled, false);
    assert.match(apply(f, 'usb', midi).error, /overlaps a saved mapping/); assert.deepEqual(f, before);
  }
});

test('distinct MIDI channel, number or message kind remains eligible and existing destination mappings stay intact', () => {
  for (const source of [{kind:'cc', channel:4, number:21}, {kind:'cc', channel:3, number:22}, {kind:'note', channel:3, number:21}]) {
    const f = midiFixture(), existing = {id:'occupied', device:'usb', source, enabled:true, controls:[]};
    f.snapshot.midiMappings.push(existing);
    const result = apply(f, 'usb', midi);
    assert(result.snapshot); assert.deepEqual(result.snapshot.midiMappings.at(-1), existing);
  }
});

test('stale MIDI disconnection, inventory removal, new collision and missing source cannot apply', () => {
  for (const change of [
    f => f.available.midiPorts[1].online = false,
    f => f.available.midiPorts.splice(1, 1),
    f => f.snapshot.midiMappings.push({...copy(f.snapshot.midiMappings[0]), id:'arrived', device:'usb'}),
    f => f.snapshot.midiMappings = f.snapshot.midiMappings.filter(m => m.device !== 'old')
  ]) {
    const f = midiFixture(); assert.equal(choices(f, midi)[1].enabled, true); change(f);
    const before = copy(f); assert(apply(f, 'usb', midi).error); assert.deepEqual(f, before);
  }
});

test('malformed or internally colliding incoming MIDI sources are refused', () => {
  const f = midiFixture(); f.snapshot.midiMappings[0].source.channel = 17;
  assert.match(apply(f, 'usb', midi).error, /unreadable message source/);
  const g = midiFixture(); g.snapshot.midiMappings.push({...copy(g.snapshot.midiMappings[0]), id:'duplicate'});
  assert.match(apply(g, 'usb', midi).error, /overlaps/);
});

test('repair does not guess a missing parameter target and final ownership still blocks it', () => {
  const f = fixture(); f.available.targetKeys = [];
  const result = apply(f);
  assert.equal(result.snapshot.expressionSettings.ports[1].mappings[0].target, target);
  const projected = ownership.project(f.current, result.snapshot, f.available);
  assert.equal(projected.ready, false);
  assert.deepEqual(projected.issues, [{kind:'control-target', id:target}]);
});

test('browser and CommonJS expose the same options and repair results without a DOM or storage dependency', () => {
  const world = {window:{}, structuredClone};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'midi-protocol-study.js'), 'utf8'), world);
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'session-connection-repair.js'), 'utf8'), world);
  const api = world.window.SegnoSessionConnectionRepair, f = fixture();
  assert.deepEqual(Object.keys(api), ['options', 'repair']);
  assert.deepEqual(JSON.parse(JSON.stringify(api.options(f.snapshot, f.current, f.available, control))), choices(f));
  assert.deepEqual(JSON.parse(JSON.stringify(api.repair(f.snapshot, f.current, f.available, control, 1))), apply(f));
});
