const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ownership = require('./session-field-ownership.js');
const recovery = require('./session-recovery-model.js');
const copy = value => structuredClone(value);
const target = JSON.stringify(['mix', 'Guitar', 'level']);
const file = id => ({id, name:'Backing.wav', seconds:24, format:'WAV'});
const switchConfig = hardware => ({hardware, press:'command:undo', hold:'command:redo', change:'none', mappings:[]});
function rig() {
  return {
    racks:[{id:'rack-1', source:'Guitar', rule:{pedal:0, condition:'held'}, modules:[{name:'Delay', params:[['Mix', .3]]}]}],
    channels:{'rack-1':{pan:['Pan', .25]}}, nextId:9, latched:[true, false],
    pedalSettings:{palette:{custom:'#123456'}, leds:['Blue'], recordHold:'Undo recording', custom:[{press:'New loop', hold:'Peel'}]},
    expressionSettings:{nextId:4, ports:[
      {type:'expression', calibration:{heel:.1, toe:.9}, mappings:[{id:'expression-3', target, heel:.2, toe:.8}], switches:[switchConfig('momentary'), switchConfig('momentary')]},
      {type:'dual', calibration:null, mappings:[], switches:[switchConfig('momentary'), switchConfig('latching')]}
    ]},
    midiMappings:[{id:'midi-one', device:'keys', enabled:true, source:{kind:'cc', channel:2, number:1}, controls:[{kind:'parameter', key:target, low:.2, high:.8}]}],
    midiControlSettings:{enabled:true}, syncSettings:{source:'din', outputs:{din:{clock:true, offset:3}}},
    recordedParts:{'Track 1':['Guitar']}, trackPlayback:{'Track 1':true}, trackLabels:{'Track 1':'Verse'},
    trackLayers:{'Track 1':{layers:[{id:'take-1', beats:4, regions:[{offsetBeats:6, beats:4}]}]}},
    trackLength:{'Track 1':{audio:[], durationBeats:16}}, editHistory:{serial:1, tracks:[{undo:[{id:1}], redo:[]}]},
    loopSettings:{mode:'multi', tempo:111.5, signature:'4/4'}, liveMonitoring:{Guitar:'auto'}, recordingInputs:{'Track 1':['Guitar']},
    inputSetup:{stereoPairs:['Input 3'], trimDb:{Guitar:-3}}, audioRouting:{outputs:{main:['Guitar']}}, expressionMix:{Guitar:{level:.4, pan:.2}},
    trackPitch:{'Track 1':3}, trackFade:{'Track 1':{from:.6, to:.6, startedAt:0, durationMs:0}},
    audioDeviceConfig:{id:'stage', rate:48000, measurement:{samples:20}}, tunerSettings:{reference:440},
    inputLabels:{Guitar:'Voice'}, outputLabels:{main:'PA'}, saved:[{id:'old-preset'}],
    audioLibrary:{files:[file('backing')], usbFiles:[file('usb-old')], nextId:2, prepared:['backing'], backing:file('backing'), backingEnd:'next', trackImports:{}},
    performanceRecording:{nextId:2, last:{id:'performance-1'}}, sessionLibrary:{current:{id:'current'}, sessions:[]},
    externalLatched:[[false, false], [true, false]], controllerConfig:{connected:true, identity:'pedal-A'},
    held:[true, true], lastTransportEvent:{action:'play'}
  };
}
function availability(session) {
  return {controlConnected:[true, true], midiPorts:[{id:'keys', online:true}], targetKeys:[target],
    mediaIssues:recovery.inspect(session, [file('backing')])};
}
function freeze(value) {
  for (const child of Object.values(value)) if (child && typeof child === 'object') freeze(child);
  return Object.freeze(value);
}

