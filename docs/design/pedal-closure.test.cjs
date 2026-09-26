// Author-only silent prototype contracts. No audio or physical pedal proof.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');
const {createRig, clone} = require('./audio-state-test-harness.cjs');

function studies() {
  const context = {window: {}, Map, Set};
  vm.createContext(context);
  for (const file of ['pedal-action-catalogue.js', 'mapping-action-dispatch.js', 'transpose-performance-study.js', 'pedal-color-editor.js', 'pedal-ux-study.js', 'loop-ux-study.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, file), 'utf8'), context, {filename: file});
  }
  context.createPedalColorEditor = context.window.createPedalColorEditor;
  context.SegnoPedalWidget = {indicator: () => '', face: () => ''};
  return context.window;
}

test('global transpose bypass retains shifts across selection, bank and reentry; Reset remains independent', () => {
  const w = studies(), pitches = [3, -2, 0, 0, 7, 0, 0, 0], events = [];
  let enabled = true, current = 0, refuseSave = false;
  const t = w.createTransposePerformanceStudy({trackNames: pitches.map((_, i) => 'Track ' + (i + 1)), currentTrack: () => current, transport: (...args) => events.push(args), state: {
    get: i => pitches[i], hasAudio: i => [0, 1, 4].includes(i), enabled: () => enabled,
    setEnabled: value => {if (refuseSave) return false; enabled = value; return true;},
    write: changes => changes.forEach(({track, pitch}) => pitches[track] = pitch),
  }});
  t.enter(); t.toggle(1);
  const stored = [...pitches], selected = clone(t.snapshot().selected);
  t.run('Toggle transpose');
  assert.equal(t.snapshot().enabled, false);
  assert.deepEqual(clone(t.snapshot().effectivePitches), Array(8).fill(0));
  assert.deepEqual(pitches, stored);
  assert.deepEqual(clone(t.snapshot().selected), selected);
  assert.match(t.body(), /Transpose bypassed/);
  assert.equal(t.role(0).hint, 'Hold · Enable');
  t.toggle(4); assert.equal(t.role(4, 1).pitch, '+7');
  current = 4; t.enter();
  assert.deepEqual(clone(t.snapshot().selected), [4]);
  t.run('Toggle transpose');
  assert.deepEqual(clone(t.snapshot().effectivePitches), stored);
  assert.deepEqual(pitches, stored);
  t.run('Toggle transpose'); t.run('Pitch up');
  assert.equal(pitches[4], 8);
  assert.equal(t.effectivePitch(4), 0, 'editing a stored shift does not enable transpose');
  t.run('Reset pitch');
  assert.equal(pitches[4], 0); assert.deepEqual(pitches.slice(0, 2), [3, -2]);
  assert.equal(t.snapshot().enabled, false);
  refuseSave = true;
  assert.equal(t.toggleEnabled(), false);
  assert.equal(t.snapshot().enabled, false);
  assert.deepEqual(events, [], 'bypass, pitch steps and reset never trigger transport');
  assert.deepEqual(clone(t.assignments(0)), {press: 'Record / Play', hold: 'Toggle transpose'});
});

function pedalRig() {
  const w = studies();
  let saved, focus, writes = 0, fail = false;
  const p = w.createPedalStudy({read: () => saved, write: value => {writes++; if (fail) return false; saved = clone(value); return true;}, render: () => {}, setFocus: value => focus = value, indicatorState: () => false});
  saved = p.state(); saved.calibration = {expression: [.08, .92]}; saved.leds[4] = 'Violet';
  p.body(); p.action('setup:context:custom');
  return {p, state: () => clone(saved), focus: () => focus, writes: () => writes, fail: value => fail = value};
}

test('clear custom explicitly covers both banks, preserves fixed controls, and supports cancel/save/restore', () => {
  const h = pedalRig(), p = h.p;
  p.action('setup:edit:4:hold'); p.action('setup:choose:Free loop mode');
  p.action('setup:bank'); p.action('setup:edit:4:press'); p.action('setup:choose:Song loop mode');
  const before = clone(p.snapshot().draft), originalSaved = h.state();
  p.action('setup:clear-custom');
  assert.equal(h.focus(), 'setup:clear-cancel');
  assert.match(p.overlay(), /Both banks A and B · Press and Hold/);
  p.action('setup:save'); assert.equal(h.writes(), 0, 'modal blocks background Save');
  p.action('setup:clear-cancel');
  assert.deepEqual(clone(p.snapshot().draft), before); assert.deepEqual(h.state(), originalSaved);
  p.action('setup:clear-custom'); assert.equal(p.finish(), true);
  assert.equal(p.snapshot().clearPending, false); assert.equal(h.focus(), 'setup:clear-custom');
  p.action('setup:clear-custom'); p.action('setup:clear-confirm');
  const cleared = clone(p.snapshot().draft);
  for (const i of [0, 1, 2, 4, 5, 6, 7, 8]) assert.deepEqual(cleared.custom[i], {press: 'None', hold: 'None'});
  assert.ok(cleared.bankB.every(pair => pair.press === 'None' && pair.hold === 'None'));
  for (const key of ['mode', 'recordHold', 'trackHold', 'leds', 'palette', 'calibration']) assert.deepEqual(cleared[key], before[key]);
  assert.deepEqual(cleared.custom[3], before.custom[3]); assert.deepEqual(cleared.custom[9], before.custom[9]);
  assert.equal(p.snapshot().bank, 1); assert.equal(p.snapshot().selected, 4);
  assert.deepEqual(h.state(), originalSaved, 'clearing the draft does not change performance settings');
  p.action('setup:save'); assert.deepEqual(h.state(), cleared);
  p.action('setup:restore-custom'); assert.deepEqual(clone(p.snapshot().draft), before);
  assert.deepEqual(h.state(), cleared, 'restoration also remains a draft until Save');
  p.action('setup:save'); assert.deepEqual(h.state(), before);
  assert.equal(p.snapshot().canRestore, false);
});

test('custom clear survives a refused save and Cancel/discard leave saved assignments intact', () => {
  const h = pedalRig(), p = h.p, original = h.state();
  p.action('setup:clear-custom'); p.action('setup:clear-confirm');
  h.fail(true); p.action('setup:save');
  assert.deepEqual(h.state(), original); assert.equal(p.snapshot().canRestore, true);
  assert.match(p.snapshot().saveError, /Could not save/);
  p.action('setup:cancel'); assert.deepEqual(clone(p.snapshot().draft), original);
  assert.equal(p.snapshot().canRestore, false);
  p.action('setup:clear-custom'); p.discard(); p.body();
  assert.equal(p.snapshot().clearPending, false); assert.deepEqual(clone(p.snapshot().draft), original);
});

function modeRig(beats = [4, 4]) {
  const w = studies(), rig = createRig('free', 8);
  beats.forEach((count, i) => rig.record(i, count));
  rig.transport.command('Stop');
  let pending = null, save = true, requests = 0, sourceToken;
  const messages = [], tracks = () => rig.state.map((track, i) => ({id: 'Track ' + (i + 1), hasAudio: !!track.parts.length, beats: track.length.durationBeats, playing: track.playing}));
  const loop = w.createLoopStudy({getSettings: () => rig.config, recording: () => rig.capture.some(v => ['recording', 'overdubbing'].includes(v)), modeContext: () => ({tracks: tracks(), pending: rig.transport.snapshot().pending.length > 0}), tracks: [], render: () => {}, setFocus: () => {}, confirmMode: mode => pending = mode, closeMode: () => pending = null,
    commitMode: mode => {if (!save) return false; rig.config.mode = mode; rig.state.forEach(t => t.playing = false); return true;},
  });
  const dispatch = w.createMappingActionDispatch({loopMode: (mode, token) => {requests++; sourceToken = token; const choice = loop.modeAvailability(mode); if (!choice.enabled) return {reason: choice.reason}; return loop.action('loop:mode:' + mode);}, feedback: message => messages.push(message)});
  return {w, rig, loop, dispatch, messages, pending: () => pending, cancel: () => pending = null, save: value => save = value, requests: () => requests, sourceToken: () => sourceToken};
}

test('all five assignable mode shortcuts use Settings transition guards and retain recorded content', () => {
  for (const mode of ['multi', 'sync', 'song', 'band', 'free']) {
    const h = modeRig(), before = clone(h.rig.state);
    const entry = h.w.SegnoAssignableActions.find(action => action.key === 'loop-mode:' + mode);
    assert.equal(entry.operation, 'loop-mode'); assert.equal(entry.group, 'loop-modes');
    h.dispatch.dispatch(entry.key, 'external:test');
    assert.equal(h.requests(), 1); assert.equal(h.rig.config.mode, mode);
    assert.equal(h.sourceToken(), 'external:test');
    assert.equal(h.pending(), null); assert.deepEqual(clone(h.rig.state), before);
  }
});

test('mode shortcuts retain playback until confirmed, permit cancellation and recheck capture/save failures', () => {
  const h = modeRig(); h.rig.transport.command('Record / Play', 0);
  const before = clone(h.rig.state);
  h.dispatch.dispatch('loop-mode:song');
  assert.equal(h.pending(), 'song'); assert.equal(h.rig.config.mode, 'free'); assert.deepEqual(clone(h.rig.state), before);
  h.cancel(); assert.deepEqual(clone(h.rig.state), before);
  h.dispatch.dispatch('loop-mode:song'); h.rig.capture[0] = 'overdubbing';
  h.loop.action('loop:mode-confirm:song'); assert.equal(h.rig.config.mode, 'free'); assert.deepEqual(clone(h.rig.state), before);
  h.rig.capture[0] = 'idle'; h.save(false);
  h.loop.action('loop:mode-confirm:song'); assert.equal(h.rig.config.mode, 'free'); assert.deepEqual(clone(h.rig.state), before);
  h.save(true); h.loop.action('loop:mode-confirm:song');
  assert.equal(h.rig.config.mode, 'song'); assert.ok(h.rig.state.every(t => !t.playing));
  const after = clone(h.rig.state); after[0].playing = true; assert.deepEqual(after, before);
});

test('incompatible, recording, queued and unavailable mode shortcuts report the same refusal without mutation', () => {
  const h = modeRig([3, 4]), before = clone(h.rig.state);
  for (const mode of ['multi', 'sync', 'band']) {
    h.dispatch.dispatch('loop-mode:' + mode);
    assert.equal(h.messages.at(-1), h.loop.modeAvailability(mode).reason);
    assert.equal(h.rig.config.mode, 'free'); assert.deepEqual(clone(h.rig.state), before);
  }
  h.rig.capture[1] = 'recording'; h.dispatch.dispatch('loop-mode:song');
  assert.match(h.messages.at(-1), /Finish recording/); assert.equal(h.pending(), null);
  const queued = modeRig([]), empty = clone(queued.rig.state);
  queued.rig.config.start = 'sound'; queued.rig.transport.command('Record / Play', 2);
  assert.ok(queued.rig.transport.snapshot().pending.length > 0);
  queued.dispatch.dispatch('loop-mode:song');
  assert.match(queued.messages.at(-1), /queued action/); assert.equal(queued.rig.config.mode, 'free');
  assert.deepEqual(clone(queued.rig.state), empty);
  const unavailable = h.w.createMappingActionDispatch({feedback: reason => h.messages.push(reason)});
  unavailable.dispatch('loop-mode:free'); assert.equal(h.messages.at(-1), 'Control unavailable');
});
