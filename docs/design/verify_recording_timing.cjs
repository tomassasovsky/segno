// Draft timing acceptance for the silent prototype; no native audio or DSP.
// Run with node --test docs/design/verify_recording_timing.cjs.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {createRig, clone} = require('./audio-state-test-harness.cjs');

const command = (rig, action, track = 0) => rig.transport.command(action, track);
const pending = rig => clone(rig.transport.snapshot().pending);
const layers = (rig, track = 0) => rig.state[track].layers.layers;
const duration = (rig, track = 0) => rig.state[track].length.durationBeats;
const near = (actual, expected, message) => assert(Math.abs(actual - expected) < 1e-7, message || `${actual} should equal ${expected}`);
function rigFor(mode = 'free') {
  const rig = createRig(mode);
  rig.config.click = 'always';
  return rig;
}
function noPending(rig) {
  assert.equal(pending(rig).length, 0);
  assert(rig.capture.every(value => value === 'idle'));
}
function countIn(rig, track, action, beats) {
  assert.deepEqual(pending(rig), [{track, action, timing:'Count-in · ' + beats}]);
  assert.equal(rig.capture[track], 'armed');
  assert.equal(rig.state[track].playing, false);
}

for (const bars of [1, 2]) {
  test(bars + '-bar local count-in begins an empty recording only at its final beat', () => {
    const rig = rigFor();
    rig.config.countIn = bars;
    command(rig, 'Record / Play');
    countIn(rig, 0, 'Record', bars * 4);
    rig.advance(bars * 2000 - 1);
    assert.equal(rig.capture[0], 'armed');
    assert.equal(layers(rig).length, 0);
    rig.advance(1);
    assert.equal(rig.capture[0], 'recording');
    assert.equal(pending(rig).length, 0);
    near(rig.transport.info(0).beats, 0);
    near(rig.transport.snapshot().elapsed, 0);
  });
}

for (const entry of [
  {name:'recording on another empty track', action:'Record / Play', track:1, pending:'Record', capture:'recording'},
  {name:'playback of a stopped track', action:'Record / Play', track:0, pending:'Play', capture:'idle'},
  {name:'overdub of a stopped track', action:'Arm overdub', track:0, pending:'Overdub', capture:'overdubbing'},
]) {
  test('local count-in restarts after Stop for ' + entry.name, () => {
    const rig = rigFor();
    rig.record(0, 8);
    command(rig, 'Stop');
    rig.advance(750);
    rig.config.countIn = 1;
    const original = clone(layers(rig));
    command(rig, entry.action, entry.track);
    countIn(rig, entry.track, entry.pending, 4);
    rig.advance(1999);
    assert.equal(rig.capture[entry.track], 'armed');
    assert.deepEqual(layers(rig), original);
    rig.advance(1);
    assert.equal(pending(rig).length, 0);
    assert.equal(rig.capture[entry.track], entry.capture);
    assert.equal(rig.state[entry.track].playing, entry.capture !== 'recording');
    near(rig.transport.info(entry.track).position, 0);
  });
}

test('Stop cancels a local count-in without creating audio or consuming prior history', () => {
  const rig = rigFor();
  rig.record(0, 8);
  command(rig, 'Stop');
  rig.config.countIn = 2;
  const before = clone(rig.state), history = rig.history();
  command(rig, 'Record / Play', 1);
  countIn(rig, 1, 'Record', 8);
  rig.advance(1500);
  command(rig, 'Stop');
  noPending(rig);
  rig.advance(8000);
  noPending(rig);
  assert.deepEqual(rig.state, before);
  assert.deepEqual(rig.history(), history);
});

for (const active of ['playing', 'recording']) {
  test('adding a recording during ' + active + ' music adds no local count-in', () => {
    const rig = rigFor();
    if (active === 'playing') rig.record(0, 8);
    else { command(rig, 'Record / Play'); rig.advance(1000); }
    rig.config.countIn = 2;
    command(rig, 'Record / Play', 1);
    assert.equal(rig.capture[1], 'recording');
    assert.equal(pending(rig).length, 0);
    assert.equal(rig.state[0].playing, true);
    near(rig.transport.info(1).beats, 0);
  });
}

