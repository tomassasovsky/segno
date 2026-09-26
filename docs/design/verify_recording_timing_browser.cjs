// Normal-host timing journeys; all persistence assertions use real localStorage.
// The transport, signal and waveform remain symbolic prototype behavior.
const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const base = process.env.FX_PROTOTYPE_URL || 'http://127.0.0.1:8768/fx-ux-prototype.html';
const storageKey = 'segno-fx-factory-design-2026-09-06-channels';
const output = path.join(__dirname, 'shared-behavior-previews');
const track = i => 'Track ' + (i + 1);
const near = (actual, expected) => assert(Math.abs(actual - expected) < 1e-6, `${actual} != ${expected}`);
const layers = (s, i) => s.rig.trackLayers[track(i)].layers;
const duration = (s, i) => s.rig.trackLength[track(i)].durationBeats;

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
    const click = id => page.locator('[data-action=' + JSON.stringify(id) + ']').click();
    const advance = async ms => {
      await page.clock.runFor(ms);
      // A same-track selection flushes elapsed time at an exact fake-clock boundary.
      await page.evaluate(() => segnoDemo.dispatchMapping('select-track:' + segnoDemo.displayState().selected));
    };
    const saved = () => page.evaluate(key => localStorage.getItem(key), storageKey);
    const live = async () => {
      const s = await state(), t = await transport();
      return {parts:s.recordedParts, layers:s.rig.trackLayers, length:s.rig.trackLength,
        history:s.rig.editHistory, tempo:s.loopSettings.tempo, playing:s.trackPlayback,
        capture:s.captureState, tracks:t.tracks, pending:t.pending};
    };
    async function open() {
      await page.goto(base + '?canvas=actual');
      await page.waitForFunction(() => window.segnoDemo);
      assert(!new URL(page.url()).searchParams.has('review'));
    }
    await open();
    const initial = await state();
    async function seed(settings) {
      await page.evaluate(({initial, storageKey, settings}) => {
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
        rig.loopSettings = {mode:'free', tempo:120, signature:'4/4', start:'press', recDub:false,
          click:'always', countIn:0, lengthTiming:{bars:0, quantize:'immediate'}, trackLengthTiming:{},
          playback:{once:false, decay:0}, ...settings};
        rig.syncSettings = {source:'internal'};
        rig.audioLibrary = {...structuredClone(initial.audioLibrary.state), prepared:[], backing:null, trackImports:{}};
        delete rig.sessionLibrary;
        delete rig.performanceRecording;
        localStorage.setItem(storageKey, JSON.stringify(rig));
      }, {initial, storageKey, settings});
      await open();
    }
    async function setSavedSettings(settings) {
      await page.evaluate(({storageKey, settings}) => {
        const s = segnoDemo.snapshot(), rig = s.rig;
        Object.assign(rig, {recordedParts:s.recordedParts, trackPlayback:s.trackPlayback,
          recordingInputs:s.recordingInputs, trackLabels:s.trackLabels, liveMonitoring:s.liveMonitoring,
          loopSettings:{...s.loopSettings, ...settings}});
        delete rig.sessionLibrary;
        localStorage.setItem(storageKey, JSON.stringify(rig));
      }, {storageKey, settings});
      await open();
    }
    async function record(i, beats) {
      await select(i);
      await command('command:record-play');
      await advance(beats * 500);
      await command('command:record-play');
      near(duration(await state(), i), beats);
    }
    async function screenshot(name) {
      await page.evaluate(() => document.fonts.ready);
      await page.locator('#screen').scrollIntoViewIfNeeded();
      const size = await page.locator('#screen').boundingBox();
      near(size.width, 1920);
      near(size.height, 1080);
      fs.mkdirSync(output, {recursive:true});
      await page.locator('#screen').screenshot({path:path.join(output, kind + '-' + name + '.png')});
    }
    async function storageFailure(value) {
      await page.evaluate(({value, storageKey}) => {
        if (value) {
          window.timingOriginalWriter = Storage.prototype.setItem;
          Storage.prototype.setItem = function(key, data) {
            if (key === storageKey) throw new DOMException('Simulated full storage', 'QuotaExceededError');
            return window.timingOriginalWriter.call(this, key, data);
          };
        } else {
          Storage.prototype.setItem = window.timingOriginalWriter;
          delete window.timingOriginalWriter;
        }
      }, {value, storageKey});
    }
    async function pairedCountIn() {
      const pairContext = await browser.newContext({viewport:{width:1920, height:1080}});
      const pair = await pairContext.newPage(), persisted = await saved();
      try {
        await pair.clock.install({time:new Date('2026-09-08T12:00:00Z')});
        await pair.clock.pauseAt(new Date('2026-09-08T12:00:01Z'));
        await pair.goto(new URL('stage-two-screen-preview.html', base).href);
        await pair.evaluate(({storageKey, persisted}) => localStorage.setItem(storageKey, persisted), {storageKey, persisted});
        await pair.evaluate(url => {document.querySelector('iframe').src = url;}, base + '?canvas=actual');
        await pair.waitForFunction(() => {
          const frame = document.querySelector('iframe').contentWindow;
          return !new URL(frame.location.href).searchParams.has('review') && frame.segnoDemo;
        });
        await pair.evaluate(() => {
          const api = document.querySelector('iframe').contentWindow.segnoDemo;
          api.dispatchMapping('select-track:0');
          api.dispatchMapping('command:record-play');
        });
        await pair.clock.runFor(600);
        await pair.evaluate(() => document.querySelector('iframe').contentWindow.segnoDemo.dispatchMapping('select-track:0'));
        await pair.clock.runFor(100);
        assert.match(await pair.locator('#state').innerText(), /^Play · Count-in · 3$/);
        const paired = await pair.evaluate(() => {
          const api = document.querySelector('iframe').contentWindow.segnoDemo;
          return {pending:api.transportState().pending, displayed:api.displayState().pending};
        });
        assert.deepEqual(paired.displayed, paired.pending);
        assert.deepEqual(paired.pending, [{track:0, action:'Play', timing:'Count-in · 3'}]);
      } finally { await pairContext.close(); }
    }

    // A stopped existing loop gets a local count-in; running music does not.
    await seed({});
    await record(0, 8);
    await command('command:stop');
    await setSavedSettings({countIn:1});
    await select(0);
    await command('command:record-play');
    assert.equal((await state()).trackPlayback['Track 1'], false);
    assert.deepEqual((await transport()).pending, [{track:0, action:'Play', timing:'Count-in · 4'}]);
    await advance(500);
    assert.equal((await transport()).pending[0].timing, 'Count-in · 3');
    const countCue = page.locator('[data-queue-track="0"]');
    assert.equal(await countCue.isVisible(), true);
    assert.match(await countCue.innerText(), /Play\s+Count-in · 3/);
    await pairedCountIn();
    await screenshot('timing-count-in');
    await advance(1499);
    assert.equal((await state()).trackPlayback['Track 1'], false);
    await advance(1);
    assert.equal((await state()).trackPlayback['Track 1'], true);
    assert.deepEqual((await transport()).pending, []);
    await select(1);
    await command('command:record-play');
    assert.equal((await state()).captureState['Track 2'], 'recording');
    assert.deepEqual((await transport()).pending, []);
    await command('command:stop');

    // A Sync Auto take starts off the primary downbeat and queues its finish.
    await seed({mode:'sync', primaryTrack:'Track 1', trackPlayback:{'Track 1':{once:false}}, trackAudioTempo:{'Track 1':{follow:true}}});
    await record(0, 16);
    const primary = structuredClone(layers(await state(), 0));
    await advance(1000);
    await select(1);
    await command('command:record-play');
    await advance(2000);
    await command('direct:speed:0.5');
    assert.equal((await state()).rig.loopSpeed, .5);
    await command('direct:reverse:0');
    assert.equal(!!(await state()).rig.trackReverse['Track 1'], true);
    await click('settings');
    await click('loop:page:loop-settings');
    await click('loop:page:loop-playback');
    await click('loop:scope:Track 1');
    await click('loop:once:true');
    assert.equal((await state()).loopSettings.trackPlayback['Track 1'].once, true);
    await click('loop:playback-inherit:once');
    assert.equal((await state()).loopSettings.trackPlayback['Track 1']?.once??false, false);
    await click('back');
    await click('loop:page:loop-audio-tempo');
    await click('loop:audio-tempo:follow:false');
    assert.equal((await state()).loopSettings.trackAudioTempo['Track 1'].follow, false);
    await click('loop:audio-tempo-inherit:follow');
    assert.equal((await state()).loopSettings.trackAudioTempo['Track 1']?.follow??true, true);
    await click('stage');
    await command('direct:speed:1');await command('direct:reverse:0');
    await command('command:record-play');
    let t = await transport();
    assert.equal((await state()).captureState['Track 2'], 'recording');
    assert.deepEqual(t.pending, [{track:1, action:'Play', timing:'Primary cycle · 10 beats'}]);
    assert.match(await page.locator('[data-queue-track="1"]').innerText(), /Primary cycle · 10 beats/);
    await screenshot('timing-cycle-queued');
    await advance(4999);
    assert.equal((await state()).captureState['Track 2'], 'recording');
    await advance(1);
    t = await transport();
    const complete = await state();
    assert.equal(complete.captureState['Track 2'], 'idle');
    assert.deepEqual(t.pending, []);
    assert.equal(complete.trackPlayback['Track 1'], true);
    assert.equal(complete.trackPlayback['Track 2'], true);
    assert.deepEqual(layers(complete, 0), primary);
    near(duration(complete, 1), 16);
    near(layers(complete, 1)[0].beats, 14);
    near(layers(complete, 1)[0].regions[0].offsetBeats, 2);
    near(layers(complete, 1)[0].regions[0].beats, 14);
    near(t.tracks[0].position, 0);
    await command('view:wave');
    const points = await page.locator('[data-wave-track="1"] .wave-envelope path').evaluate(el =>
      [...el.getAttribute('d').matchAll(/(-?[\d.]+),(-?[\d.]+)/g)].map(m => ({x:Number(m[1]) / 1024, y:Number(m[2])})));
    assert(points.filter(p => p.x < .125).every(p => p.y === 50), 'the leading two beats stay silent');
    assert(points.some(p => p.x >= .125 && Math.abs(p.y - 50) > .01), 'captured audio follows the silent leading region');
    await screenshot('timing-cycle-complete');

    // Tempo, content and history are published together through actual storage.
    await seed({click:'off'});
    await command('command:record-play');
    await advance(3500);
    const before = await live(), persisted = await saved();
    await storageFailure(true);
    try {
      await command('command:record-play');
      assert.deepEqual(await live(), before);
      assert.equal(await saved(), persisted);
      assert.match((await transport()).notice.action, /Could not save/);
    } finally { await storageFailure(false); }
    await command('command:record-play');
    const inferred = await state();
    near(inferred.loopSettings.tempo, 480 / 3.5);
    near(duration(inferred, 0), 8);
    near(duration(inferred, 0) * 60 / inferred.loopSettings.tempo, 3.5);
    assert.equal(inferred.captureState['Track 1'], 'idle');
    assert.equal(inferred.trackPlayback['Track 1'], true);
    assert.equal(inferred.rig.editHistory.tracks[0].undo.length, 1);
    near(JSON.parse(await saved()).loopSettings.tempo, 480 / 3.5);
    await screenshot('timing-first-take');
    await page.reload();
    const reloaded = await state();
    near(reloaded.loopSettings.tempo, 480 / 3.5);
    near(duration(reloaded, 0), 8);
    assert.deepEqual(layers(reloaded, 0), layers(inferred, 0));
    assert.equal(reloaded.rig.editHistory.tracks[0].undo.length, 1);
    assert.deepEqual(errors, []);
    console.log(kind + ': stopped/running count-in, Sync Auto cue and leading silence, inferred-tempo save failure/retry and reload passed; four 1920×1080 screenshots captured.');
  } finally { await browser.close(); }
}

(async () => { for (const kind of ['chrome', 'firefox']) await verify(kind); })()
  .catch(error => {console.error(error); process.exitCode = 1;});
