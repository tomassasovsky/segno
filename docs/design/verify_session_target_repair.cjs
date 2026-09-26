const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const api = require('./session-target-repair.js');
const fx = require('./fx-parameter-descriptors.js');
const copy = value => structuredClone(value);
const missing = JSON.stringify(['fx', 'rack-old', 'removed-module', 'Del Mix']);
const replacement = JSON.stringify(['fx', 'rack-current', 'existing-module', 'Delay']);
const other = JSON.stringify(['mix', 'Guitar', 'level']);
function freeze(value) {
  if (value && typeof value === 'object') {Object.values(value).forEach(freeze);Object.freeze(value);}
  return value;
}
const parameter = (extra = {}) => ({kind:'parameter', key:missing, label:'Delay · Mix', detail:'Guitar / Old space', low:.9, high:.2, curve:'custom', ...extra});
function fixture() {
  return {
    racks:[{id:'rack-current', name:'Current space', source:'Guitar', rule:{pedal:'external:0:0', condition:'held'},
      modules:[{name:'Delay', expressionId:'existing-module', params:[['Delay', 1], ['Del Time', .7]]}]}],
    expressionSettings:{nextId:14, ports:[
      {type:'expression', calibration:{heel:.1, toe:.9}, mappings:[{id:'expression-old', target:missing, label:'Delay · Mix', detail:'Guitar / Old space', heel:.92, toe:.08, curve:'log', extra:{keep:true}}],
        switches:[{hardware:'momentary', press:'command:undo', hold:'command:redo', mappings:[{id:'held', target:missing, condition:'held', inactive:.22, active:.71}]}]},
      {type:'single', calibration:null, mappings:[{id:'dormant', target:missing, heel:.1, toe:.9}],
        switches:[{hardware:'latching', change:'command:stop', mappings:[{target:missing, condition:'on', inactive:.9, active:.1, curve:'linear'}]}]}
    ]},
    midiMappings:[
      {id:'continuous', device:'usb', source:{kind:'cc', channel:2, number:21}, behavior:'continuous', enabled:true, controls:[parameter(), {kind:'action', key:replacement, trigger:'press'}]},
      {id:'momentary', device:'keys', source:{kind:'note', channel:'omni', number:60}, behavior:'momentary', enabled:false, controls:[parameter({low:.15, high:.8})]},
      {id:'toggle', device:'din', source:{kind:'cc', channel:7, number:3}, behavior:'toggle', enabled:true, controls:[parameter({low:.8, high:.25})]},
      {id:'program', device:'usb', source:{kind:'program', channel:4, number:9}, behavior:'trigger', enabled:true, controls:[parameter({low:.17, high:.6})]}
    ],
    sessionRequirements:{controlPorts:[{port:0, type:'expression', switches:[]}, {port:1, type:'single', switches:[{index:0, hardware:'latching'}]}]},
    recordedParts:{'Track 1':['Guitar']}, trackLayers:{'Track 1':{layers:[{id:'take', beats:16}]}},
    loopSettings:{tempo:117}, inputLabels:{Guitar:'Voice'}, audioDeviceConfig:{id:'stage'}, nextExpressionModuleId:40
  };
}
const descriptor = (extra = {}) => ({key:replacement, label:'Texture', detail:'Guitar / Current space', destination:'Guitar',
  coerce:value => Math.round(value * 2) / 2, format:value => ({0:'Off', .5:'Soft', 1:'Hard'})[value],
  get:() => {throw Error('No live read');}, set:() => {throw Error('No live write');}, persist:() => {throw Error('No persistence');}, ...extra});
const targets = () => [descriptor(), descriptor({key:other, label:'Volume', detail:'Guitar', coerce:value => value, format:value => Math.round(value * 100) + '%'})];
const repair = (snapshot, list = targets(), key = replacement) => api.repair(snapshot, list, missing, key);
const values = rows => rows.map(row => row.values.map(value => [value.label, value.value]));