test('receiving external clock suppresses local count-in on an empty first recording', () => {
  const rig = rigFor();
  Object.assign(rig.config, {externalClock:true, countIn:2});
  command(rig, 'Record / Play');
  assert.equal(rig.capture[0], 'recording');
  assert.equal(pending(rig).length, 0);
});

test('an armed external-clock recording starts when clock returns without inserting local count-in', () => {
  const rig = rigFor();
  Object.assign(rig.config, {externalClock:true, waitingClock:true, countIn:2});
  command(rig, 'Record / Play');
  assert.equal(rig.capture[0], 'armed');
  assert.equal(pending(rig)[0].timing, 'Waiting for clock');
  rig.advance(3000);
  assert.equal(rig.capture[0], 'armed');
  rig.config.waitingClock = false;
  rig.transport.clockReady();
  assert.equal(rig.capture[0], 'recording');
  assert.equal(pending(rig).length, 0);
});

for (const cancel of [false, true]) {
  test('Start / Stop all shares one local count-in across populated tracks' + (cancel ? ' and Stop cancels it' : ''), () => {
    const rig = rigFor();
    for (const track of [0, 1, 2]) rig.record(track, 8);
    command(rig, 'Stop');
    rig.config.countIn = 1;
    const before = clone(rig.state), history = rig.history();
    command(rig, 'Start / Stop all');
    const queued = pending(rig);
    assert.equal(queued.length, 3);
    assert.deepEqual(queued.map(item => item.track), [0, 1, 2]);
    assert(queued.every(item => item.action === 'Play' && item.timing === 'Count-in · 4'));
    assert(rig.state.every(track => !track.playing));
    rig.advance(1999);
    assert(rig.state.every(track => !track.playing));
    if (cancel) {
      command(rig, 'Stop');
      rig.advance(8000);
      noPending(rig);
      assert.deepEqual(rig.state, before);
    } else {
      rig.advance(1);
      noPending(rig);
      assert.deepEqual(rig.state.map(track => track.playing), [true, true, true, false]);
      for (const track of [0, 1, 2]) near(rig.transport.info(track).position, 0);
      rig.advance(500);
      for (const track of [0, 1, 2]) near(rig.transport.info(track).position, 1 / 8);
    }
    assert.deepEqual(rig.history(), history);
  });
}

for (const mode of ['sync', 'band']) {
  for (const entry of [
    {offset:0, beforeRequest:1.5, loop:8, captured:8},
    {offset:2, beforeRequest:1.5, loop:8, captured:6},
    {offset:6, beforeRequest:4, loop:16, captured:10},
  ]) {
    test(mode + ' Auto captures from primary offset ' + entry.offset + ' and completes at the next primary cycle end', () => {
      const rig = rigFor(mode);
      rig.config.primaryTrack = 'Track 1';
      rig.record(0, 8);
      const primary = clone(rig.state[0]);
      rig.advance(entry.offset * 500);
      command(rig, 'Record / Play', 1);
      assert.equal(rig.capture[1], 'recording');
      assert.equal(pending(rig).length, 0);
      near(rig.transport.info(0).position, entry.offset / 8);
      rig.advance(entry.beforeRequest * 500);
      command(rig, 'Record / Play', 1);
      assert.equal(rig.capture[1], 'recording');
      assert.equal(pending(rig)[0].track, 1);
      assert.equal(pending(rig)[0].action, 'Play');
      const remaining = (entry.captured - entry.beforeRequest) * 500;
      rig.advance(remaining - 1);
      assert.equal(rig.capture[1], 'recording');
      assert.equal(layers(rig, 1).length, 0);
      assert.equal(rig.state[0].playing, true);
      rig.advance(1);
      noPending(rig);
      assert.equal(duration(rig, 1), entry.loop);
      near(layers(rig, 1)[0].beats, entry.captured);
      assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:entry.offset, beats:entry.captured}]);
      assert.equal(rig.state[1].playing, true);
      assert.deepEqual(rig.state[0], primary, 'primary content and playing state remain unchanged');
      near(rig.transport.info(0).position, 0);
      near(rig.transport.info(1).position, 0);
      assert.equal(rig.transport.compatibility({}), '');
    });
  }

  test(mode + ' compatible fixed length can remain shorter than its primary loop', () => {
    const rig = rigFor(mode);
    rig.config.primaryTrack = 'Track 1';
    rig.record(0, 8);
    const primary = clone(rig.state[0]);
    rig.advance(1000);
    rig.overrides[1] = {bars:1};
    command(rig, 'Record / Play', 1);
    assert.equal(rig.capture[1], 'recording');
    rig.advance(1999);
    assert.equal(rig.capture[1], 'recording');
    rig.advance(1);
    noPending(rig);
    assert.equal(duration(rig, 1), 4);
    assert.equal(layers(rig, 1)[0].beats, 4);
    assert.deepEqual(rig.state[0], primary);
    near(rig.transport.info(0).position, .75);
    assert.equal(rig.transport.compatibility({}), '');
  });
}

