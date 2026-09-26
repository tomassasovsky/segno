'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const P = require('./processing-behavior-study.js');
const clone = value => JSON.parse(JSON.stringify(value));
const fx = (id, tailSteps = 0) => ({id, tailSteps, bypassed:false});
function fixture({live=false, auxiliary=false, mono=false, outputLevel=1} = {}) {
  return P.create({
    tracks:[{id:'Guitar', playing:true, hasAudio:true, muted:false, mono, printedPre:['input-drive'],
      pre:[fx('track-pre')], post:[fx('track-delay', 2)], routes:['Main'], level:.7}],
    inputs:[{id:'Voice', monitoring:true, signal:live, recordingTrimDb:-6, level:.8,
      pre:[fx('voice-pre')], post:[fx('voice-post', 1)], routes:['Main']}],
    auxiliary:[{id:'Backing', playing:auxiliary, routes:['Main']}, {id:'Click', playing:auxiliary, routes:['Main']}],
    outputs:[{id:'Main', fx:[fx('main-reverb', 2)], level:outputLevel}, {id:'Monitor', fx:[fx('monitor-reverb', 1)], level:1}],
  });
}
const origins = packets => [...new Set(packets.flatMap(packet => packet.origins))].sort();
const observe = (state, type, id, value) => P.advance(P.action(state, type, id, value));

test('ordinary Stop ends the recorded feed while Post and output tails drain independently of live input', () => {
  let state = P.advance(fixture({live:true}));
  state = observe(state, 'stop', 'Guitar');
  assert.equal(state.frame.tracks.Guitar.feed, false);
  assert(state.frame.tracks.Guitar.audible.length > 0);
  assert(state.frame.tracks.Guitar.audible.every(packet => packet.tail));
  assert.equal(state.frame.inputs.Voice.feed, true);
  assert(origins(state.frame.outputs.Main.incoming).includes('Voice'));
  for (let i = 0; i < 6; i++) state = P.advance(state);
  assert.deepEqual(state.frame.tracks.Guitar.audible, []);
  assert.deepEqual(origins(state.frame.outputs.Main.audible), ['Voice']);
  assert.deepEqual(state.frame.outputs.Monitor.audible, []);
});

for (const control of ['input-signal', 'monitor']) test(control + ' stops fresh live feed, drains tails, and resumes without changing other input settings', () => {
  let state = P.advance(fixture({live:true}));
  state = observe(state, 'stop', 'Guitar');
  state = observe(state, control, 'Voice', false);
  assert.equal(state.frame.inputs.Voice.feed, false);
  assert(state.frame.inputs.Voice.audible.some(packet => packet.tail));
  assert.equal(state.inputs[0][control === 'monitor' ? 'signal' : 'monitoring'], true);
  assert.equal(state.inputs[0].recordingTrimDb, -6);
  assert.equal(state.inputs[0].level, .8);
  for (let i=0; i<8; i++) state=P.advance(state);
  assert.deepEqual(state.frame.inputs.Voice.audible, []);
  assert.deepEqual(state.frame.outputs.Main.audible, []);
  state=observe(state, control, 'Voice', true);
  assert.equal(state.frame.inputs.Voice.feed, true);
  assert(state.frame.inputs.Voice.audible.some(packet => !packet.tail));
  assert.deepEqual(origins(state.frame.outputs.Main.incoming), ['Voice']);
  assert.equal(state.tracks[0].playing, false);
});

test('captured Pre alone cannot keep the stopped player audible', () => {
  let state = P.create({tracks:[{id:'Guitar', playing:true, printedPre:['captured-reverb'], post:[], routes:['Main']}],
    outputs:[{id:'Main', fx:[]}]});
  state = P.advance(state);
  assert(state.frame.outputs.Main.audible[0].path.includes('printed:captured-reverb'));
  state = observe(state, 'stop', 'Guitar');
  assert.deepEqual(state.frame.outputs.Main.audible, []);
});