test('capture contains musical mappings and exact references, excluding physical setup and global catalogues', () => {
  const source = freeze(rig()), saved = ownership.capture(source);
  assert.deepEqual(saved.pedalSettings, source.pedalSettings);
  assert.deepEqual(saved.midiMappings, source.midiMappings);
  assert.deepEqual(saved.inputSetup, source.inputSetup);
  assert.deepEqual(saved.expressionSettings.ports[0].mappings, source.expressionSettings.ports[0].mappings);
  assert.equal(saved.expressionSettings.ports[0].calibration, undefined);
  assert.equal(saved.expressionSettings.ports[0].type, undefined);
  assert.equal(saved.expressionSettings.ports[1].switches[1].hardware, undefined);
  assert.deepEqual(saved.sessionRequirements.controlPorts, [
    {port:0, type:'expression', switches:[]},
    {port:1, type:'dual', switches:[{index:0, hardware:'momentary'}, {index:1, hardware:'latching'}]}
  ]);
  for (const key of ['audioDeviceConfig', 'tunerSettings', 'inputLabels', 'outputLabels', 'saved', 'sessionLibrary',
    'performanceRecording', 'controllerConfig', 'held', 'externalLatched', 'midiControlSettings', 'syncSettings', 'lastTransportEvent']) {
    assert.equal(Object.hasOwn(saved, key), false, key);
  }
  assert.deepEqual(Object.keys(saved.audioLibrary).sort(), ['backing', 'backingEnd', 'prepared', 'trackImports']);
  assert.deepEqual(saved.trackPlayback, {'Track 1':false});
  assert.deepEqual(source.trackPlayback, {'Track 1':true});
});

test('recalling A after physical setup changes keeps current hardware and newer catalogues while restoring A music', () => {
  const original = rig(), saved = ownership.capture(original), current = rig();
  current.audioDeviceConfig = {id:'spare', rate:96000, measurement:{samples:81}};
  current.inputLabels.Guitar = 'Current alias'; current.outputLabels.main = 'Current PA';
  current.controllerConfig = {connected:false, identity:'pedal-B'};
  current.expressionSettings.ports[0].calibration = {heel:.25, toe:.7};
  current.pedalSettings.custom[0].press = 'Stop'; current.pedalSettings.leds[0] = 'Red';
  current.inputSetup = {stereoPairs:[], trimDb:{Guitar:6}};
  current.midiControlSettings.enabled = false; current.syncSettings.source = 'usb';
  current.saved.push({id:'new-preset'}); current.audioLibrary.files.push(file('new-audio'));
  current.audioLibrary.usbFiles = [file('usb-current')]; current.audioLibrary.nextId = 40;
  current.audioLibrary.backing = file('new-audio'); current.audioLibrary.prepared = ['new-audio'];
  current.performanceRecording.last.id = 'performance-new';
  const before = copy(current); freeze(current); freeze(saved);
  const result = ownership.project(current, saved, availability(saved));
  assert.equal(result.ready, true); assert.deepEqual(result.issues, []);
  for (const key of ['audioDeviceConfig', 'inputLabels', 'outputLabels', 'controllerConfig', 'saved', 'performanceRecording',
    'sessionLibrary', 'tunerSettings', 'externalLatched', 'midiControlSettings', 'syncSettings']) assert.deepEqual(result.rig[key], before[key], key);
  assert.deepEqual(result.rig.expressionSettings.ports[0].calibration, {heel:.25, toe:.7});
  for (const key of ['pedalSettings', 'inputSetup', 'midiMappings', 'recordedParts', 'trackLabels', 'editHistory', 'loopSettings', 'audioRouting']) {
    assert.deepEqual(result.rig[key], original[key], key);
  }
  for (const key of ['files', 'usbFiles', 'nextId']) assert.deepEqual(result.rig.audioLibrary[key], before.audioLibrary[key]);
  assert.deepEqual(result.rig.audioLibrary.prepared, ['backing']);
  assert.deepEqual(result.rig.trackPlayback, {'Track 1':false});
  assert.deepEqual(current, before);
  result.rig.expressionSettings.ports[0].mappings[0].heel = .9;
  result.rig.audioLibrary.files[0].name = 'Draft edit';
  assert.equal(saved.expressionSettings.ports[0].mappings[0].heel, .2);
  assert.equal(current.audioLibrary.files[0].name, 'Backing.wav');
});