for (const example of [
  {seconds:1.75, initial:120, beats:4, tempo:240 / 1.75},
  {seconds:3.5, initial:120, beats:8, tempo:480 / 3.5},
  {seconds:3, initial:100, beats:4, tempo:80},
  {seconds:.8, initial:300, beats:4, tempo:300},
  {seconds:8, initial:30, beats:4, tempo:30},
  {seconds:512, initial:30, beats:256, tempo:30},
  {seconds:60, initial:300, beats:256, tempo:256},
]) {
  test('first Auto take of ' + example.seconds + ' seconds infers whole bars nearest ' + example.initial + ' BPM without changing audio time', () => {
    const rig = rigFor();
    Object.assign(rig.config, {click:'off', tempo:example.initial});
    command(rig, 'Record / Play');
    rig.advance(example.seconds * 1000);
    command(rig, 'Record / Play');
    noPending(rig);
    assert.equal(rig.state[0].playing, true);
    assert.equal(duration(rig), example.beats);
    near(rig.config.tempo, example.tempo);
    near(duration(rig) * 60 / rig.config.tempo, example.seconds, 'inferred musical length preserves elapsed audio seconds');
    assert.equal(layers(rig).length, 1);
    near(layers(rig)[0].beats, example.beats);
    assert.deepEqual(layers(rig)[0].regions, [{offsetBeats:0, beats:example.beats}]);
  });
}

for (const seconds of [.5, 513]) {
  test('first Auto take retains measured duration when ' + seconds + ' seconds has no valid bar and tempo candidate', () => {
    const rig = rigFor();
    rig.config.click = 'off';
    command(rig, 'Record / Play');
    rig.advance(seconds * 1000);
    command(rig, 'Record / Play');
    noPending(rig);
    assert.equal(rig.config.tempo, 120);
    near(duration(rig), seconds * 2);
    near(layers(rig)[0].beats, seconds * 2);
    near(duration(rig) * 60 / rig.config.tempo, seconds);
  });
}

for (const click of ['first', 'rec', 'always']) {
  test('first Auto take with click ' + click + ' retains the selected tempo and measured duration', () => {
    const rig = rigFor();
    rig.config.click = click;
    command(rig, 'Record / Play');
    rig.advance(1750);
    command(rig, 'Record / Play');
    noPending(rig);
    assert.equal(rig.config.tempo, 120);
    near(duration(rig), 3.5);
  });
}

test('external clock prevents first-take tempo inference even with click off', () => {
  const rig = rigFor();
  Object.assign(rig.config, {click:'off', externalClock:true});
  command(rig, 'Record / Play');
  rig.advance(1750);
  command(rig, 'Record / Play');
  noPending(rig);
  assert.equal(rig.config.tempo, 120);
  near(duration(rig), 3.5);
});

