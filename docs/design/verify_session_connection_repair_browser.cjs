// Author verification of pending session connection repair on the normal host.
// Controllers, calibration inventories and audio descriptors are simulated.
const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const base = process.env.FX_PROTOTYPE_URL || 'http://127.0.0.1:8768/fx-ux-prototype.html';
const key = 'segno-fx-factory-design-2026-09-06-channels';
const output = path.join(__dirname, 'session-connection-previews');

async function verify(kind) {
  const browser = await (kind === 'chrome' ? chromium : firefox).launch({headless:true,
    ...(kind === 'chrome' ? {executablePath:process.env.ATLAS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'} : {})});
  try {
    const page = await browser.newPage({viewport:{width:1920, height:1080}}), errors = [];
    page.setDefaultTimeout(6000);
    page.on('pageerror', error => errors.push(error.message));
    const state = () => page.evaluate(() => segnoDemo.snapshot());
    const dialog = async () => (await state()).sessions.dialog;
    const button = id => page.locator('[data-action=' + JSON.stringify(id) + ']');
    const click = id => button(id).click();
    const persisted = () => page.evaluate(key => localStorage.getItem(key), key);
    const live = async () => {const s = await state();return {rig:s.rig, parts:s.recordedParts, playback:s.trackPlayback, inputs:s.recordingInputs, held:s.held, capture:s.captureState, bank:s.bank};};
    const open = async () => {await click('session:library');await click('session:row:session-2');await click('session:load');};
    const foot = id => page.evaluate(id => {segnoDemo.performanceDown(id, 'connection-test');segnoDemo.performanceUp('connection-test');}, id);
    const chooseControl = async () => {await click('session:connection:0');await click('session:replacement:1');};
    const encoderPress = async id => {
      // The host encoder clamps at each end rather than wrapping.
      await page.evaluate(() => {for (let n = 0; n < 20; n++) segnoDemo.turn(-1);});
      for (let n = 0; n < 20 && (await state()).focusId !== id; n++) await page.evaluate(() => segnoDemo.turn(1));
      assert.equal((await state()).focusId, id, 'encoder reaches ' + id);
      await page.evaluate(() => segnoDemo.press());
    };
    const shot = async name => {
      await page.evaluate(() => document.fonts.ready);
      const outside = await page.locator('.session-dialog button,.session-dialog h2,.session-repair-affected').evaluateAll(elements => {
        const s = document.querySelector('#screen').getBoundingClientRect();
        return elements.filter(e => {const r = e.getBoundingClientRect();return r.top < s.top || r.bottom > s.bottom || r.left < s.left || r.right > s.right;}).map(e => e.textContent);
      });
      assert.deepEqual(outside, []);
      fs.mkdirSync(output, {recursive:true});
      await page.locator('#screen').screenshot({path:path.join(output, kind + '-session-connection-' + name + '.png')});
    };
    await page.goto(base + '?canvas=actual');await page.waitForFunction(() => window.segnoDemo);
    const initial = await state();
    async function seed(mode = 'control') {
      const expected = await page.evaluate(({initial, key, mode}) => {
        const current = structuredClone(initial.rig), names = Array.from({length:8}, (_, i) => 'Track ' + (i + 1));
        Object.assign(current, {recordedParts:{}, trackPlayback:{}, trackLayers:{}, trackLength:{},
          trackLabels:structuredClone(initial.trackLabels), inputLabels:structuredClone(initial.inputLabels), outputLabels:structuredClone(initial.outputLabels),
          liveMonitoring:structuredClone(initial.liveMonitoring), recordingInputs:structuredClone(initial.recordingInputs),
          expressionSettings:structuredClone(initial.expression.saved), audioLibrary:structuredClone(initial.audioLibrary.state)});
        delete current.performanceRecording;
        for (const name of names) {
          current.recordedParts[name] = [];current.trackPlayback[name] = false;
          current.trackLayers[name] = {layers:[]};current.trackLength[name] = {audio:[], durationBeats:0, note:''};
        }
        current.trackFade = {};current.mutedTracks = Array(8).fill(false);current.soloTracks = Array(8).fill(false);
        current.midiMappings = [];current.loopSettings = {...structuredClone(initial.loopSettings), mode:'free', tempo:96};
        current.audioLibrary.prepared = [];current.audioLibrary.backing = null;current.audioLibrary.trackImports = {};
        for (const port of current.expressionSettings.ports) {
          port.type = 'expression';port.calibration = {heel:0, toe:1};port.mappings = [];
          for (const s of port.switches) Object.assign(s, {press:'none', hold:'none', change:'none', mappings:[]});
        }
        const rack = current.racks[0], module = rack.modules.find(m => m.params.length);
        module.expressionId = 'session-original-module';
        const target = JSON.stringify(['fx', rack.id, module.expressionId, module.params[0][0]]);
        const mixTarget = JSON.stringify(['mix', 'Guitar', 'level']);
        const mappings = [
          {id:'expression-tone', target, label:'Tone', detail:'Guitar', heel:.1, toe:.8},
          {id:'expression-level', target:mixTarget, label:'Volume', detail:'Guitar', heel:.25, toe:.9}
        ];
        const midi = id => ({id, device:'keys', source:{kind:'cc', channel:2, number:id==='midi-tone'?1:7},
          enabled:true, behavior:'continuous', controls:[{kind:'parameter', key:id==='midi-tone'?target:mixTarget, label:id==='midi-tone'?'Tone':'Volume', detail:'Guitar', low:.2, high:.75}]});
        const isMidi = ['midi','collision','pages'].includes(mode);
        if (!isMidi) current.expressionSettings.ports[0].mappings = structuredClone(mappings);
        else current.midiMappings = [midi('midi-tone'), midi('midi-level')];
        if (mode === 'occupied') current.expressionSettings.ports[1].mappings = [{...mappings[1], id:'already-on-two'}];
        if (mode === 'collision') current.midiMappings.push({...midi('midi-tone'), id:'usb-existing', device:'usb', enabled:false, source:{kind:'cc', channel:'omni', number:1}});
        if (mode === 'pages') current.midiMappings = Array.from({length:5}, (_, i) => ({...midi('midi-tone'), id:'paged-'+i, device:'missing-'+i, source:{kind:'cc', channel:2, number:i+1}}));
        const snapshot = SegnoSessionFieldOwnership.capture(current);
        if (mode === 'media') {snapshot.audioLibrary.prepared = ['missing-audio'];snapshot.audioLibrary.backing = {id:'missing-audio', name:'Lost backing.wav', seconds:222, format:'WAV'};}
        current.expressionSettings.ports[0].type = 'dual';
        current.expressionSettings.ports[0].calibration = {heel:.1, toe:.9};current.expressionSettings.ports[0].mappings = [];
        current.expressionSettings.ports[1].calibration = mode === 'uncalibrated' ? null : {heel:.2, toe:.75};current.expressionSettings.ports[1].mappings = [];
        current.midiMappings = [];current.loopSettings.tempo = 120;
        current.recordedParts['Track 1'] = ['Guitar'];current.trackLength['Track 1'] = {audio:[], durationBeats:8, note:'Current loop'};
        current.trackLayers['Track 1'] = {layers:[{id:'current-take', beats:8, gain:1, regions:[{offsetBeats:0, beats:8}]}]};
        current.inputLabels.Guitar = 'Current microphone';current.outputLabels['Main output'] = 'Current PA';
        current.audioDeviceConfig = {id:'stage', rate:96000, frames:128, measurement:null};
        current.midiControlSettings = {enabled:false};current.syncSettings = {source:'internal', thru:true};
        current.sessionLibrary = {nextId:3, current:{id:'session-1', name:'Current loop', updated:1}, folders:[],
          sessions:[{id:'session-2', name:'Evening set', updated:1, snapshot}]};
        localStorage.setItem(key, JSON.stringify(current));return {current, snapshot, mappings};
      }, {initial, key, mode});
      await page.goto(base + '?canvas=actual');await page.waitForFunction(() => window.segnoDemo);
      assert.equal(new URL(page.url()).searchParams.has('review'), false);
      await page.evaluate(() => segnoDemo.expressionConnect(1, true));
      return expected;
    }
    const unchanged = async (before, saved) => {assert.deepEqual(await live(), before);assert.equal(await persisted(), saved);};
    const assertControl = (s, expected) => {
      assert.equal(s.rig.sessionLibrary.current.id, 'session-2');
      assert.equal(s.rig.expressionSettings.ports[0].type, 'dual');
      assert.deepEqual(s.rig.expressionSettings.ports[0].calibration, {heel:.1, toe:.9});
      assert.deepEqual(s.rig.expressionSettings.ports[0].mappings, []);
      assert.equal(s.rig.expressionSettings.ports[1].type, 'expression');
      assert.deepEqual(s.rig.expressionSettings.ports[1].calibration, {heel:.2, toe:.75});
      assert.deepEqual(s.rig.expressionSettings.ports[1].mappings, expected.mappings);
      assert.deepEqual(s.rig.syncSettings, expected.current.syncSettings);
      assert.deepEqual(s.rig.midiControlSettings, expected.current.midiControlSettings);
      assert.deepEqual(s.rig.audioDeviceConfig, expected.current.audioDeviceConfig);
      assert.equal(s.inputLabels.Guitar, 'Current microphone');
      assert(Object.values(s.trackPlayback).every(v => !v));
      assert.deepEqual(s.rig.sessionLibrary.sessions.find(s => s.id === 'session-1').snapshot.trackLayers['Track 1'].layers, expected.current.trackLayers['Track 1'].layers);
    };

    // A chosen replacement is a pending proposal; Back, Reset and Cancel publish nothing.
    let expected = await seed(), before = await live(), saved = await persisted();
    await open();assert.equal((await dialog()).type, 'dependencies');await unchanged(before, saved);await shot('missing');
    await click('session:connection:0');assert.deepEqual((await dialog()).connection, {kind:'control', port:0});
    assert(await button('session:replacement:0').isDisabled());assert(await button('session:replacement:1').isEnabled());
    assert.match(await page.locator('.session-repair-affected').innerText(), /Tone/);
    assert.match(await page.locator('.session-repair-affected').innerText(), /Volume/);
    await shot('picker');await click('session:connection-back');await unchanged(before, saved);
    await chooseControl();assert.match(await button('session:dependency-retry').innerText(), /Apply and open/);
    assert.deepEqual((await dialog()).repaired.expressionSettings.ports[1].mappings, expected.mappings);
    await unchanged(before, saved);await shot('ready');
    await click('session:connection-reset');assert.equal((await dialog()).changes.length, 0);await unchanged(before, saved);
    await chooseControl();await click('session:dependency-cancel');assert.equal(await dialog(), null);await unchanged(before, saved);

    // Incompatible, occupied, uncalibrated and disconnected replacements stay disabled.
    for (const mode of ['occupied','uncalibrated','disconnected']) {
      await seed(mode);if (mode === 'disconnected') await page.evaluate(() => segnoDemo.expressionConnect(1, false));
      before = await live();saved = await persisted();await open();await click('session:connection:0');
      assert(await button('session:replacement:1').isDisabled());
      assert.match(await button('session:replacement:1').innerText(), mode === 'occupied' ? /already has assignments/ : mode === 'uncalibrated' ? /Calibrate/ : /not connected/);
      await click('session:dependency-cancel');await unchanged(before, saved);
    }

    // Current connection state is checked again at Apply; a failed writer preserves the same draft.
    expected = await seed();before = await live();saved = await persisted();await open();await chooseControl();
    const repaired = structuredClone((await dialog()).repaired);
    await page.evaluate(() => segnoDemo.expressionConnect(1, false));await click('session:dependency-retry');
    assert.equal((await dialog()).type, 'dependencies');assert.deepEqual((await dialog()).repaired, repaired);
    assert.match(await page.locator('.session-dialog').innerText(), /CTRL 2 is not connected/);await unchanged(before, saved);
    await page.evaluate(() => segnoDemo.expressionConnect(1, true));
    await page.evaluate(key => {window.connectionWriter = Storage.prototype.setItem;Storage.prototype.setItem = function(k, v) {if (k === key) throw new DOMException('Full', 'QuotaExceededError');return window.connectionWriter.call(this, k, v);};}, key);
    try {
      await click('session:dependency-retry');assert.match((await state()).sessions.error, /Could not save/);
      assert.equal((await dialog()).type, 'dependencies');assert.deepEqual((await dialog()).repaired, repaired);await unchanged(before, saved);
    } finally {await page.evaluate(() => {Storage.prototype.setItem = window.connectionWriter;delete window.connectionWriter;});}
    // The failed Apply retained encoder focus on Apply, so one press retries it.
    assert.equal((await state()).focusId, 'session:dependency-retry');
    await page.evaluate(() => segnoDemo.press());assertControl(await state(), expected);
    await page.reload();assertControl(await state(), expected);

    // Every replacement decision is reachable with the encoder alone.
    expected = await seed();before = await live();saved = await persisted();await open();
    await encoderPress('session:connection:0');await encoderPress('session:replacement:1');
    await unchanged(before, saved);await encoderPress('session:dependency-retry');assertControl(await state(), expected);

    // MIDI moves the exact device field for every mapping; target/channel/range IDs are unchanged.
    expected = await seed('midi');before = await live();saved = await persisted();await open();await click('session:connection:0');
    assert(await button('session:replacement:keys').isDisabled());assert(await button('session:replacement:usb').isEnabled());
    await shot('midi');await click('session:replacement:usb');await unchanged(before, saved);
    assert.deepEqual((await dialog()).repaired.midiMappings, expected.snapshot.midiMappings.map(m => ({...m, device:'usb'})));
    await click('session:dependency-retry');assert.deepEqual((await state()).rig.midiMappings, expected.snapshot.midiMappings.map(m => ({...m, device:'usb'})));
    await page.reload();assert.deepEqual((await state()).rig.midiMappings, expected.snapshot.midiMappings.map(m => ({...m, device:'usb'})));
    await seed('collision');before = await live();saved = await persisted();await open();await click('session:connection:0');
    assert(await button('session:replacement:usb').isDisabled());assert.match(await button('session:replacement:usb').innerText(), /overlaps/);
    assert(await button('session:replacement:din').isEnabled());await click('session:dependency-cancel');await unchanged(before, saved);

    // Existing media repair can feed the pending connection repair without publishing either early.
    expected = await seed('media');before = await live();saved = await persisted();await open();
    assert((await state()).sessions.recovery.draft);await click('recover:choose:missing-audio');await click('recover:file:inside-1');await click('recover:open');
    assert.equal((await dialog()).type, 'dependencies');await unchanged(before, saved);await chooseControl();
    assert.equal((await dialog()).repaired.audioLibrary.backing.id, 'inside-1');await click('session:dependency-retry');
    assertControl(await state(), expected);assert.equal((await state()).rig.audioLibrary.backing.id, 'inside-1');
    assert.equal((await state()).sessions.recovery.draft, null);

    // Foot entry keeps every track contact within repair. STOP backs out of the picker, CLEAR resets.
    expected = await seed();await click('session:library');await click('stage');before = await live();saved = await persisted();
    await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));await foot(4);
    assert.deepEqual((await dialog()).connection, {kind:'control', port:0});await foot(1);assert.equal((await dialog()).connection, null);
    await foot(4);await foot(4);assert.equal((await dialog()).changes.length, 1);await unchanged(before, saved);
    await foot(8);assert.equal((await dialog()).changes.length, 0);await foot(4);await foot(4);await foot(3);
    assert.equal((await state()).page, 'stage');assert.equal(await dialog(), null);await unchanged(before, saved);
    await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));await foot(4);await foot(4);await foot(1);
    assertControl(await state(), expected);assert.equal((await state()).page, 'stage');

    // A held choice is tied to its original action and pending request, never renumbered on release.
    await seed('midi');await click('session:library');await click('stage');before = await live();saved = await persisted();
    await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));await foot(4);
    await page.evaluate(() => segnoDemo.performanceDown(4, 'held-usb'));
    await page.evaluate(() => segnoDemo.midiConnect('usb', false));
    await page.evaluate(() => segnoDemo.performanceUp('held-usb'));
    assert.equal((await dialog()).changes.length, 0);assert.equal((await dialog()).repaired, null);
    assert.deepEqual((await dialog()).connection, {kind:'midi', id:'keys'});
    assert.match((await state()).sessions.error, /not connected/);await unchanged(before, saved);
    await foot(3);
    for (const retire of ['cancel-reopen','back','back-reenter','reset']) {
      await seed();await click('session:library');await click('stage');before = await live();saved = await persisted();
      await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));await foot(4);
      if (retire === 'reset') await foot(4);
      await page.evaluate(id => segnoDemo.performanceDown(id, 'stale-contact'), retire === 'reset' ? 1 : 4);
      if (retire === 'cancel-reopen') {await foot(3);await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));await foot(4);}
      else if (retire === 'back' || retire === 'back-reenter') {await foot(1);if (retire === 'back-reenter') await foot(4);}
      else await foot(8);
      const pendingBeforeRelease = structuredClone(await dialog());
      await page.evaluate(() => segnoDemo.performanceUp('stale-contact'));
      assert.deepEqual(await dialog(), pendingBeforeRelease, retire + ' retires the held action');
      await unchanged(before, saved);await foot(3);
    }

    // More than four missing controller rows use BANK without changing the performance bank.
    await seed('pages');await click('session:library');await click('stage');before = await live();saved = await persisted();
    await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));assert.equal((await dialog()).issues.length, 5);
    await foot(9);await foot(4);assert.deepEqual((await dialog()).connection, {kind:'midi', id:'missing-4'});
    await foot(1);await foot(9);await foot(9);await foot(4);
    assert.deepEqual((await dialog()).connection, {kind:'midi', id:'missing-0'}, 'BANK wraps back to the first four connections');
    await foot(1);await foot(3);await unchanged(before, saved);
    assert.deepEqual(errors, []);
    console.log(kind + ': staged CTRL/MIDI repair, disabled/collision choices, disconnect and save retry, touch/encoder/foot controls, media repair and reload passed; four screenshots captured.');
  } finally {await browser.close();}
}
(async () => {for (const kind of ['chrome','firefox']) await verify(kind);})()
  .catch(error => {console.error(error);process.exitCode = 1;});