test('a stale saved CTRL type cannot replace physical setup or open until its requirement is resolved', () => {
  const saved = ownership.capture(rig()), current = rig();
  current.expressionSettings.ports[0].type = 'single';
  current.expressionSettings.ports[0].calibration = {heel:.3, toe:.85};
  const result = ownership.project(current, saved, availability(saved));
  assert.equal(result.ready, false);
  assert.deepEqual(result.issues, [{kind:'control-type', source:'CTRL 1', port:0, expected:'expression', actual:'single'}]);
  assert.equal(result.rig.expressionSettings.ports[0].type, 'single');
  assert.deepEqual(result.rig.expressionSettings.ports[0].calibration, current.expressionSettings.ports[0].calibration);
  assert.equal(result.rig.expressionSettings.ports[0].mappings[0].target, target);
  current.expressionSettings.ports[0].type = 'expression';
  assert.equal(ownership.project(current, saved, availability(saved)).ready, true);
});

test('missing ports, calibration, connection and switch hardware remain explicit without replacement guesses', () => {
  const saved = ownership.capture(rig()), current = rig();
  current.expressionSettings.ports[0].calibration = null;
  current.expressionSettings.ports[1].switches[1].hardware = 'momentary';
  const available = availability(saved); available.controlConnected[0] = false;
  const result = ownership.project(current, saved, available);
  assert.deepEqual(result.issues.map(row => row.kind), ['control-connection', 'control-calibration', 'switch-hardware']);
  assert.equal(result.rig.expressionSettings.ports[0].calibration, null);
  assert.equal(result.rig.expressionSettings.ports[1].switches[1].hardware, 'momentary');
  current.expressionSettings.ports.pop();
  assert(ownership.project(current, saved, available).issues.some(row => row.kind === 'control-type' && row.actual === null));
});

test('rack activation alone records a required external switch and preserves its original source', () => {
  const source = rig();
  source.expressionSettings.ports[1].switches.forEach(s => Object.assign(s, {press:'none', hold:'none'}));
  source.racks[0].rule = {pedal:'external:1:1', condition:'on'};
  const saved = ownership.capture(source);
  assert.deepEqual(saved.sessionRequirements.controlPorts[1], {port:1, type:'dual', switches:[{index:1, hardware:'latching'}]});
  const current = rig(); current.expressionSettings.ports[1].type = 'single';
  const result = ownership.project(current, saved, availability(saved));
  assert.equal(result.ready, false);
  assert.equal(result.rig.racks[0].rule.pedal, 'external:1:1');
});

test('missing MIDI device and parameter identities block even when a similarly named source is available', () => {
  const saved = ownership.capture(rig()), available = availability(saved);
  available.midiPorts = [{id:'different', name:'Keyboard', online:true}, {id:'keys', online:false}];
  available.targetKeys = [JSON.stringify(['mix', 'Renamed guitar', 'level'])];
  const result = ownership.project(rig(), saved, available);
  assert.equal(result.ready, false);
  assert.deepEqual(result.issues, [{kind:'midi-device', id:'keys'}, {kind:'control-target', id:target}]);
  assert.deepEqual(result.rig.midiMappings, saved.midiMappings);
  assert.equal(result.rig.expressionSettings.ports[0].mappings[0].target, target);
});

