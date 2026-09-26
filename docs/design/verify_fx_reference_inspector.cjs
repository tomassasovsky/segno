const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const data = require('./fx-reference-evidence.js');
const model = require('./fx-reference-inspector.js');
const context = {window: {}};
vm.runInNewContext(fs.readFileSync(__dirname + '/looperx-factory/catalog.js', 'utf8'), context);
const catalogue = JSON.parse(JSON.stringify(context.window.LOOPERX_FACTORY));
const control = (family, key) => data.controls.find(row => row.family === family && row.key === key);

test('inventory contains all exact family/key identities and distinguishes enables', () => {
  const expected = catalogue.families.flatMap(f => [...new Set(f.presets.flatMap(p => Object.keys(p.parameters)))].map(key => JSON.stringify([f.name,key]))).sort();
  assert.deepEqual(data.controls.map(c => JSON.stringify([c.family,c.key])).sort(), expected);
  assert.equal(new Set(expected).size, 300);
  assert.equal(data.controls.filter(c => c.status === 'module-enable').length, 61);
  assert.equal(data.controls.filter(c => c.status === 'unresolved').length, 239);
});
test('exact zero-valued presets survive and no family or preset fallback occurs', () => {
  const family = catalogue.families.find(f => f.name === "Ed's Rack"), first = family.presets[0];
  assert.equal(model.presetValue(catalogue, control(family.name, 'Amp'), first.id).value, 0);
  assert.equal(model.presetValue(catalogue, control(family.name, 'Amp Drive'), first.id).value, first.parameters['Amp Drive']);
  assert.equal(model.presetValue(catalogue, control('Guitar Rack', 'Amp Drive'), first.id), null);
  assert.equal(model.presetValue(catalogue, {...control(family.name, 'Amp'), key:'missing'}, first.id), null);
  assert.equal(model.presetValue(catalogue, control(family.name, 'Amp'), 'missing'), null);
});
test('same-named controls never inherit another family constructor', () => {
  assert.equal(model.constructorEvidence(data, control("Ed's Rack", 'Cab')).nativeIndex, 25);
  assert.equal(model.constructorEvidence(data, control('Guitar Rack', 'Cab')), null);
});
test('captured constructor has exact Ed schema and keeps duplicate cabinet argument', () => {
  const expected = data.controls.filter(c => c.family === "Ed's Rack").map(c => c.key).sort();
  assert.deepEqual(data.native.records.map(c => c.sourceKey).sort(), expected);
  const cab = data.native.records.find(c => c.sourceKey === 'Cab');
  assert.equal(cab.stringListArguments.length, 12);
  assert.equal(cab.stringListArguments[6], '4x10"');
  assert.equal(cab.stringListArguments[10], '4x10"');
  assert.deepEqual(cab.integerArguments, [6,6]);
});
test('constructor arguments never become legal domains or reset defaults', () => {
  for (const c of data.controls) {assert.equal(c.nativeDomain, null); assert.equal(c.nativeDefault, null);}
  for (const c of data.singles) assert.equal(c.nativeSchema, null);
  assert.match(data.native.limits, /No builder execution/);
});
test('search and status filters remain collection specific', () => {
  assert.equal(model.matching(data, {family:"Ed's Rack",search:' amp drive ',status:'unresolved'}).length, 1);
  assert.equal(model.matching(data, {family:"Ed's Rack",search:'amp drive',status:'module-enable'}).length, 0);
  assert.equal(model.matching(data, {tab:'audio',search:'035 6-8 Brushes 1.wav',family:'missing',status:'module-enable'}).length, 1);
  assert.equal(model.matching(data, {tab:'singles',search:'missing'}).length, 0);
});
test('missing-source download preserves all unresolved identities without promoting audio', () => {
  const before = JSON.stringify(data), result = model.missingSources(data);
  assert.equal(result.unresolvedControls.length, 239);
  assert.equal(result.unresolvedSingles.length, 26);
  assert.equal(result.unavailableFactoryAudio.length, 302);
  assert.equal(result.unavailableFactoryAudio.reduce((n,r) => n+r.expectedBytes,0), 485392756);
  assert(data.audio.every(a => a.available === false));
  result.unresolvedControls[0].key = 'edited download';
  assert.equal(JSON.stringify(data), before);
});