test('describe identifies every exact-key source and its original endpoint semantics without guessing target units', () => {
  const s = freeze(fixture()), description = api.describe(s, missing);
  assert.equal(description.label, 'Delay · Mix'); assert.equal(description.detail, 'Guitar / Old space');
  assert.deepEqual(description.affected.map(row => row.source), ['CTRL 1 · Expression', 'CTRL 1 · Button 1',
    'CTRL 2 · Expression', 'CTRL 2 · Button 1', 'MIDI usb · CC 21 · Ch 2',
    'MIDI keys · Note 60 · All channels', 'MIDI din · CC 3 · Ch 7', 'MIDI usb · Program 9 · Ch 4']);
  assert.deepEqual(values(description.affected), [
    [['Heel', .92], ['Toe', .08]], [['Released', .22], ['Held', .71]],
    [['Heel', .1], ['Toe', .9]], [['Off', .9], ['On', .1]],
    [['From', .9], ['To', .2]], [['Released', .15], ['Held', .8]],
    [['Off', .8], ['On', .25]], [['Value', .6]]
  ]);
  assert(description.affected.every(row => row.values.every(value => !Object.hasOwn(value, 'formatted'))));
});

test('preview shows exact coerced endpoints, including reverse ranges and typed labels', () => {
  const s = freeze(fixture()), preview = api.preview(s, targets(), missing, replacement);
  assert.equal(preview.error, undefined);
  assert.equal(preview.label, 'Texture'); assert.equal(preview.detail, 'Guitar / Current space');
  assert.deepEqual(values(preview.affected), [
    [['Heel', 1], ['Toe', 0]], [['Released', 0], ['Held', .5]],
    [['Heel', 0], ['Toe', 1]], [['Off', 1], ['On', 0]],
    [['From', 1], ['To', 0]], [['Released', 0], ['Held', 1]],
    [['Off', 1], ['On', .5]], [['Value', .5]]
  ]);
  assert.deepEqual(preview.affected.map(row => row.values.map(value => value.formatted)),
    [['Hard','Off'], ['Off','Soft'], ['Off','Hard'], ['Hard','Off'], ['Hard','Off'], ['Off','Hard'], ['Hard','Soft'], ['Soft']]);
  assert(preview.affected.every(row => row.values.every(value => !Object.hasOwn(value, 'field'))));
});

test('repair moves all exact references while preserving IDs, source conditions, hardware, curves and unrelated state', () => {
  const original = fixture(), before = copy(original); freeze(original);
  const result = repair(original), s = result.snapshot;
  assert(s);
  assert.deepEqual(s.expressionSettings.ports[0].mappings[0], {...before.expressionSettings.ports[0].mappings[0],
    target:replacement, label:'Texture', detail:'Guitar / Current space', heel:1, toe:0});
  assert.deepEqual(s.expressionSettings.ports[0].switches[0].mappings[0], {...before.expressionSettings.ports[0].switches[0].mappings[0],
    target:replacement, label:'Texture', detail:'Guitar / Current space', inactive:0, active:.5});
  assert.equal(s.expressionSettings.ports[1].mappings[0].target, replacement);
  assert.equal(s.expressionSettings.ports[1].switches[0].mappings[0].target, replacement);
  const expectedRanges = [[1,0], [0,1], [1,.5], [.17,.5]];
  for (let i = 0; i < s.midiMappings.length; i++) {
    assert.deepEqual(s.midiMappings[i], {...before.midiMappings[i], controls:[
      {...before.midiMappings[i].controls[0], key:replacement, label:'Texture', detail:'Guitar / Current space', low:expectedRanges[i][0], high:expectedRanges[i][1]},
      ...before.midiMappings[i].controls.slice(1)
    ]});
  }
  for (const key of ['racks','sessionRequirements','recordedParts','trackLayers','loopSettings','inputLabels','audioDeviceConfig','nextExpressionModuleId']) assert.deepEqual(s[key], before[key]);
  assert.equal(s.expressionSettings.nextId, 14);
  assert.equal(s.expressionSettings.ports[0].switches[0].press, 'command:undo');
  assert.deepEqual(s.expressionSettings.ports[0].calibration, before.expressionSettings.ports[0].calibration);
  assert.deepEqual(result.change.from, {label:'Delay · Mix', detail:'Guitar / Old space'});
  assert.deepEqual(result.change.to, {label:'Texture', detail:'Guitar / Current space'});
  assert.equal(result.change.affected.length, 8);
  assert.equal(result.change.affected[0], 'CTRL 1 · Expression · Heel: Hard · Toe: Off');
  assert.equal(result.change.affected.at(-1), 'MIDI usb · Program 9 · Ch 4 · Value: Soft');
  assert.deepEqual(original, before);
});

