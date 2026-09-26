// Behavioral acceptance for symbolic capture recovery; no audio buffers or DSP.
// Run with Node. Uses the same public transport/edit harness as other studies.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {createRig, clone} = require('./audio-state-test-harness.cjs');
const layers = (rig, track) => rig.state[track].layers.layers;
const length = (rig, track) => rig.state[track].length.durationBeats;
const command = (rig, action, track = 0) => rig.transport.command(action, track);
function idle(rig) {
  assert.deepEqual(rig.capture, rig.capture.map(() => 'idle'));
  assert.equal(rig.transport.snapshot().pending.length, 0);
  assert(rig.transport.snapshot().tracks.every(track => track.capturing === null));
}
function empty(rig) {
  assert(rig.state.every(track => !track.parts.length && !track.layers.layers.length && !track.playing));
}
function live(rig) {
  const transport = rig.transport.snapshot();
  return clone({state:rig.state, capture:rig.capture, history:rig.history(), pending:transport.pending, tracks:transport.tracks});
}
function arm(rig, track) {
  rig.overrides[track] = {waitingClock:true};
  command(rig, 'Record / Play', track);
  assert.equal(rig.capture[track], 'armed');
}

for (const offset of [6, 14]) {
  test('established Multi recovers four captured beats at cycle offset ' + offset + ' inside the original 16-beat loop', () => {
    const rig = createRig('multi');
    rig.record(0, 16);
    rig.advance(offset * 500);
    command(rig, 'Record / Play', 1);
    rig.advance(2000);
    assert.equal(rig.capture[1], 'recording');
    const other = clone(rig.state[0]), phase = rig.transport.info(0).position;
    command(rig, 'Undo', 1);
    assert.equal(layers(rig, 1).length, 0);
    assert.equal(rig.capture[1], 'idle');
    assert(rig.transport.canRecover([1], 'redo'));
    command(rig, 'Redo', 1);
    assert.equal(rig.config.mode, 'multi');
    assert.equal(length(rig, 1), 16);
    assert.equal(layers(rig, 1).length, 1);
    assert.equal(layers(rig, 1)[0].beats, 4);
    assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:offset, beats:4}]);
    assert.deepEqual(rig.state[1].length.audio, [], 'silent remainder is not represented as invented audio samples');
    assert.equal(rig.state[1].playing, true);
    assert.equal(rig.capture[1], 'idle');
    assert.equal(rig.transport.info(1).position, phase);
    assert.equal(rig.transport.info(0).position, phase);
    assert.deepEqual(rig.state[0], other, 'the established loop keeps playing without replacement');
    const recovered = clone(layers(rig, 1));
    rig.advance(8000);
    assert.deepEqual(layers(rig, 1), recovered, 'playback does not synthesize another captured layer');
    assert.equal(rig.state[0].playing, true);
    assert.equal(rig.capture[1], 'idle');
  });
}

test('the first Multi take recovers its exact captured duration without an established cycle', () => {
  const rig = createRig('multi');
  command(rig, 'Record / Play');
  rig.advance(1750);
  command(rig, 'Undo');
  assert.equal(layers(rig, 0).length, 0);
  command(rig, 'Redo');
  assert.equal(length(rig, 0), 3.5);
  assert.equal(layers(rig, 0)[0].beats, 3.5);
  assert.equal(rig.state[0].playing, true);
  assert.equal(rig.capture[0], 'idle');
  assert.deepEqual(rig.state[0].length.audio, []);
});

