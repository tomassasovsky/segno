const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const recovery = require('./session-recovery-model.js');
const copy = value => structuredClone(value);
const file = (id, seconds = 24, format = 'WAV') => ({id, name:id + '.wav', seconds, format, folder:'Saved audio'});
const imported = descriptor => ({file:copy(descriptor), state:'stopped', speed:1, sourceLocation:'internal', originalSourceLocation:'usb', timing:{policy:'unchanged', seconds:24, loopTempo:120, bars:12, metadataSource:'fixture'}});
function fixture() {
  const missing = file('missing');
  return {name:'Evening set', trackLabels:{0:'Guitar', 3:'Harmony'}, expressionMix:{Backing:{level:.6, pan:.2}}, trackLayers:{Guitar:{layers:[{gain:.7, beats:48}]}}, audioLibrary:{prepared:['missing', 'second'], backing:copy(missing), backingEnd:'next', trackImports:{0:imported(missing), 3:imported(missing)}}};
}
function freeze(value) {
  for (const child of Object.values(value)) if (child && typeof child === 'object') freeze(child);
  return Object.freeze(value);
}

test('browser and CommonJS entrypoints expose the same recovery behavior', () => {
  const world = {window:{}, structuredClone};
  for(const name of ['performance-recording-model.js','recorded-audio-model.js','session-recovery-model.js'])vm.runInNewContext(fs.readFileSync(path.join(__dirname, name), 'utf8'), world);
  assert.deepEqual(Object.keys(world.window.SegnoSessionRecovery), ['valid', 'inspect', 'candidates', 'repair']);
  assert.deepEqual(world.window.SegnoSessionRecovery.inspect(fixture(), []), recovery.inspect(fixture(), []));
});
test('malformed candidates cannot produce invalid session references',()=>{
 const snapshot=fixture(),problem=recovery.inspect(snapshot,[])[0];
 const malformed={id:'candidate',seconds:24,format:'WAV'};
 assert.deepEqual(recovery.candidates(problem,[malformed]),[]);
 assert.throws(()=>recovery.repair(snapshot,problem.id,malformed,[malformed]),/no longer available/);
 assert.equal(recovery.valid({audioLibrary:{prepared:{broken:true}}}),false);
});

test('inspection deduplicates shared dependencies and distinguishes missing, unreadable and changed imports', () => {
  const snapshot = fixture();
  snapshot.audioLibrary.prepared.push('missing', 'broken');
  const missing = recovery.inspect(snapshot, [file('second'), {...file('broken'), unreadable:true}]);
  assert.deepEqual(missing, [
    {id:'missing', name:'missing.wav', usages:['Prepared audio', 'Backing track', 'Track 1', 'Track 4'], trackRequirements:[{track:0, seconds:24, format:'WAV'}, {track:3, seconds:24, format:'WAV'}], reason:'missing'},
    {id:'broken', name:'Missing backing audio', usages:['Prepared audio'], trackRequirements:[], reason:'unreadable'}
  ]);
  assert.equal(recovery.inspect(snapshot, [file('missing', 25), file('second'), file('broken')])[0].reason, 'changed');
  assert.equal(recovery.inspect(snapshot, [file('missing', 24, 'MP3'), file('second'), file('broken')])[0].reason, 'changed');
  assert.deepEqual(recovery.inspect(snapshot, [file('missing'), file('second'), file('broken')]), []);
});

test('equal filenames never resolve a missing identity or select a replacement', () => {
  const snapshot = fixture(), sameName = {...file('different-id'), name:'missing.wav'}, before = copy(snapshot);
  const problem = recovery.inspect(snapshot, [sameName, file('second')])[0];
  assert.equal(problem.id, 'missing');
  assert.equal(problem.reason, 'missing');
  assert.equal(recovery.candidates(problem, [sameName])[0].id, 'different-id');
  assert.deepEqual(snapshot, before);
});

test('candidate browsing requires readable supported audio and exact imported length and format', () => {
  const problem = recovery.inspect(fixture(), [file('second')])[0];
  const files = [file('wav'), file('lowercase', 24, 'wav'), file('mp3', 24, 'MP3'), file('short', 23.999), file('long', 25), file('empty', 0), file('negative', -1), file('infinite', Infinity), file('other', 24, 'FLAC'), {...file('broken'), unreadable:true}, {...file('text'), seconds:'24'}];
  assert.deepEqual(recovery.candidates(problem, files).map(row => row.id), ['wav', 'lowercase']);
  const preparedOnly = {audioLibrary:{prepared:['missing'], trackImports:{}}};
  assert.deepEqual(recovery.candidates(recovery.inspect(preparedOnly, [])[0], files).map(row => row.id), ['wav', 'lowercase', 'mp3', 'short', 'long']);
});