test('browsing, preview and cancelling by discarding their results never mutate the saved session or descriptor', () => {
  const s = fixture(), before = copy(s), list = targets(); freeze(s); freeze(list);
  const options = api.options(s, list, missing), preview = api.preview(s, list, missing, replacement), result = repair(s, list);
  options[0].label = 'Discarded choice'; preview.affected[0].values[0].value = .4;
  result.snapshot.expressionSettings.ports[0].mappings[0].extra.keep = false;
  result.change.affected.push('Discarded review');
  assert.deepEqual(s, before); assert.equal(list[0].label, 'Texture');
  assert.equal(api.describe(s, missing).affected[0].values[0].value, .92);
});

for (const removal of ['module', 'parameter']) {
  test('actual FX catalogue repairs a removed ' + removal + ' without generating identities or changing the effect', () => {
    const s = fixture();
    s.racks.unshift({id:'rack-old', name:'Old space', source:'Guitar', modules:[{name:'Delay', expressionId:'removed-module', params:[['Delay',1], ['Del Mix',.5]]}]});
    if (removal === 'module') s.racks[0].modules = [];
    else s.racks[0].modules[0].params = [['Delay',1]];
    const before = copy(s); freeze(s);
    const catalogue = fx.targets(s), selected = catalogue.find(t => t.key === replacement);
    assert(selected); assert(!catalogue.some(t => t.key === missing));
    const p = api.preview(s, catalogue, missing, replacement), result = repair(s, catalogue);
    assert.equal(p.error, undefined); assert.equal(result.error, undefined);
    assert.deepEqual(p.affected[0].values.map(v => [v.value,v.formatted]), [[1,'On'], [0,'Off']]);
    assert.deepEqual(result.snapshot.racks, before.racks);
    assert.equal(result.snapshot.nextExpressionModuleId, 40);
    assert.deepEqual(s, before);
  });
}

test('unverified FX parameters retain Source-number formatting instead of invented units or enums', () => {
  const s = freeze(fixture()), catalogue = fx.targets(s), key = JSON.stringify(['fx','rack-current','existing-module','Del Time']);
  const p = api.preview(s, catalogue, missing, key), result = repair(s, catalogue, key);
  assert.equal(p.error, undefined);
  assert.deepEqual(p.affected[0].values.map(v => [v.value,v.formatted]), [[.92,'Source 0.92'], [.08,'Source 0.08']]);
  assert.equal(result.snapshot.expressionSettings.ports[0].mappings[0].heel, .92);
  assert.equal(result.snapshot.expressionSettings.ports[0].mappings[0].toe, .08);
});

test('a restored original target is not missing even when its live control is temporarily disabled', () => {
  const s = freeze(fixture()), list = [...targets(), descriptor({key:missing, enabled:false})];
  assert(api.options(s, list, missing).every(choice => !choice.enabled && /available again/.test(choice.reason)));
  assert.match(api.preview(s, list, missing, replacement).error, /available again/);
  assert.match(repair(s, list).error, /available again/);
});

test('a selected target disappearing or being renamed to a different identity cannot be applied', () => {
  const s = fixture(), before = copy(s), original = targets();
  assert.equal(api.preview(s, original, missing, replacement).error, undefined);
  for (const list of [[], [descriptor({key:'different-id'})]]) {
    assert.match(repair(s, list).error, /no longer available/);
    assert.match(api.preview(s, list, missing, replacement).error, /no longer available/);
  }
  for (const key of [undefined, 'Texture', JSON.parse(replacement)]) assert(api.repair(s, original, missing, key).error);
  assert.deepEqual(s, before);
});

test('replacement collisions are refused independently within every affected source context, with no partial repair', () => {
  for (const collide of [
    s => s.expressionSettings.ports[0].mappings.push({id:'existing', target:replacement, heel:0, toe:1}),
    s => s.expressionSettings.ports[0].switches[0].mappings.push({target:replacement, condition:'on', inactive:0, active:1}),
    s => s.midiMappings[1].controls.push(parameter({key:replacement}))
  ]) {
    const s = fixture(); collide(s); const before = copy(s);
    const choice = api.options(s, targets(), missing).find(t => t.key === replacement);
    assert.equal(choice.enabled, false); assert.match(choice.reason, /already controls/);
    assert.match(repair(s).error, /already controls/); assert.deepEqual(s, before);
  }
});