test('a stopped existing track prevents another Auto take from retuning the session', () => {
  const rig = rigFor();
  rig.record(0, 8);
  command(rig, 'Stop');
  rig.config.click = 'off';
  const original = clone(rig.state[0]);
  command(rig, 'Record / Play', 1);
  rig.advance(1750);
  command(rig, 'Record / Play', 1);
  noPending(rig);
  assert.equal(rig.config.tempo, 120);
  near(duration(rig, 1), 3.5);
  assert.deepEqual(rig.state[0], original);
});

test('stopping a fixed-length first take early preserves its measured duration without tempo inference', () => {
  const rig = rigFor();
  Object.assign(rig.config, {click:'off', bars:1});
  command(rig, 'Record / Play');
  rig.advance(1750);
  command(rig, 'Stop');
  noPending(rig);
  assert.equal(rig.config.tempo, 120);
  near(duration(rig), 3.5);
  assert.equal(rig.state[0].playing, false);
});

test('first-take inference excludes local count-in time from the captured audio duration', () => {
  const rig = rigFor();
  Object.assign(rig.config, {click:'off', countIn:1});
  command(rig, 'Record / Play');
  rig.advance(2000);
  assert.equal(rig.capture[0], 'recording');
  rig.advance(1750);
  command(rig, 'Record / Play');
  noPending(rig);
  assert.equal(duration(rig), 4);
  near(rig.config.tempo, 240 / 1.75);
  near(duration(rig) * 60 / rig.config.tempo, 1.75);
});

function live(rig) {
  const state = rig.transport.snapshot();
  return clone({tracks:rig.state, capture:rig.capture, history:rig.history(), tempo:rig.config.tempo,
    pending:state.pending, transportTracks:state.tracks});
}

for (const elapsedAfterFailure of [0, 250]) {
  test('rejected inferred-tempo publication preserves capture, audio, clock and journal before retry' + (elapsedAfterFailure ? ' after more audio arrives' : ''), () => {
    const rig = rigFor();
    rig.config.click = 'off';
    command(rig, 'Record / Play');
    rig.advance(1750);
    const before = live(rig);
    rig.failPublish(true);
    command(rig, 'Record / Play');
    assert.deepEqual(live(rig), before);
    assert.match(rig.transport.snapshot().notice.action, /Could not save/);
    const attempted = rig.publishedAttempts().at(-1);
    near(attempted.clock.tempo, 240 / 1.75);
    assert.equal(attempted.state[0].length.durationBeats, 4);
    assert.equal(attempted.journal.tracks[0].undo.length, 1);
    if (elapsedAfterFailure) {
      rig.advance(elapsedAfterFailure);
      assert.equal(rig.capture[0], 'recording');
      assert.equal(rig.config.tempo, 120);
      near(rig.transport.info(0).beats, 4);
    }
    rig.failPublish(false);
    command(rig, 'Record / Play');
    noPending(rig);
    assert.equal(rig.state[0].playing, true);
    assert.equal(duration(rig), 4);
    assert.equal(layers(rig).length, 1);
    const seconds = (1750 + elapsedAfterFailure) / 1000;
    near(rig.config.tempo, 240 / seconds);
    near(duration(rig) * 60 / rig.config.tempo, seconds);
    assert.equal(rig.history().tracks[0].undo.length, 1, 'retry records one complete take rather than a failed phantom edit');
    if (!elapsedAfterFailure) assert.deepEqual(rig.publishedAttempts().at(-1), attempted);
  });
}