test('Mute gates all of Track Post while the already mixed output tail survives', () => {
  let state = P.advance(fixture());
  state = observe(state, 'mute', 'Guitar', true);
  assert.equal(state.tracks[0].playing, true);
  assert(state.frame.tracks.Guitar.post.length > 0, 'Mute does not flush private processor history');
  assert.deepEqual(state.frame.tracks.Guitar.audible, []);
  assert.deepEqual(state.frame.outputs.Main.incoming, []);
  assert(state.frame.outputs.Main.audible.every(packet => packet.tail && packet.path.includes('fx:main-reverb')));
  assert(state.frame.outputs.Main.audible.length > 0);
  state = P.advance(P.advance(state));
  assert.deepEqual(state.frame.outputs.Main.audible, []);
  state = observe(state, 'mute', 'Guitar', false);
  assert(state.frame.tracks.Guitar.audible.length > 0);
});

test('Clear ends the recorded feed and removes playable content without flushing downstream tails', () => {
  let state = P.advance(fixture());
  state = observe(state, 'clear', 'Guitar');
  assert.equal(state.tracks[0].hasAudio, false);
  assert.equal(state.frame.tracks.Guitar.feed, false);
  assert(state.frame.tracks.Guitar.audible.some(packet => packet.tail));
  assert(state.frame.outputs.Main.audible.some(packet => packet.tail));
  for (let i = 0; i < 6; i++) state = P.advance(state);
  assert.deepEqual(state.buffers, {});
  assert.deepEqual(state.frame.outputs.Main.audible, []);
  assert.equal(observe(state, 'play', 'Guitar').frame.tracks.Guitar.feed, false);
});

test('bypass passes new dry feed and drains only the existing wet tail', () => {
  let state = P.advance(fixture());
  state = observe(state, 'bypass', 'track-delay', true);
  const post = state.frame.tracks.Guitar.post;
  assert(post.some(packet => !packet.tail && packet.path.includes('dry:track-delay') && !packet.path.includes('fx:track-delay')));
  assert(post.some(packet => packet.tail && packet.path.includes('fx:track-delay')));
  state = P.advance(P.advance(state));
  assert(state.frame.tracks.Guitar.post.every(packet => !packet.tail && packet.path.includes('dry:track-delay')));
  assert.equal(state.buffers['track-delay'], undefined);
  assert.throws(() => P.action(state, 'bypass', 'track-pre', true), /prepared replacement/);
});

test('explicit all-sound cut clears existing tails without changing the monitoring preference', () => {
  const previous = P.advance(fixture({live:true, auxiliary:true}));
  const state = P.action(previous, 'all-sound-cut');
  assert.deepEqual(state.buffers, {});
  assert(state.tracks.every(track => !track.playing));
  assert(state.auxiliary.every(source => !source.playing));
  assert.deepEqual(state.frame.outputs.Main.audible, []);
  assert.equal(state.inputs[0].monitoring, true);
  assert.deepEqual(origins(P.advance(state).frame.outputs.Main.audible), ['Voice'], 'later live input is a new feed, not a retained tail');
  assert(previous.buffers['main-reverb']);
});

test('output bypass preserves a previously mixed tail while new routed sources pass dry', () => {
  let state = P.advance(fixture({live:true, auxiliary:true}));
  state = observe(state, 'bypass', 'main-reverb', true);
  const output = state.frame.outputs.Main.afterFx;
  assert.deepEqual(origins(output.filter(packet => !packet.tail)), ['Backing', 'Click', 'Guitar', 'Voice']);
  assert(output.filter(packet => !packet.tail).every(packet => packet.path.includes('dry:main-reverb') && !packet.path.includes('fx:main-reverb')));
  assert(output.some(packet => packet.tail && packet.path.includes('fx:main-reverb')));
  state = P.advance(P.advance(state));
  assert(state.frame.outputs.Main.afterFx.every(packet => !packet.path.includes('fx:main-reverb')));
});

test('new captured parts copy input Pre/Post independently and omit live Mixer level from capture gain', () => {
  const input = clone(fixture().inputs[0]), before = clone(input);
  const captured = P.captureRecipe(input, 'take-a');
  input.pre[0].bypassed = true; input.post[0].tailSteps = 8; input.recordingTrimDb = 12; input.level = .1;
  assert.deepEqual(captured.pre, before.pre);
  assert.deepEqual(captured.post, before.post);
  assert.equal(captured.recordingTrimDb, -6);
  assert.equal(captured.originalDryRetained, true);
  assert.equal(captured.liveMixerLevelPrinted, false);
  assert.equal(captured.level, undefined);
  assert.throws(() => { captured.post[0].tailSteps = 3; }, TypeError);
});