test('replacement use in unrelated source contexts and MIDI action controls is preserved and does not collide', () => {
  const s = fixture();
  s.expressionSettings.ports.push({mappings:[{id:'unrelated', target:replacement, heel:.3, toe:.8}], switches:[]});
  s.midiMappings.push({id:'unrelated-midi', device:'keys', source:{kind:'cc', channel:1, number:2}, behavior:'continuous', controls:[parameter({key:replacement})]});
  const unrelatedPort = copy(s.expressionSettings.ports[2]), unrelatedMidi = copy(s.midiMappings.at(-1)), result = repair(s);
  assert(result.snapshot);
  assert.deepEqual(result.snapshot.expressionSettings.ports[2], unrelatedPort);
  assert.deepEqual(result.snapshot.midiMappings.at(-1), unrelatedMidi);
  assert.deepEqual(result.snapshot.midiMappings[0].controls[1], s.midiMappings[0].controls[1]);
});

test('duplicate missing-key entries in one source context refuse instead of producing duplicate parameter writes', () => {
  for (const duplicate of [
    s => s.expressionSettings.ports[0].mappings.push({...copy(s.expressionSettings.ports[0].mappings[0]), id:'duplicate'}),
    s => s.expressionSettings.ports[0].switches[0].mappings.push(copy(s.expressionSettings.ports[0].switches[0].mappings[0])),
    s => s.midiMappings[0].controls.push(copy(s.midiMappings[0].controls[0]))
  ]) {
    const s = fixture(); duplicate(s); const before = copy(s);
    assert(api.options(s, targets(), missing).every(t => !t.enabled));
    assert.match(repair(s).error, /duplicate assignments/); assert.deepEqual(s, before);
  }
});

test('all nonfinite, nonnumeric and out-of-range saved endpoints refuse before any mapping changes', () => {
  const slots = [s => [s.expressionSettings.ports[0].mappings[0], 'heel'],
    s => [s.expressionSettings.ports[0].switches[0].mappings[0], 'inactive'],
    s => [s.midiMappings[0].controls[0], 'high']];
  for (const slot of slots) for (const value of [NaN, Infinity, -Infinity, '0.5', null, undefined, -.1, 1.1]) {
    const s = fixture(), [mapping, field] = slot(s); mapping[field] = value; const before = copy(s);
    assert.match(repair(s).error, /invalid saved endpoint/);
    assert.match(api.preview(s, targets(), missing, replacement).error, /invalid saved endpoint/);
    assert.deepEqual(s, before);
  }
});

test('invalid or throwing coercion and formatting cannot leave an earlier affected mapping repaired', () => {
  for (const change of [
    {coerce:() => NaN}, {coerce:() => Infinity}, {coerce:() => true}, {coerce:() => 2},
    {coerce:() => {throw Error('Unreadable range');}}, {format:() => {throw Error('Unreadable enum');}},
    {format:() => undefined}, {format:() => ''}
  ]) {
    const s = fixture(), before = copy(s), list = [descriptor(change)];
    assert.equal(api.options(s, list, missing)[0].enabled, false);
    assert.match(repair(s, list).error, /could not represent/); assert.deepEqual(s, before);
  }
});

test('Program only coerces and reviews Value; unused low survives unchanged or remains absent', () => {
  for (const stored of [true, false]) {
    const s = fixture(); if (!stored) delete s.midiMappings[3].controls[0].low;
    const p = api.preview(s, targets(), missing, replacement), result = repair(s);
    assert.deepEqual(p.affected.at(-1).values, [{label:'Value', value:.5, formatted:'Soft'}]);
    assert.equal(result.snapshot.midiMappings[3].controls[0].high, .5);
    assert.equal(Object.hasOwn(result.snapshot.midiMappings[3].controls[0], 'low'), stored);
    if (stored) assert.equal(result.snapshot.midiMappings[3].controls[0].low, .17);
  }
});