test('Clear All freezes an established Multi partial take and restores it stopped without changing the shared loop', () => {
  const rig = createRig('multi');
  rig.record(0, 16);
  rig.advance(3000);
  command(rig, 'Record / Play', 1);
  rig.advance(2000);
  const phase = rig.transport.info(0).position, established = clone(rig.state[0]);
  arm(rig, 2);
  command(rig, 'Clear all');
  empty(rig); idle(rig);
  assert.equal(rig.transport.events('Clear all').undo.length, 1);
  command(rig, 'Undo', 2);
  assert.deepEqual(rig.state[0], established);
  assert.equal(rig.transport.info(0).position, phase);
  assert.equal(length(rig, 1), 16);
  assert.equal(layers(rig, 1)[0].beats, 4);
  assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:6, beats:4}]);
  assert.equal(rig.state[1].playing, false, 'partial capture restores as stopped playable content');
  assert.equal(rig.state[0].playing, true);
  idle(rig);
  command(rig, 'Undo', 1);
  assert.equal(layers(rig, 1).length, 0, 'the frozen Recording remains the next chronological edit');
  command(rig, 'Redo', 1);
  assert.equal(length(rig, 1), 16);
  assert.equal(rig.capture[1], 'idle');
});

test('Clear All groups a partial overdub, preserves completed playback states, decay, earlier history and later mix changes', () => {
  const rig = createRig('free', 5);
  for (const track of [0, 1, 2]) rig.record(track, 8);
  command(rig, 'Stop');
  command(rig, 'Record / Play', 0);
  command(rig, 'Record / Play', 2);
  rig.config.decay = 25;
  command(rig, 'Record / Play', 2);
  rig.advance(2000);
  arm(rig, 3);
  const original = clone(layers(rig, 2)), priorHistory = rig.history().tracks[2].undo.length;
  command(rig, 'Clear all', 4);
  empty(rig); idle(rig);
  const groups = rig.transport.events('Clear all').undo;
  assert.equal(groups.length, 1);
  assert.deepEqual(clone(groups[0].group), [0, 1, 2, 3, 4]);
  rig.state[2].mix.level = .37;
  command(rig, 'Undo', 3);
  assert.deepEqual(rig.state.map(track => track.playing), [true, false, false, false, false]);
  assert.equal(length(rig, 2), 8);
  assert.equal(layers(rig, 2).length, 2);
  assert.equal(layers(rig, 2)[0].gain, .75);
  assert.equal(layers(rig, 2)[1].beats, 4);
  assert.equal(rig.state[2].mix.level, .37);
  assert.equal(rig.history().tracks[2].undo.length, priorHistory + 1, 'the frozen pass has its own chronological history');
  idle(rig);
  command(rig, 'Undo', 2);
  assert.deepEqual(layers(rig, 2), original, 'Undo of the frozen pass restores the prior decay state');
  assert.equal(rig.state[2].mix.level, .37);
  assert.equal(rig.state[2].playing, false);
  command(rig, 'Redo', 2);
  assert.equal(layers(rig, 2).length, 2);
  assert.equal(layers(rig, 2)[0].gain, .75);
  assert.equal(rig.state[2].playing, false);
  idle(rig);
  command(rig, 'Redo', 0);
  empty(rig);
  command(rig, 'Undo', 1);
  assert.equal(layers(rig, 2).length, 2);
  assert.equal(rig.state[2].mix.level, .37);
  command(rig, 'Undo', 1);
  assert.equal(layers(rig, 1).length, 0, 'the earlier completed take remains recoverable');
});

test('Clear All freezes a defining partial take at its real length and Undo never restarts capture', () => {
  const rig = createRig('multi');
  command(rig, 'Record / Play');
  rig.advance(1750);
  command(rig, 'Clear all');
  empty(rig); idle(rig);
  command(rig, 'Undo', 3);
  assert.equal(length(rig, 0), 3.5);
  assert.equal(layers(rig, 0)[0].beats, 3.5);
  assert.equal(rig.state[0].playing, false);
  idle(rig);
  const restored = clone(rig.state);
  rig.advance(4000);
  assert.deepEqual(rig.state, restored, 'a restored stopped take cannot silently keep recording');
});

test('a wrapped partial overdub restores only its captured region and applies decay once', () => {
  const rig = createRig();
  rig.record(0, 16);
  rig.advance(7000);
  rig.config.decay = 50;
  command(rig, 'Record / Play');
  rig.advance(2000);
  command(rig, 'Clear all');
  command(rig, 'Undo');
  assert.equal(length(rig, 0), 16);
  assert.equal(layers(rig, 0).length, 2);
  assert.equal(layers(rig, 0)[0].gain, .5);
  assert.equal(layers(rig, 0)[1].beats, 4);
  assert.deepEqual(layers(rig, 0)[1].regions, [{offsetBeats:14, beats:4}]);
  assert.equal(rig.state[0].playing, false);
  idle(rig);
});

