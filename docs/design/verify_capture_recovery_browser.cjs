// Integrated symbolic capture recovery. All storage checks use the normal URL.
// Wave contours use fixture PCM; this does not verify native recording or DSP.
const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const base = process.env.FX_PROTOTYPE_URL || 'http://127.0.0.1:8768/fx-ux-prototype.html';
const storageKey = 'segno-fx-factory-design-2026-09-06-channels';
const output = path.join(__dirname, 'capture-recovery-previews');
const track = i => 'Track ' + (i + 1);
const layers = (s, i) => s.rig.trackLayers[track(i)].layers;
const duration = (s, i) => s.rig.trackLength[track(i)].durationBeats;
const near = (actual, expected, message) => assert(Math.abs(actual - expected) < 1e-6, message || `${actual} != ${expected}`);
const content = s => ({parts:s.recordedParts, layers:s.rig.trackLayers, length:s.rig.trackLength, history:s.rig.editHistory, playing:s.trackPlayback, capture:s.captureState});

async function verify(kind) {
  const browser = await (kind === 'chrome' ? chromium : firefox).launch({headless:true,
    ...(kind === 'chrome' ? {executablePath:process.env.ATLAS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'} : {})});
  try {
    const context = await browser.newContext({viewport:{width:1920, height:1080}});
    const page = await context.newPage(), errors = [];
    page.setDefaultTimeout(6000);
    page.on('pageerror', error => errors.push(error.message));
    await page.clock.install({time:new Date('2026-09-08T12:00:00Z')});
    await page.clock.pauseAt(new Date('2026-09-08T12:00:01Z'));
    const state = () => page.evaluate(() => segnoDemo.snapshot());
    const transport = () => page.evaluate(() => segnoDemo.transportState());
    const command = key => page.evaluate(key => segnoDemo.dispatchMapping(key), key);
    const select = i => command('select-track:' + i);
    const button = id => page.locator('[data-action=' + JSON.stringify(id) + ']');
    const click = id => button(id).click();
    const advance = milliseconds => page.clock.runFor(milliseconds);
    const live = async () => ({...content(await state()), transport:(await transport()).tracks, pending:(await transport()).pending});
    const saved = () => page.evaluate(key => localStorage.getItem(key), storageKey);
    await page.goto(base + '?canvas=actual');
    await page.waitForFunction(() => window.segnoDemo);
    const initial = await state();

    async function seed() {
      await page.evaluate(({initial, storageKey}) => {
        const rig = structuredClone(initial.rig);
        for (const key of ['recordedParts', 'trackLayers', 'trackLength', 'trackPlayback', 'trackPitch', 'trackReverse', 'trackFade', 'bounceRecipes', 'trackFxBypass']) rig[key] = {};
        rig.expressionMix = {};
        for (let i = 0; i < 8; i++) {
          const t = 'Track ' + (i + 1);
          rig.recordedParts[t] = [];
          rig.trackLayers[t] = {layers:[]};
          rig.trackLength[t] = {audio:[], durationBeats:0, note:''};
          rig.trackPlayback[t] = false;
          rig.expressionMix[t] = {level:1, pan:.5};
        }
        rig.recordingInputs = structuredClone(initial.recordingInputs);
        rig.trackLabels = structuredClone(initial.trackLabels);
        rig.liveMonitoring = structuredClone(initial.liveMonitoring);
        rig.mutedTracks = Array(8).fill(false);
        rig.soloTracks = Array(8).fill(false);
        rig.loopSpeed = 1;
        rig.editHistory = {serial:0, tracks:Array.from({length:8}, () => ({undo:[], redo:[]}))};
        rig.loopSettings = {mode:'multi', tempo:120, signature:'4/4', start:'press', recDub:false, countIn:0,
          lengthTiming:{bars:0, quantize:'immediate'}, trackLengthTiming:{'Track 3':{quantize:'bar'}, 'Track 4':{quantize:'bar'}}, playback:{once:false, decay:25}};
        rig.syncSettings = {source:'internal'};
        rig.audioLibrary = {...structuredClone(initial.audioLibrary.state), prepared:[], backing:null, trackImports:{}};
        delete rig.sessionLibrary;
        delete rig.performanceRecording;
        const effect = structuredClone(rig.racks.find(r => r.modules.length));
        effect.id = 'capture-recovery-effect';
        effect.source = 'Track 2';
        rig.racks.push(effect);
        localStorage.setItem(storageKey, JSON.stringify(rig));
      }, {initial, storageKey});
      await page.goto(base + '?canvas=actual');
      await page.waitForFunction(() => window.segnoDemo);
      assert(!new URL(page.url()).searchParams.has('review'));
      assert.equal((await state()).loopSettings.mode, 'multi');
    }

    async function record(i, beats = 16) {
      await select(i);
      await command('command:record-play');
      await advance(beats * 500);
      if ((await state()).captureState[track(i)] === 'recording') await command('command:record-play');
      near(duration(await state(), i), beats);
    }

    async function storageFailure(value) {
      await page.evaluate(({value, storageKey}) => {
        if (value) {
          window.captureRecoveryWriter = Storage.prototype.setItem;
          Storage.prototype.setItem = function(key, data) {
            if (key === storageKey) throw new DOMException('Simulated full storage', 'QuotaExceededError');
            return window.captureRecoveryWriter.call(this, key, data);
          };
        } else {
          Storage.prototype.setItem = window.captureRecoveryWriter;
          delete window.captureRecoveryWriter;
        }
      }, {value, storageKey});
    }

    async function failedThenRetry(key) {
      const before = await live(), persisted = await saved();
      await storageFailure(true);
      try {
        await command(key);
        assert.deepEqual(await live(), before, `${key}: failed publication must preserve live audio, history, capture and queue`);
        assert.equal(await saved(), persisted, `${key}: failed publication must preserve stored state`);
        assert.match((await transport()).notice.action, /Could not save/);
      } finally { await storageFailure(false); }
      await command(key);
    }

    async function idle() {
      assert(Object.values((await state()).captureState).every(value => value === 'idle'));
      const t = await transport();
      assert.deepEqual(t.pending, []);
      assert(t.tracks.every(row => row.capturing === null));
    }

    async function empty() {
      const s = await state();
      assert(Object.values(s.recordedParts).every(parts => !parts.length));
      assert(Object.values(s.trackPlayback).every(value => !value));
      for (let i = 0; i < 8; i++) assert.deepEqual(layers(s, i), []);
      await idle();
    }

    // The unfinished second take occupies only its captured region in Multi.
    await seed();
    await record(0);
    await advance(3000);
    await select(1);
    await command('command:record-play');
    await advance(2000);
    assert.equal((await state()).captureState['Track 2'], 'recording');
    await select(2);
    await command('command:record-play');
    assert((await transport()).pending.some(row => row.track === 2 && row.timing === 'Next bar'));
    await select(1);
    const established = structuredClone(layers(await state(), 0)), phase = (await transport()).tracks[0].position;
    await failedThenRetry('command:undo');
    assert.deepEqual(layers(await state(), 1), []);
    assert.equal((await state()).captureState['Track 2'], 'idle');
    assert((await transport()).pending.some(row => row.track === 2));
    await command('command:redo');
    let recovered = await state();
    near(duration(recovered, 1), 16);
    near(layers(recovered, 1)[0].beats, 4);
    assert.equal(layers(recovered, 1)[0].regions.length, 1);
    near(layers(recovered, 1)[0].regions[0].offsetBeats, 6);
    near(layers(recovered, 1)[0].regions[0].beats, 4);
    assert.deepEqual(recovered.rig.trackLength['Track 2'].audio, []);
    assert.deepEqual(layers(recovered, 0), established);
    assert.equal(recovered.trackPlayback['Track 1'], true);
    assert.equal(recovered.trackPlayback['Track 2'], true);
    near((await transport()).tracks[0].position, phase);
    near((await transport()).tracks[1].position, phase);
    assert.equal(recovered.loopSettings.mode, 'multi');
    assert.equal(recovered.modal, null);
    await select(2);
    await command('command:undo'); // Cancel the unrelated queued recording.
    await select(1);
    await command('view:wave');
    await page.evaluate(() => document.fonts.ready);
    await advance(2600); // Let the canceled-queue feedback leave the review image.
    let signal = await page.evaluate(() => segnoDemo.displayState().tracks[1]);
    assert.equal(signal.state, 'Playing');
    assert(signal.position * 16 > 10, 'the playhead is in the uncaptured portion');
    assert.equal(signal.meter, 0);
    assert.deepEqual(signal.stereo, {left:0, right:0});
    await advance(((8 - signal.position * 16 + 16) % 16) * 500);
    signal = await page.evaluate(() => segnoDemo.displayState().tracks[1]);
    near(signal.position * 16, 8);
    assert(signal.meter > 0 && signal.stereo.left > 0 && signal.stereo.right > 0, 'the captured region has simulated signal');
    const wave = await page.evaluate(() => segnoDemo.waveState(1));
    const points = await page.locator('[data-wave-track="1"] .wave-envelope path').evaluate(el =>
      [...el.getAttribute('d').matchAll(/(-?[\d.]+),(-?[\d.]+)/g)].map(match => ({x:Number(match[1]) / 1024, y:Number(match[2])})));
    const audible = points.filter(point => Math.abs(point.y - 50) > .01);
    const bounds = {x:Math.min(...audible.map(point => point.x)), width:Math.max(...audible.map(point => point.x)) - Math.min(...audible.map(point => point.x))};
    near(wave.span, 4);
    assert(bounds.x > .37 && bounds.x < .38, 'the waveform begins at the captured shared offset');
    assert(bounds.width > .24 && bounds.width < .26, 'one bar of recorded contour leaves three bars silent');
    assert(points.filter(point => point.x < .375 || point.x >= .625).every(point => point.y === 50), 'the remainder is a silent centerline, not invented waveform content');
    fs.mkdirSync(output, {recursive:true});
    await page.locator('#screen').screenshot({path:path.join(output, kind + '-partial-redo-wave.png')});
    const persistedRegion = structuredClone(layers(await state(), 1));
    await page.reload();
    assert.deepEqual(layers(await state(), 1), persistedRegion);
    near(duration(await state(), 1), 16);
    await select(1);
    await command('command:undo');
    assert.deepEqual(layers(await state(), 1), []);
    await command('command:redo');
    assert.deepEqual(layers(await state(), 1), persistedRegion);

    // The accepted small-screen consumer reads the same recovered SVG path.
    const pair = await context.newPage();
    pair.on('pageerror', error => errors.push(error.message));
    await pair.setViewportSize({width:1920, height:1440});
    await pair.clock.install({time:new Date('2026-09-08T13:00:00Z')});
    await pair.clock.pauseAt(new Date('2026-09-08T13:00:01Z'));
    await pair.goto(new URL('stage-two-screen-preview.html', base).href);
    await pair.locator('#main').evaluate((el, url) => { el.src = url + '?canvas=actual'; }, base);
    await pair.waitForFunction(() => document.querySelector('#main').contentWindow?.segnoDemo && !new URL(document.querySelector('#main').contentWindow.location.href).searchParams.has('review'));
    const main = pair.frames().find(frame => frame.url() === base + '?canvas=actual');
    await main.evaluate(() => {
      segnoDemo.dispatchMapping('select-track:1');
      segnoDemo.dispatchMapping('view:wave');
      segnoDemo.dispatchMapping('command:start-stop-all');
      document.querySelector('#screen').scrollIntoView({block:'start'});
    });
    await pair.clock.runFor(160);
    const mainPath = await main.locator('[data-wave-track="1"] .wave-envelope path').getAttribute('d');
    assert.equal(await pair.locator('.close-wave path').getAttribute('d'), mainPath);
    assert.equal(await pair.locator('#track-number').innerText(), '2');
    await pair.screenshot({path:path.join(output, kind + '-partial-redo-two-displays.png'), fullPage:true});
    await pair.close();

    for (const take of ['initial', 'overdub']) {
      await seed();
      await record(0);
      if (take === 'overdub') await record(1);
      await record(2);
      await command('command:stop');
      await select(0);
      await command('command:record-play');
      if (take === 'overdub') { await select(1); await command('command:record-play'); }
      await advance(3000);
      await select(1);
      await command('command:record-play');
      await advance(2000);
      assert.equal((await state()).captureState['Track 2'], take === 'initial' ? 'recording' : 'overdubbing');
      await select(3);
      await command('command:record-play');
      assert((await transport()).pending.some(row => row.track === 3 && row.timing === 'Next bar'));
      const playingPosition = (await transport()).tracks[0].position;
      await failedThenRetry('command:clear-all');
      await empty();
      const clearId = (await state()).rig.editHistory.tracks[0].undo.at(-1).id;
      assert((await state()).rig.editHistory.tracks.every(row => row.undo.at(-1).id === clearId));

      await click('stage-view-menu');
      await click('stage-view:mixer');
      await button('stage-mix:1:level').evaluate(el => { el.value = '-6'; el.dispatchEvent(new Event('input', {bubbles:true})); });
      await click('stage-fx-power:1');
      const laterMix = structuredClone((await state()).rig.expressionMix['Track 2']);
      assert.equal((await state()).rig.trackFxBypass['Track 2'], true);
      await failedThenRetry('command:undo');
      recovered = await state();
      assert.deepEqual(Object.values(recovered.trackPlayback), [true, false, false, false, false, false, false, false]);
      near((await transport()).tracks[0].position, playingPosition);
      near(duration(recovered, 1), 16);
      assert.equal(layers(recovered, 1).length, take === 'initial' ? 1 : 2);
      near(layers(recovered, 1).at(-1).regions[0].beats, 4);
      if (take === 'overdub') near(layers(recovered, 1)[0].gain, .75);
      assert.deepEqual(recovered.rig.expressionMix['Track 2'], laterMix);
      assert.equal(recovered.rig.trackFxBypass['Track 2'], true);
      await idle();
      const frozen = structuredClone(layers(recovered, 1));
      await advance(8000);
      assert.deepEqual(layers(await state(), 1), frozen, 'restored capture stays stopped and never adds another layer');
      await command('command:redo');
      await empty();
      await page.reload();
      await select(3);
      await command('command:undo');
      assert.deepEqual(layers(await state(), 1), frozen);
      assert.deepEqual((await state()).rig.expressionMix['Track 2'], laterMix);
      assert.equal((await state()).rig.trackFxBypass['Track 2'], true);
      await idle();
      await command('command:redo');
      await empty();
      await record(0, 4);
      await select(2);
      const newer = await live();
      await command('command:undo');
      assert.deepEqual(await live(), newer, 'a newer audio edit on one member blocks old group overwrite');
      assert.match((await transport()).notice.action, /Undo newer edits first/);
      assert.equal((await state()).loopSettings.mode, 'multi');
      assert.equal((await state()).modal, null);
    }
    assert.deepEqual(errors, []);
    console.log(kind + ': Multi partial Undo/Redo, sparse shared Wave, active grouped Clear All, real storage failure/retry, persistence, newer-audio guard and later Mixer/FX preservation passed.');
  } finally { await browser.close(); }
}

(async () => { for (const kind of ['chrome', 'firefox']) await verify(kind); })()
  .catch(error => { console.error(error); process.exitCode = 1; });