test('unreadable source containers, switch conditions and MIDI message sources refuse repair', () => {
  for (const corrupt of [
    s => s.expressionSettings.ports = {}, s => s.expressionSettings.ports[0].mappings = null,
    s => s.expressionSettings.ports[0].switches[0].mappings[0].condition = 'unknown',
    s => s.midiMappings[0].controls = 'invalid', s => s.midiMappings[0].source = null,
    s => s.midiMappings[0].source.channel = 17, s => s.midiMappings[0].source.kind = 'pitchbend',
    s => s.midiMappings[0].device = '', s => s.midiMappings[0].behavior = 'unknown'
  ]) {
    const s = fixture(); corrupt(s); const before = copy(s);
    assert.match(repair(s).error, /unreadable/); assert.deepEqual(s, before);
  }
});

test('a no-longer-assigned source, locked candidate or unreadable descriptor never applies', () => {
  const s = fixture();
  assert.match(api.repair(s, targets(), 'no-saved-key', replacement).error, /no longer assigned/);
  for (const change of [{enabled:false}, {enabled:() => false}, {format:undefined}, {label:''}, {coerce:'invalid'}]) {
    const list = [descriptor(change)]; assert.equal(api.options(s, list, missing)[0].enabled, false); assert(repair(s, list).error);
  }
  assert.match(repair(s, [descriptor(), descriptor()]).error, /ambiguous target identity/);
});

test('new collisions and invalid endpoints after preview are revalidated at repair', () => {
  for (const change of [s => s.midiMappings[0].controls.push(parameter({key:replacement})),
    s => s.expressionSettings.ports[1].mappings[0].toe = NaN]) {
    const s = fixture(); assert.equal(api.preview(s, targets(), missing, replacement).error, undefined); change(s);
    const before = copy(s); assert(repair(s).error); assert.deepEqual(s, before);
  }
});

test('missing saved labels stay generic and optional coercion preserves exact normalized values', () => {
  const s = fixture();
  for (const port of s.expressionSettings.ports) for (const m of port.mappings) {delete m.label;delete m.detail;}
  for (const m of s.midiMappings) for (const c of m.controls) {delete c.label;delete c.detail;}
  const description = api.describe(s, missing);
  assert.equal(description.label, 'Missing control'); assert.equal(description.detail, '');
  const p = api.preview(s, [descriptor({coerce:undefined, format:v => 'Normalized ' + v})], missing, replacement);
  assert.equal(p.affected[0].values[0].value, .92);
  assert.equal(p.affected[0].values[0].formatted, 'Normalized 0.92');
});

test('option rows preserve supplied destination labels and readable scale notes without exporting descriptor functions', () => {
  const s = fixture(), list = [descriptor({destination:'Track 1', destinationLabel:'Verse', type:'unresolved'}),
    descriptor({key:other, destination:'Guitar', destinationLabel:'Stage microphone', note:'Normalized volume'})];
  const choices = api.options(s, list, missing);
  assert.equal(choices[0].destination, 'Track 1');
  assert.equal(choices[0].destinationLabel, 'Verse');
  assert.equal(choices[0].note, 'Scale unverified · source values');
  assert.equal(choices[1].destinationLabel, 'Stage microphone');
  assert.equal(choices[1].note, 'Normalized volume');
  assert.deepEqual(copy(choices), JSON.parse(JSON.stringify(choices)));
  assert(!Object.values(choices[0]).some(value => typeof value === 'function'));
});

test('browser and CommonJS expose identical pure behavior without DOM, storage or descriptor writes', () => {
  const world = {window:{}, structuredClone};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'midi-protocol-study.js'), 'utf8'), world);
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'session-target-repair.js'), 'utf8'), world);
  const browser = world.window.SegnoSessionTargetRepair, s = freeze(fixture()), list = freeze(targets());
  assert.deepEqual(Object.keys(browser), ['describe','options','preview','repair']);
  for (const [method, args] of [['describe',[s, missing]], ['options',[s, list, missing]],
    ['preview',[s, list, missing, replacement]], ['repair',[s, list, missing, replacement]]]) {
    assert.deepEqual(JSON.parse(JSON.stringify(browser[method](...args))), JSON.parse(JSON.stringify(api[method](...args))));
  }
});