test('Clear All at an overdub pass boundary adds no duplicate pass or second decay', () => {
  const rig = createRig();
  rig.record(0, 8);
  rig.config.decay = 25;
  command(rig, 'Record / Play');
  rig.advance(4000);
  assert.equal(layers(rig, 0).length, 2);
  const completed = clone(layers(rig, 0));
  command(rig, 'Clear all');
  command(rig, 'Undo');
  assert.deepEqual(layers(rig, 0), completed);
  assert.equal(layers(rig, 0)[0].gain, .75);
  assert.equal(rig.transport.events('Overdub').undo.length, 1);
  idle(rig);
});

test('zero-length capture and queued arms cancel without invented audio or history', () => {
  for (const queued of [false, true]) {
    const rig = createRig();
    if (queued) arm(rig, 0); else command(rig, 'Record / Play');
    command(rig, 'Clear all');
    empty(rig); idle(rig);
    assert(rig.transport.snapshot().tracks.every(track => track.undo === 0 && track.redo === 0));
    assert.equal(rig.transport.events('Clear all').undo.length, 0);
    rig.advance(8000);
    command(rig, 'Undo');
    command(rig, 'Redo');
    empty(rig); idle(rig);
  }
});

test('zero-length overdub adds no layer or decay before grouped Clear All recovery', () => {
  const rig = createRig();
  rig.record(0, 8);
  const original = clone(layers(rig, 0));
  rig.config.decay = 80;
  command(rig, 'Record / Play');
  command(rig, 'Clear all');
  empty(rig); idle(rig);
  command(rig, 'Undo');
  assert.deepEqual(layers(rig, 0), original);
  assert.equal(rig.transport.events('Overdub').undo.length, 0);
  assert.equal(rig.state[0].playing, false);
  idle(rig);
});

test('failed Clear All publication leaves live content, capture, pending arms and history intact, then retries once', () => {
  const rig = createRig();
  rig.record(0, 8);
  command(rig, 'Record / Play', 1);
  rig.advance(1750);
  arm(rig, 2);
  const before = live(rig);
  rig.failPublish(true);
  command(rig, 'Clear all');
  assert.deepEqual(live(rig), before);
  rig.advance(250);
  assert.equal(rig.capture[1], 'recording');
  assert.equal(rig.capture[2], 'armed');
  assert.equal(rig.transport.info(1).beats, 4, 'a failed Clear All does not lose capture time');
  rig.failPublish(false);
  command(rig, 'Clear all');
  empty(rig); idle(rig);
  assert.equal(rig.transport.events('Clear all').undo.length, 1);
  command(rig, 'Undo');
  assert.equal(length(rig, 1), 4);
  assert.equal(layers(rig, 1).length, 1);
  assert.equal(rig.state[1].playing, false);
});

test('failed partial Undo is atomic across captured audio and history and retains another queued arm', () => {
  const rig = createRig('multi');
  rig.record(0, 16);
  rig.advance(3000);
  command(rig, 'Record / Play', 1);
  rig.advance(2000);
  arm(rig, 2);
  const before = live(rig);
  rig.failPublish(true);
  command(rig, 'Undo', 1);
  assert.deepEqual(live(rig), before);
  rig.advance(500);
  assert.equal(rig.capture[1], 'recording');
  assert.equal(rig.transport.info(1).beats, 5, 'a failed Undo retains the original capture start');
  rig.failPublish(false);
  command(rig, 'Undo', 1);
  assert.equal(layers(rig, 1).length, 0);
  assert.equal(rig.capture[1], 'idle');
  assert.equal(rig.capture[2], 'armed');
  command(rig, 'Redo', 1);
  assert.equal(length(rig, 1), 16);
  assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:6, beats:5}]);
});