test('missing media stays missing in the current catalogue until existing recovery explicitly repairs the snapshot', () => {
  const saved = ownership.capture(rig()), current = rig();
  current.audioLibrary.files = [file('replacement')];
  const available = availability(saved); available.mediaIssues = recovery.inspect(saved, current.audioLibrary.files);
  const result = ownership.project(current, saved, available);
  assert.equal(result.ready, false); assert.equal(result.issues[0].kind, 'media');
  assert.equal(result.rig.audioLibrary.backing.id, 'backing');
  assert.deepEqual(result.rig.audioLibrary.files, current.audioLibrary.files);
  const pending = recovery.repair(saved, 'backing', current.audioLibrary.files[0], current.audioLibrary.files);
  available.mediaIssues = recovery.inspect(pending, current.audioLibrary.files);
  assert.equal(ownership.project(current, pending, available).ready, true);
  assert.equal(saved.audioLibrary.backing.id, 'backing');
});

test('absent availability evidence never certifies an unresolved required connection or media', () => {
  const saved = ownership.capture(rig()), result = ownership.project(rig(), saved);
  assert.equal(result.ready, false);
  assert.deepEqual(result.issues.map(row => row.kind), ['control-connection', 'control-connection', 'midi-device', 'control-target', 'media-unverified']);
});

test('a mapping without a declared physical requirement cannot silently adopt the current pedal type', () => {
  const source = rig();
  delete source.expressionSettings.ports[0].type;
  const saved = ownership.capture(source), result = ownership.project(rig(), saved, availability(saved));
  assert.equal(result.ready, false);
  assert.deepEqual(result.issues, [{kind:'control-type', source:'CTRL 1', port:0, expected:null, actual:'expression'}]);
  assert.equal(result.rig.expressionSettings.ports[0].mappings[0].target, target);
});

test('absent session musical fields clear current music while unknown current appliance fields survive', () => {
  const current = rig(); current.futurePhysicalSetting = {identity:'new'};
  const saved = ownership.capture({racks:[], recordedParts:{'Track 1':[]}, audioLibrary:{prepared:[], backing:null, trackImports:{}}});
  const result = ownership.project(current, saved);
  assert.equal(result.ready, true);
  assert.equal(result.rig.pedalSettings, undefined);
  assert.equal(result.rig.trackPitch, undefined);
  assert.deepEqual(result.rig.expressionSettings.ports[0].mappings, []);
  assert.equal(result.rig.expressionSettings.ports[1].switches[0].press, 'none');
  assert.deepEqual(result.rig.futurePhysicalSetting, {identity:'new'});
});

test('captured snapshot survives JSON roundtrip and repeated capture without losing required hardware or music', () => {
  const saved = ownership.capture(rig()), decoded = JSON.parse(JSON.stringify(saved));
  assert.deepEqual(ownership.capture(decoded), saved);
  assert.equal(ownership.project(rig(), decoded, availability(decoded)).ready, true);
});

test('browser and CommonJS expose the same pure projection', () => {
  const world = {window:{}, structuredClone};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'session-field-ownership.js'), 'utf8'), world);
  const saved = ownership.capture(rig());
  assert.deepEqual(Object.keys(world.window.SegnoSessionFieldOwnership), ['capture', 'project']);
  assert.deepEqual(JSON.parse(JSON.stringify(world.window.SegnoSessionFieldOwnership.project(rig(), saved, availability(saved)))), ownership.project(rig(), saved, availability(saved)));
});