test('one repair updates every dependency while preserving timing, source, levels and unrelated session state', () => {
  const snapshot = fixture(), files = [file('replacement'), file('second')], before = copy(snapshot), filesBefore = copy(files);
  freeze(snapshot); freeze(files);
  const problem = recovery.inspect(snapshot, files)[0], selected = recovery.candidates(problem, files)[0];
  const pending = recovery.repair(snapshot, problem.id, selected, files);
  const expected = copy(before);
  expected.audioLibrary.prepared[0] = 'replacement';
  expected.audioLibrary.backing = copy(files[0]);
  expected.audioLibrary.trackImports[0].file = copy(files[0]);
  expected.audioLibrary.trackImports[3].file = copy(files[0]);
  assert.deepEqual(pending, expected);
  assert.deepEqual(recovery.inspect(pending, files), []);
  assert.deepEqual(snapshot, before);
  assert.deepEqual(files, filesBefore);
  pending.audioLibrary.trackImports[0].timing.bars = 99;
  pending.audioLibrary.backing.name = 'Changed draft';
  assert.equal(snapshot.audioLibrary.trackImports[0].timing.bars, 12);
  assert.equal(files[0].name, 'replacement.wav');
  assert.equal(pending.audioLibrary.trackImports[3].file.name, 'replacement.wav');
});

test('canceling a repair draft leaves the source snapshot intact and replacement collisions preserve prepared order', () => {
  const snapshot = fixture(), before = copy(snapshot), files = [file('second')];
  const pending = recovery.repair(snapshot, 'missing', files[0], files);
  assert.deepEqual(pending.audioLibrary.prepared, ['second']);
  assert.deepEqual(snapshot, before);
  assert.deepEqual(recovery.inspect(snapshot, files).map(problem => problem.id), ['missing']);
});

test('candidate and problem outputs are independent copies of session and available media', () => {
  const snapshot = fixture(), files = [file('replacement')];
  const problem = recovery.inspect(snapshot, files)[0];
  problem.trackRequirements[0].seconds = 999;
  assert.equal(snapshot.audioLibrary.trackImports[0].file.seconds, 24);
  const selected = recovery.candidates(recovery.inspect(snapshot, files)[0], files)[0];
  selected.name = 'Edited choice';
  assert.equal(files[0].name, 'replacement.wav');
});

test('every apply rejects missing, unreadable, changed and incompatible candidates without mutating the source', () => {
  const snapshot = freeze(fixture()), before = copy(snapshot), selected = file('replacement');
  assert.throws(() => recovery.repair(snapshot, 'missing', selected, []), /no longer available/);
  assert.throws(() => recovery.repair(snapshot, 'missing', selected, [{...selected, unreadable:true}]), /no longer available/);
  assert.throws(() => recovery.repair(snapshot, 'missing', selected, [{...selected, name:'Renamed.wav'}]), /changed/);
  assert.throws(() => recovery.repair(snapshot, 'missing', selected, [{...selected, seconds:25}]), /changed/);
  const incompatible = file('incompatible', 25);
  assert.throws(() => recovery.repair(snapshot, 'missing', incompatible, [incompatible]), /original duration and format/);
  const wrongFormat = file('wrong-format', 24, 'MP3');
  assert.throws(() => recovery.repair(snapshot, 'missing', wrongFormat, [wrongFormat]), /original duration and format/);
  assert.deepEqual(snapshot, before);
});

test('apply recomputes current requirements and refuses a problem that has already resolved', () => {
  const snapshot = fixture(), selected = file('replacement');
  const problem = recovery.inspect(snapshot, [selected])[0];
  assert.equal(recovery.candidates(problem, [selected]).length, 1);
  snapshot.audioLibrary.trackImports[3].file.seconds = 48;
  assert.throws(() => recovery.repair(snapshot, 'missing', selected, [selected]), /original duration and format/);
  assert.deepEqual(recovery.candidates(recovery.inspect(snapshot, [selected])[0], [selected, file('other', 48)]), []);
  const resolved = fixture();
  assert.throws(() => recovery.repair(resolved, 'missing', selected, [file('missing'), selected]), /no longer needs repair/);
});

test('final inspection catches a repaired import changing later while prepared-only edits can remain valid', () => {
  const snapshot = fixture(), files = [file('replacement'), file('second')];
  const pending = recovery.repair(snapshot, 'missing', files[0], files);
  const later = [file('replacement', 30), file('second', 40, 'MP3')];
  assert.deepEqual(recovery.inspect(pending, later).map(problem => [problem.id, problem.reason]), [['replacement', 'changed']]);
  assert.equal(pending.audioLibrary.trackImports[0].file.seconds, 24);
  assert.equal(pending.audioLibrary.trackImports[0].timing.seconds, 24);
  later[0] = file('replacement', 24, 'MP3');
  assert.equal(recovery.inspect(pending, later)[0].reason, 'changed');
});