test('failed grouped Undo preserves cleared content and its entire journal until a successful retry', () => {
  const rig = createRig();
  rig.record(0, 8);
  command(rig, 'Record / Play', 1);
  rig.advance(1500);
  command(rig, 'Clear all');
  empty(rig); idle(rig);
  const before = live(rig);
  rig.failPublish(true);
  command(rig, 'Undo', 2);
  assert.deepEqual(live(rig), before);
  rig.failPublish(false);
  command(rig, 'Undo', 2);
  assert.equal(length(rig, 0), 8);
  assert.equal(length(rig, 1), 3);
  assert.equal(rig.state[0].playing, true);
  assert.equal(rig.state[1].playing, false);
  idle(rig);
});

for (const mode of ['sync', 'band']) {
  test('proposed ' + mode + ' Clear All retains a partial fixed recording in its chosen compatible window', () => {
    const rig = createRig(mode);
    rig.config.primaryTrack = 'Track 1';
    rig.record(0, 8);
    rig.overrides[1] = {bars:2};
    command(rig, 'Record / Play', 1);
    rig.advance(1500);
    assert.equal(rig.capture[1], 'recording');
    command(rig, 'Clear all');
    empty(rig); idle(rig);
    command(rig, 'Undo');
    assert.equal(length(rig, 0), 8);
    assert.equal(length(rig, 1), 8);
    assert.equal(layers(rig, 1)[0].beats, 3);
    assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:0, beats:3}]);
    assert.equal(rig.state[1].playing, false);
    assert.equal(rig.transport.compatibility({}), '');
    idle(rig);
    command(rig, 'Undo', 1);
    assert.equal(layers(rig, 1).length, 0);
    command(rig, 'Redo', 1);
    assert.equal(length(rig, 1), 8);
    assert.equal(layers(rig, 1)[0].beats, 3);
    assert.equal(rig.capture[1], 'idle');
  });
}

test('offline Redo preserves its history and empty destination until playback can reconnect', () => {
  const rig = createRig('multi');
  command(rig, 'Record / Play');
  rig.advance(1750);
  command(rig, 'Undo');
  const before = live(rig);
  rig.setAudioReady(false);
  command(rig, 'Redo');
  assert.deepEqual(live(rig), before);
  assert.match(rig.transport.snapshot().notice.action, /Reconnect audio/);
  rig.setAudioReady(true);
  command(rig, 'Redo');
  assert.equal(length(rig, 0), 3.5);
  assert.equal(rig.state[0].playing, true);
  assert.equal(rig.capture[0], 'idle');
});

function sparseRig(offset) {
  const rig = createRig('multi');
  rig.record(0, 16);
  rig.advance(offset * 500);
  command(rig, 'Record / Play', 1);
  rig.advance(2000);
  command(rig, 'Undo', 1);
  command(rig, 'Redo', 1);
  return rig;
}
function waveformBins(rig) {
  // Equal nonzero peaks make each of the 32 visible time bins unambiguous.
  const world = {window:{segnoWaveformReferences:[{id:'equal-peaks', peaks:Array.from({length:32}, () => [-100, 100])}]}};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'stage-display-study.js'), 'utf8'), world);
  const display = world.window.createStageDisplayStudy({}), info = rig.transport.info(1);
  const wave = display.waveState(0, {tracks:[{...info, state:'Stopped', bars:info.loopBeats / 4}]});
  const upper = wave.path.slice(1, -1).split('L').slice(0, 32);
  assert.equal(upper.length, 32);
  return upper.flatMap((point, index) => Number(point.split(',')[1]) === 50 ? [] : [index]);
}

test('Multiply repeats sparse recorded regions in Wave and Undo restores their exact placement', () => {
  const rig = sparseRig(6), original = clone(layers(rig, 1));
  assert.equal(rig.length.direct([0, 1], 'double'), true);
  assert.equal(length(rig, 1), 32);
  assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:6, beats:4}, {offsetBeats:22, beats:4}]);
  assert.deepEqual(waveformBins(rig), [6, 7, 8, 9, 22, 23, 24, 25]);
  command(rig, 'Undo', 1);
  assert.equal(length(rig, 1), 16);
  assert.deepEqual(layers(rig, 1), original);
  command(rig, 'Redo', 1);
  assert.deepEqual(waveformBins(rig), [6, 7, 8, 9, 22, 23, 24, 25]);
});