test('recording trim never changes the live processing branch', () => {
  const first = clone(fixture({live:true})), second = clone(first);
  second.inputs[0].recordingTrimDb = 12;
  assert.deepEqual(P.advance(first).frame.inputs, P.advance(second).frame.inputs);
});

test('zero source Mixer levels stop output contributions without inventing fresh tail feed', () => {
  const previous = P.advance(fixture({live:true, auxiliary:true})), mutedLevels = clone(previous);
  for (const source of [...mutedLevels.tracks, ...mutedLevels.inputs, ...mutedLevels.auxiliary]) source.level = 0;
  let state = P.advance(mutedLevels);
  assert.deepEqual(state.frame.outputs.Main.incoming, []);
  assert(state.frame.outputs.Main.audible.length > 0, 'the already mixed tail still drains');
  state = P.advance(P.advance(state));
  assert.deepEqual(state.frame.outputs.Main.audible, []);
});

test('proposed Track Mono averages channels before whole-track Pre and Post', () => {
  assert.deepEqual(P.monoAverage(.8, -.4), [.2, .2]);
  assert.deepEqual(P.monoAverage(1, -1), [0, 0]);
  const packet = P.advance(fixture({mono:true})).frame.tracks.Guitar.post[0];
  assert(packet.path.indexOf('printed:input-drive') < packet.path.indexOf('track-mono-average'));
  assert(packet.path.indexOf('track-mono-average') < packet.path.indexOf('printed:track-pre'));
  assert(packet.path.indexOf('track-mono-average') < packet.path.indexOf('fx:track-delay'));
  assert.equal(packet.path.filter(stage => stage === 'track-mono-average').length, 1);
});

test('true output FX receive every routed source and no source routed elsewhere', () => {
  const initial = clone(fixture({live:true, auxiliary:true}));
  initial.auxiliary[1].routes = ['Monitor'];
  const state = P.advance(initial), main = state.frame.outputs.Main, monitor = state.frame.outputs.Monitor;
  assert.deepEqual(origins(main.incoming), ['Backing', 'Guitar', 'Voice']);
  assert.deepEqual(origins(monitor.incoming), ['Click']);
  assert(main.afterFx.every(packet => packet.path.filter(stage => stage === 'fx:main-reverb').length === 1));
  assert(monitor.afterFx.every(packet => packet.path.includes('fx:monitor-reverb') && !packet.path.includes('fx:main-reverb')));
});

test('performance capture makes the unresolved before/after final-controls tap explicit', () => {
  const state = P.advance(fixture({live:true, auxiliary:true, outputLevel:0}));
  assert.throws(() => P.performanceFrame(state, 'Main'), /explicitly/);
  const before = P.performanceFrame(state, 'Main', 'before-final-controls');
  const after = P.performanceFrame(state, 'Main', 'after-final-controls');
  assert.deepEqual(origins(before.packets), ['Backing', 'Click', 'Guitar', 'Voice']);
  assert(before.packets.every(packet => packet.path.includes('fx:main-reverb')));
  assert.deepEqual(after.packets, []);
  assert.equal(before.duration, 'elapsed-recording-time');
  const quarter = P.advance(fixture({outputLevel:.25}));
  assert.equal(P.performanceFrame(quarter, 'Main', 'after-final-controls').packets[0].level, .175);
  const muted = clone(fixture()); muted.outputs[0].muted = true;
  const mutedFrame = P.advance(muted);
  assert(P.performanceFrame(mutedFrame, 'Main', 'before-final-controls').packets.length > 0);
  assert.deepEqual(P.performanceFrame(mutedFrame, 'Main', 'after-final-controls').packets, []);
});

test('USB export copies the finished file and its capture provenance without another render', () => {
  const file = {id:'performance-1', name:'Take 1.wav', seconds:91.5, format:'WAV', recipe:{captureTap:'after-final-controls'}};
  const exported = P.exportFile(file);
  file.recipe.captureTap = 'before-final-controls';
  assert.equal(exported.render, false);
  assert.equal(exported.file.seconds, 91.5);
  assert.equal(exported.file.recipe.captureTap, 'after-final-controls');
});

test('actions and observations leave input state unchanged and return immutable snapshots', () => {
  const state = P.advance(fixture()), before = clone(state);
  P.advance(state); P.action(state, 'mute', 'Guitar', true); P.action(state, 'clear', 'Guitar');
  assert.deepEqual(state, before);
  assert(Object.isFrozen(state.buffers['track-delay'].packet));
  assert.throws(() => { state.tracks[0].playing = false; }, TypeError);
});