for (const mode of ['sync', 'band']) {
  test(mode + ' Auto finish requested exactly at the primary boundary completes without another silent cycle', () => {
    const rig = rigFor(mode);
    rig.config.primaryTrack = 'Track 1';
    rig.record(0, 8);
    rig.advance(1000);
    command(rig, 'Record / Play', 1);
    rig.advance(3000);
    assert.equal(rig.capture[1], 'recording');
    near(rig.transport.info(0).position, 0);
    command(rig, 'Record / Play', 1);
    noPending(rig);
    assert.equal(duration(rig, 1), 8);
    assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:2, beats:6}]);
    assert.equal(rig.state[0].playing, true);
    assert.equal(rig.state[1].playing, true);
    near(rig.transport.info(1).position, 0);
  });

  test(mode + ' Auto honors quantized start before measuring the leading silent region', () => {
    const rig = rigFor(mode);
    rig.config.primaryTrack = 'Track 1';
    rig.record(0, 8);
    rig.advance(500);
    rig.overrides[1] = {quantize:'bar'};
    command(rig, 'Record / Play', 1);
    assert.equal(pending(rig)[0].timing, 'Next bar');
    rig.advance(1499);
    assert.equal(layers(rig, 1).length, 0);
    assert.notEqual(rig.capture[1], 'recording');
    rig.advance(1);
    assert.equal(rig.capture[1], 'recording');
    near(rig.transport.info(0).position, .5);
    rig.advance(500);
    command(rig, 'Record / Play', 1);
    rig.advance(1500);
    noPending(rig);
    assert.equal(duration(rig, 1), 8);
    assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:4, beats:4}]);
    assert.equal(rig.state[0].playing, true);
    near(rig.transport.info(0).position, 0);
  });
}

test('first-take inference uses proportional tempo distance rather than absolute BPM difference', () => {
  const rig = rigFor();
  Object.assign(rig.config, {click:'off', tempo:116});
  command(rig, 'Record / Play');
  rig.advance(3000);
  command(rig, 'Record / Play');
  assert.equal(duration(rig), 8);
  near(rig.config.tempo, 160);
  near(duration(rig) * 60 / rig.config.tempo, 3);
});

test('an exact proportional-distance tie favors the smaller whole-bar candidate', () => {
  const rig = rigFor();
  // This selected tempo is halfway between 80 and 160 on a ratio scale.
  Object.assign(rig.config, {click:'off', tempo:Math.sqrt(80 * 160)});
  command(rig, 'Record / Play');
  rig.advance(3000);
  command(rig, 'Record / Play');
  assert.equal(duration(rig), 4);
  near(rig.config.tempo, 80);
  near(duration(rig) * 60 / rig.config.tempo, 3);
});

test('a queued finish that infers tempo consumes the remaining tick as real elapsed time', () => {
  const rig = rigFor();
  Object.assign(rig.config, {click:'off', quantize:'quarter'});
  command(rig, 'Record / Play');
  rig.advance(1100);
  command(rig, 'Record / Play');
  assert.equal(pending(rig)[0].timing, 'Next beat');
  rig.advance(1400); // Finish at 1.5 s; then exactly 1 s of the inferred loop plays.
  noPending(rig);
  assert.equal(duration(rig), 4);
  near(rig.config.tempo, 160);
  near(duration(rig) * 60 / rig.config.tempo, 1.5);
  near(rig.transport.snapshot().elapsed, 2.5);
  near(rig.transport.info(0).position, 2 / 3);
  rig.advance(250);
  near(rig.transport.snapshot().elapsed, 2.75);
  near(rig.transport.info(0).position, 5 / 6);
});

for (const signature of ['3/4', '6/8']) {
  test(signature + ' local count-in uses signature pulses and the correct wall-clock duration', () => {
    const rig = rigFor();
    Object.assign(rig.config, {signature, beatsPerBar:3, countIn:1});
    command(rig, 'Record / Play');
    countIn(rig, 0, 'Record', signature === '3/4' ? 3 : 6);
    rig.advance(1499);
    assert.equal(rig.capture[0], 'armed');
    rig.advance(1);
    assert.equal(rig.capture[0], 'recording');
    assert.equal(pending(rig).length, 0);
    near(rig.transport.info(0).beats, 0);
  });
}

test('a rejected first-take Stop preserves capture and reports the save failure until a stopped retry succeeds', () => {
  const rig = rigFor();
  rig.config.click = 'off';
  command(rig, 'Record / Play');
  rig.advance(1750);
  const before = live(rig);
  rig.failPublish(true);
  command(rig, 'Stop');
  assert.deepEqual(live(rig), before);
  assert.match(rig.transport.snapshot().notice.action, /Could not save/);
  rig.failPublish(false);
  command(rig, 'Stop');
  noPending(rig);
  assert.equal(rig.state[0].playing, false);
  assert.equal(rig.publishedAttempts().at(-1).state[0].playing, false, 'the published take already reflects stopped intent');
  assert.equal(duration(rig), 4);
  near(rig.config.tempo, 240 / 1.75);
  assert.equal(rig.history().tracks[0].undo.length, 1);
  rig.advance(2000);
  noPending(rig);
  assert.equal(layers(rig).length, 1);
});