test('Divide clips wrapped captured regions to the selected half without drawing silence as audio', () => {
  for (const part of ['first', 'last']) {
    const rig = sparseRig(14);
    assert.equal(rig.length.direct([0, 1], 'half', part), true);
    assert.equal(length(rig, 1), 8);
    assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:part === 'first' ? 0 : 6, beats:2}]);
    assert.deepEqual(waveformBins(rig), part === 'first' ? [0, 1, 2, 3, 4, 5, 6, 7] : [24, 25, 26, 27, 28, 29, 30, 31]);
  }
  const silent = sparseRig(10);
  assert.equal(silent.length.direct([0, 1], 'half', 'first'), true);
  assert.deepEqual(layers(silent, 1)[0].regions, []);
  assert.deepEqual(waveformBins(silent), [], 'a retained half with no recorded region has a flat contour');
});

test('saved Undo eligibility loads immediately after reset without requiring a display snapshot first', () => {
  const rig = createRig();
  rig.record(0, 8);
  rig.length.direct([0], 'double');
  const history = rig.history();
  rig.transport.reset();
  rig.setHistory(history);
  assert.equal(rig.transport.canRecover([0], 'undo', ['Multiply']), true);
  command(rig, 'Undo');
  assert.equal(length(rig, 0), 8);
});

for (const mode of ['song', 'band']) {
  test(mode + ' Redo publishes an exclusive section candidate and a failed save preserves live state and history', () => {
    const rig = createRig(mode), target = mode === 'band' ? 1 : 0, other = target + 1;
    rig.config.primaryTrack = 'Track 1';
    if (mode === 'band') rig.record(0, 8);
    rig.overrides[target] = {bars:2};
    rig.record(target, 8);
    const restored = clone(rig.state[target]);
    command(rig, 'Undo', target);
    rig.overrides[other] = {bars:2};
    rig.record(other, 8);
    idle(rig);
    assert.equal(layers(rig, target).length, 0);
    assert.equal(rig.state[other].playing, true);
    assert.equal(rig.transport.canRecover([target], 'redo'), true);
    const before = live(rig), expected = clone(rig.state), attemptCount = rig.publishedAttempts().length;
    expected[target] = restored;
    expected[other].playing = false;

    rig.failPublish(true);
    command(rig, 'Redo', target);
    assert.deepEqual(live(rig), before, 'a rejected publication cannot stop the current section or consume Redo');
    assert.equal(rig.publishedAttempts().length, attemptCount + 1);
    const failed = rig.publishedAttempts().at(-1);
    assert.deepEqual(failed.state, expected, 'section exclusivity must already hold in the candidate sent for publication');
    assert.equal(failed.journal.tracks[target].redo.length, 0);
    assert.equal(failed.journal.tracks[target].undo.length, 1);
    for (let i = 0; i < rig.state.length; i++) {
      if (i !== target) assert.deepEqual(failed.journal.tracks[i], before.history.tracks[i]);
    }

    rig.failPublish(false);
    command(rig, 'Redo', target);
    assert.equal(rig.publishedAttempts().length, attemptCount + 2);
    assert.deepEqual(rig.publishedAttempts().at(-1), failed, 'retry publishes the same complete candidate and journal');
    assert.deepEqual(rig.state, expected, 'published and live playback agree without a later exclusivity correction');
    assert.deepEqual(rig.history(), failed.journal);
    assert.deepEqual(rig.state.map(track => track.playing), mode === 'band' ? [true, true, false, false] : [true, false, false, false]);
    if (mode === 'band') {
      assert.deepEqual(rig.state[0], before.state[0], 'the primary bed continues unchanged while the secondary section switches');
      assert.equal(rig.transport.info(0).position, before.tracks[0].position);
    }
    idle(rig);
  });
}