if (process.env.SEGNO_PROCESSING_BROWSER === '1') {
  const {chromium, firefox} = require('playwright');
  const fs = require('node:fs'), path = require('node:path');
  for (const kind of ['chrome', 'firefox']) test(kind + ' standalone processing preview uses action and encoder paths without overflow', async () => {
    const browser = await (kind === 'chrome' ? chromium : firefox).launch({headless:true,
      ...(kind === 'chrome' ? {executablePath:process.env.ATLAS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'} : {})});
    try {
      const page = await browser.newPage({viewport:{width:1920, height:1080}}), errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(process.env.PROCESSING_PREVIEW_URL || 'http://127.0.0.1:8768/processing-behavior-preview.html');
      await page.waitForFunction(() => window.processingReview);
      await page.evaluate(() => document.fonts.ready);
      const button = action => page.locator('[data-action=' + JSON.stringify(action) + ']');
      const state = () => page.evaluate(() => processingReview.snapshot().state);
      const shot = async name => {
        if (!process.env.SEGNO_PROCESSING_SCREENSHOTS) return;
        const output = path.join(__dirname, 'processing-behavior-previews');
        fs.mkdirSync(output, {recursive:true}); await page.screenshot({path:path.join(output, kind + '-' + name + '.png')});
      };
      const bounds = async () => assert.deepEqual(await page.locator('button,.row,.comparison,footer').evaluateAll(elements => elements.filter(element => {
        if (element.offsetParent === null) return false;
        const r = element.getBoundingClientRect(); return r.left < 0 || r.right > innerWidth || r.bottom > innerHeight || r.top < 0;
      }).map(element => element.textContent)), []);
      await bounds(); await shot('tails');
      await button('stop').focus(); await page.keyboard.press('Enter');
      assert.equal((await state()).frame.tracks.Guitar.feed, false);
      assert.equal((await state()).frame.inputs.Voice.feed, true);
      assert((await state()).frame.tracks.Guitar.audible.every(packet => packet.tail));
      await shot('stop');
      await page.keyboard.press('ArrowDown');
      assert.equal(await page.evaluate(() => document.activeElement.dataset.action), 'mute');
      await page.keyboard.press('Enter');
      assert.deepEqual((await state()).frame.tracks.Guitar.audible, []);
      await button('reset').click(); await button('stop').click(); await button('live').click();
      assert.equal((await state()).frame.inputs.Voice.feed, false);
      assert.equal((await state()).inputs[0].monitoring, true);
      assert.equal(await button('live').getAttribute('aria-pressed'), 'false');
      for(let i=0;i<8;i++)await button('step').click();
      assert.deepEqual((await state()).frame.outputs.Main.audible, []);
      await button('live').click();
      assert.equal((await state()).frame.inputs.Voice.feed, true);
      assert.equal(await button('live').getAttribute('aria-pressed'), 'true');
      assert.deepEqual(origins((await state()).frame.outputs.Main.incoming), ['Voice']);
      await button('reset').click(); await button('bypass').click();
      assert((await state()).frame.tracks.Guitar.post.some(packet => !packet.tail && packet.path.includes('dry:track-delay')));
      await button('cut').click(); assert.deepEqual((await state()).buffers, {});
      assert.deepEqual((await state()).frame.outputs.Main.audible, []);
      await button('reset').click(); await button('clear').click();
      assert.equal((await state()).tracks[0].hasAudio, false);
      await button('tab:capture').click(); await bounds();
      assert.match(await page.locator('#cycle-result').textContent(), /^6 bars/);
      await button('cut-tails').click(); assert.match(await page.locator('#cycle-result').textContent(), /end at boundary/);
      await button('level:0').click();
      assert.equal(await page.locator('#before-signal').textContent(), 'Recording receives signal');
      assert.equal(await page.locator('#after-signal').textContent(), 'Recording receives silence');
      await shot('capture-taps');
      await button('level:1').click(); assert.equal(await page.locator('#after-signal').textContent(), 'Recording receives signal');
      await page.setViewportSize({width:1280, height:1024}); await bounds();
      await button('tab:tails').click(); await bounds();
      assert.deepEqual(errors, []);
    } finally { await browser.close(); }
  });
}