for (const mode of ['sync', 'band']) {
  test(mode + ' Auto uses a primary established by closing the previous capture in the same command', () => {
    const rig = rigFor(mode);
    rig.config.primaryTrack = 'Track 1';
    command(rig, 'Record / Play');
    rig.advance(4000);
    command(rig, 'Record / Play', 1);
    assert.equal(duration(rig), 8);
    assert.equal(rig.state[0].playing, true);
    assert.equal(rig.capture[1], 'recording');
    rig.advance(1500);
    command(rig, 'Record / Play', 1);
    assert.deepEqual(pending(rig), [{track:1, action:'Play', timing:'Primary cycle · 5 beats'}]);
    rig.advance(2500);
    noPending(rig);
    assert.equal(duration(rig, 1), 8);
    assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:0, beats:8}]);
    assert.equal(rig.state[0].playing, true);
  });

  for (const setting of [{speed:2}, {reverse:true}, {once:true}, {follow:false}]) {
    test(mode + ' Auto uses a stable musical cycle with primary playback ' + JSON.stringify(setting), () => {
      const rig = rigFor(mode);rig.config.primaryTrack = 'Track 1';rig.record(0, 8);
      rig.overrides[0] = setting;rig.advance(1000);
      command(rig, 'Record / Play', 1);assert.equal(rig.capture[1], 'recording');
      rig.advance(1000);command(rig, 'Record / Play', 1);
      assert.deepEqual(pending(rig), [{track:1,action:'Play',timing:'Primary cycle · 4 beats'}]);
      rig.advance(2000);noPending(rig);assert.equal(duration(rig, 1), 8);
      assert.deepEqual(layers(rig, 1)[0].regions,[{offsetBeats:2,beats:6}]);
      assert.equal(layers(rig, 1)[0].seconds,3);
    });
  }
  test(mode + ' active Auto permits primary playback changes without moving its musical finish', () => {
    const rig=rigFor(mode);rig.config.primaryTrack='Track 1';rig.record(0,8);
    command(rig,'Record / Play',1);rig.advance(500);
    assert.equal(rig.transport.allowPlaybackChange(),true);
    assert.equal(rig.transport.allowPlaybackChange(0),true);
    rig.overrides[0]={speed:2,reverse:true,once:true,follow:false};
    command(rig,'Record / Play',1);rig.advance(3500);noPending(rig);
    assert.equal(duration(rig,1),8);assert.equal(layers(rig,1)[0].seconds,4);
  });
}

for (const mode of ['sync', 'band']) {
  test(mode + ' playback change flushes a due start and a due finish before applying', () => {
    const rig = rigFor(mode);
    rig.config.primaryTrack = 'Track 1';
    rig.record(0, 8);
    rig.config.quantize = 'bar';
    rig.advance(500);
    command(rig, 'Record / Play', 1);
    assert.equal(rig.capture[1], 'idle');
    assert.equal(pending(rig)[0].action, 'Record');
    rig.elapse(1500); // The scheduler has not ticked at the exact start boundary.
    assert.equal(rig.capture[1], 'idle');
    assert.equal(rig.transport.allowPlaybackChange(0), true);
    assert.equal(rig.capture[1], 'recording');
    rig.advance(500);
    command(rig, 'Record / Play', 1);
    rig.elapse(1500); // The queued finish is now due, still without an intervening tick.
    assert.equal(rig.capture[1], 'recording');
    assert.equal(rig.transport.allowPlaybackChange(0), true);
    noPending(rig);
    assert.equal(duration(rig, 1), 8);
    assert.deepEqual(layers(rig, 1)[0].regions, [{offsetBeats:4, beats:4}]);
  });
}