function library() {
  const world = {window:{}, Date, structuredClone, document:{querySelector:()=>null}, setTimeout, clearTimeout};
  vm.createContext(world);
  for (const name of ['session-preview-study.js', 'performance-recording-model.js', 'recorded-audio-model.js', 'session-recovery-model.js', 'session-recovery-study.js', 'session-library-study.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, name), 'utf8'), world);
  }
  const tracks = Object.fromEntries(Array.from({length:8}, (_, i) => ['Track ' + (i + 1), []]));
  let snapshot = {racks:[], recordedParts:tracks, trackPlayback:{}, trackLabels:{}, liveMonitoring:{}, recordingInputs:{}, loopSettings:{tempo:120}, audioLibrary:{prepared:[], trackImports:{}}};
  let state = {nextId:3, current:{id:'session-1', name:'Current'}, sessions:[{id:'session-2', name:'Earlier', snapshot:copy(snapshot)}], folders:[]};
  let issues = [{kind:'control-connection', source:'CTRL 1', port:0}], commits = 0, staged = 0, fail = false;
  const ui = world.window.createSessionLibraryStudy({
    button:(id, title)=>`<button data-action="${id}">${title}</button>`, header:()=>'', icon:()=>'', escape:String,
    render:()=>{}, setFocus:()=>{}, active:()=>true, live:()=>({tracks:[]}), waveform:()=>'',
    ownership:()=>copy(issues), files:()=>[], read:()=>state, capture:()=>copy(snapshot), fresh:copy,
    commit:(next, incoming)=>{commits++; if (fail) return false; state=copy(next); snapshot=copy(incoming); return true;},
    metadata:next=>{state=copy(next); return true;}, stage:()=>staged++, open:()=>{}, notice:()=>{},
    capturing:()=>false, transferring:()=>false, playing:()=>false, ready:()=>true,
    backup:()=>({busy:()=>false, overlay:()=>'', back:()=>false})
  });
  return {ui, open:()=>ui.command('next'), state:()=>copy(state), live:()=>copy(snapshot),
    mutate:fn=>fn(state), issues:value=>issues=value, fail:value=>fail=value, commits:()=>commits, staged:()=>staged};
}

test('dependency retry rechecks availability and publishes only after resolution', () => {
  const s=library(), before=s.state();
  assert.equal(s.open(), false); assert.equal(s.ui.snapshot().dialog.type, 'dependencies');
  s.ui.action('session:dependency-retry'); assert.equal(s.commits(), 0); assert.deepEqual(s.state(), before);
  s.issues([]); s.ui.action('session:dependency-retry');
  assert.equal(s.state().current.id, 'session-2'); assert.equal(s.commits(), 1); assert.equal(s.staged(), 1);
  assert.equal(s.ui.snapshot().dialog, null);
});

test('dependency retry rejects actual saved-source mutation or removal', () => {
  for (const remove of [false, true]) {
    const s=library(), live=s.live(); s.open();
    s.mutate(state=>{if (remove) state.sessions=[]; else state.sessions[0].snapshot.loopSettings.tempo=144;});
    const latest=s.state(); s.issues([]); s.ui.action('session:dependency-retry');
    assert.match(s.ui.snapshot().error, /saved session changed/);
    assert.equal(s.commits(), 0); assert.equal(s.staged(), 0); assert.deepEqual(s.state(), latest); assert.deepEqual(s.live(), live);
  }
});

test('dependency Cancel, Back, Library, reveal and unrelated navigation retire pending recall', () => {
  for (const leave of [s=>s.ui.action('session:dependency-cancel'), s=>s.ui.back(),
    s=>s.ui.action('session:library'), s=>s.ui.reveal('session-1'), s=>s.ui.leave('stage')]) {
    const s=library(), before=s.state(); s.open(); leave(s); s.issues([]); s.ui.action('session:dependency-retry');
    assert.equal(s.ui.snapshot().dialog, null); assert.equal(s.commits(), 0); assert.deepEqual(s.state(), before);
  }
});

test('failed publication after dependencies resolve retains live and saved states; reopening retries', () => {
  const s=library(), before=s.state(), live=s.live(); s.open(); s.issues([]); s.fail(true);
  s.ui.action('session:dependency-retry');
  assert.match(s.ui.snapshot().error, /Nothing was changed/); assert.deepEqual(s.state(), before); assert.deepEqual(s.live(), live); assert.equal(s.staged(), 0);
  s.fail(false); assert.equal(s.open(), true); assert.equal(s.state().current.id, 'session-2');
});
