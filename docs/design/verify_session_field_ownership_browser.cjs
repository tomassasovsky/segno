// Author browser verification on the normal storage-enabled prototype URL.
// Device identity, control connections and audio remain simulated.
const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const base = process.env.FX_PROTOTYPE_URL || 'http://127.0.0.1:8768/fx-ux-prototype.html';
const key = 'segno-fx-factory-design-2026-09-06-channels';
const output = path.join(__dirname, 'session-field-ownership-previews');

async function verify(kind) {
  const browser = await (kind === 'chrome' ? chromium : firefox).launch({headless:true,
    ...(kind === 'chrome' ? {executablePath:process.env.ATLAS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'} : {})});
  try {
    const page = await browser.newPage({viewport:{width:1920, height:1080}}), errors = [];
    page.setDefaultTimeout(6000); page.on('pageerror', error => errors.push(error.message));
    const state = () => page.evaluate(() => segnoDemo.snapshot());
    const button = id => page.locator('[data-action=' + JSON.stringify(id) + ']');
    const click = id => button(id).click();
    const live = async () => {const s = await state();return {rig:s.rig, parts:s.recordedParts, playback:s.trackPlayback, inputs:s.recordingInputs, held:s.held};};
    const open = async () => {await click('session:library');await click('session:row:session-2');await click('session:load');};
    const persisted = () => page.evaluate(key => localStorage.getItem(key), key);
    await page.goto(base + '?canvas=actual'); await page.waitForFunction(() => window.segnoDemo);
    const initial = await state();
    async function seed(mode = 'ready') {
      const expected = await page.evaluate(({initial, key, mode}) => {
        const current = structuredClone(initial.rig), names = Array.from({length:8}, (_, i) => 'Track ' + (i + 1));
        Object.assign(current, {recordedParts:{}, trackPlayback:{}, trackLayers:{}, trackLength:{},
          trackLabels:structuredClone(initial.trackLabels), inputLabels:structuredClone(initial.inputLabels), outputLabels:structuredClone(initial.outputLabels),
          liveMonitoring:structuredClone(initial.liveMonitoring), recordingInputs:structuredClone(initial.recordingInputs),
          expressionSettings:structuredClone(initial.expression.saved), audioLibrary:structuredClone(initial.audioLibrary.state)});
        for (const name of names) {
          current.recordedParts[name] = [];current.trackPlayback[name] = false;
          current.trackLayers[name] = {layers:[]};current.trackLength[name] = {audio:[], durationBeats:0, note:''};
        }
        current.mutedTracks = Array(8).fill(false);current.soloTracks = Array(8).fill(false);
        current.trackFade = {};current.midiMappings = [];current.loopSettings = {...structuredClone(initial.loopSettings), mode:'free', tempo:96};
        current.audioLibrary.prepared = ['inside-1'];current.audioLibrary.backing = structuredClone(current.audioLibrary.files[0]);current.audioLibrary.trackImports = {};
        current.expressionSettings.ports[0].type = 'expression';current.expressionSettings.ports[0].calibration = {heel:0, toe:1};
        const module = current.racks[0].modules.find(m => m.params.length);
        module.expressionId = 'module-only-in-a';
        const target = JSON.stringify(['fx', current.racks[0].id, module.expressionId, module.params[0][0]]);
        current.expressionSettings.ports[0].mappings = [{id:'expression-A', target, label:'Session parameter', detail:'Guitar', heel:.1, toe:.8}];
        current.pedalSettings.leds[0] = 'Blue';current.pedalSettings.custom[0] = {press:'Peel', hold:'None'};
        current.inputSetup = {trimDb:{Guitar:-3}, stereoPairs:[]};current.trackLabels['Track 1'] = 'Verse';
        const snapshot = SegnoSessionFieldOwnership.capture(current);
        current.racks[0].modules.find(m => m.params.length).expressionId = 'module-only-in-b';
        current.expressionSettings.ports[0].calibration = {heel:.2, toe:.75};
        current.expressionSettings.ports[0].mappings = [];
        current.pedalSettings.leds[0] = 'Amber';current.pedalSettings.custom[0] = {press:'Stop', hold:'None'};
        current.loopSettings.tempo = 120;current.inputSetup.trimDb.Guitar = 6;current.trackLabels['Track 1'] = 'Current part';
        current.inputLabels.Guitar = 'Current microphone';current.outputLabels['Main output'] = 'Current PA';
        current.audioDeviceConfig = {id:'stage', rate:96000, frames:128, measurement:null};current.tunerSettings = {reference:442};
        current.midiControlSettings = {enabled:false};current.syncSettings = {source:'internal', thru:true};
        current.saved = [{id:'current-only', name:'Current preset'}];
        current.audioLibrary.files.push({id:'current-audio', name:'New recording.wav', seconds:10, format:'WAV', folder:'Saved audio'});
        current.audioLibrary.nextId = 99;
        current.sessionLibrary = {nextId:3, current:{id:'session-1', name:'Current setup', updated:1}, folders:[],
          sessions:[{id:'session-2', name:'Earlier session', updated:1, snapshot}]};
        if (mode === 'type') current.expressionSettings.ports[0].type = 'dual';
        if (mode === 'midi') snapshot.midiMappings = [{id:'missing-controller', device:'keys', source:{kind:'cc', number:1, channel:1}, enabled:true, behavior:'continuous', controls:[{kind:'parameter', key:target, low:0, high:1}]}];
        if (mode === 'target') snapshot.expressionSettings.ports[0].mappings[0].target = JSON.stringify(['fx', 'missing-rack', 'missing-module', 'Mix']);
        if (mode === 'media') {snapshot.audioLibrary.prepared = ['missing-audio'];snapshot.audioLibrary.backing = {id:'missing-audio', name:'Lost backing.wav', seconds:222, format:'WAV'};}
        if (mode === 'held') {
          current.expressionSettings.ports[0].type = 'dual';
          Object.assign(current.expressionSettings.ports[0].switches[0], {hardware:'momentary', press:'none', hold:'none', change:'none',
            mappings:[{target:JSON.stringify(['mix', 'Guitar', 'level']), condition:'held', active:.8, inactive:.2, label:'Volume', detail:'Guitar'}]});
          current.expressionMix = {Guitar:{level:.2, pan:.5}};
        }
        localStorage.setItem(key, JSON.stringify(current));return {current, snapshot, target};
      }, {initial, key, mode});
      await page.goto(base + '?canvas=actual');await page.waitForFunction(() => window.segnoDemo);
      assert.equal(new URL(page.url()).searchParams.has('review'), false);
      return expected;
    }

    // Candidate-only FX identity must be found without borrowing outgoing targets.
    const expected = await seed();
    await page.evaluate(() => segnoDemo.pedalDown(0));
    assert.equal((await state()).held[0], true);
    await open();
    let loaded = await state();assert.equal(loaded.page, 'stage');
    assert.equal(loaded.rig.sessionLibrary.current.id, 'session-2');
    assert.deepEqual(loaded.rig.pedalSettings, expected.snapshot.pedalSettings);
    assert.deepEqual(loaded.rig.expressionSettings.ports[0].mappings, expected.snapshot.expressionSettings.ports[0].mappings);
    assert.equal(loaded.rig.expressionSettings.ports[0].type, 'expression');
    assert.deepEqual(loaded.rig.expressionSettings.ports[0].calibration, {heel:.2, toe:.75});
    assert.equal(loaded.rig.loopSettings.tempo, 96);assert.equal(loaded.rig.inputSetup.trimDb.Guitar, -3);
    assert.equal(loaded.inputLabels.Guitar, 'Current microphone');assert.equal(loaded.outputLabels['Main output'], 'Current PA');
    for (const field of ['audioDeviceConfig', 'tunerSettings', 'midiControlSettings', 'syncSettings', 'saved']) assert.deepEqual(loaded.rig[field], expected.current[field], field);
    assert.equal(loaded.rig.audioLibrary.nextId, 99);assert(loaded.rig.audioLibrary.files.some(f => f.id === 'current-audio'));
    assert(loaded.held.every(v => !v));assert(Object.values(loaded.captureState).every(v => v === 'idle'));
    assert(Object.values(loaded.trackPlayback).every(v => !v));
    await page.reload();assert.equal((await state()).rig.sessionLibrary.current.id, 'session-2');
    assert.deepEqual((await state()).rig.expressionSettings.ports[0].calibration, {heel:.2, toe:.75});

    // Guard and Cancel publish nothing. Retry reevaluates current connections.
    await seed('type');const before = await live(), storedBefore = await persisted();
    await open();assert.equal((await state()).sessions.dialog.type, 'dependencies');
    assert.match(await page.locator('.session-dialog').innerText(), /CTRL 1 needs expression; current setup is dual/);
    assert.deepEqual(await live(), before);assert.equal(await persisted(), storedBefore);
    await click('session:dependency-retry');assert.deepEqual(await live(), before);
    await page.keyboard.press('Escape');assert.equal((await state()).sessions.dialog, null);assert.deepEqual(await live(), before);
    await open();await click('session:dependency-cancel');assert.deepEqual(await live(), before);

    await seed();await page.evaluate(() => segnoDemo.expressionConnect(0, false));
    await open();assert.match(await page.locator('.session-dialog').innerText(), /CTRL 1 is not connected/);
    await page.evaluate(() => segnoDemo.expressionConnect(0, true));
    await page.evaluate(() => {segnoDemo.turn(1);segnoDemo.press();});
    assert.equal((await state()).rig.sessionLibrary.current.id, 'session-2');

    // A pedal recall owns STOP/MODE through a blocked retry; no track action leaks.
    const foot = id => page.evaluate(id => {segnoDemo.performanceDown(id, 'ownership-foot');segnoDemo.performanceUp('ownership-foot');}, id);
    for (const mode of ['type', 'disconnected']) {
      await seed(mode === 'type' ? 'type' : 'ready');await click('session:library');await click('stage');
      if (mode === 'disconnected') await page.evaluate(() => segnoDemo.expressionConnect(0, false));
      const footBefore = await live(), footStored = await persisted();
      await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));
      assert.equal((await state()).sessions.dialog.type, 'dependencies');
      assert.match(await button('session:dependency-retry').innerText(), /STOP/);
      assert.match(await button('session:dependency-cancel').innerText(), /MODE/);
      await foot(1);assert.equal((await state()).sessions.dialog.type, 'dependencies');
      assert.deepEqual(await live(), footBefore);assert.equal(await persisted(), footStored);
      await foot(3);assert.equal((await state()).page, 'stage');assert.equal((await state()).sessions.dialog, null);
      assert.deepEqual(await live(), footBefore);assert.equal(await persisted(), footStored);
    }
    await seed();await click('session:library');await click('stage');await page.evaluate(() => segnoDemo.expressionConnect(0, false));
    await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));await foot(1);
    await page.evaluate(() => segnoDemo.expressionConnect(0, true));await foot(1);
    assert.equal((await state()).page, 'stage');assert.equal((await state()).rig.sessionLibrary.current.id, 'session-2');

    await seed('midi');await open();assert.match(await page.locator('.session-dialog').innerText(), /MIDI controller “keys” is unavailable/);
    await page.evaluate(() => segnoDemo.midiConnect('keys', true));await click('session:dependency-retry');
    assert.equal((await state()).rig.midiMappings[0].device, 'keys');

    await seed('target');await open();assert.match(await page.locator('.session-dialog').innerText(), /Guitar · Session parameter is unavailable/);
    assert((await state()).sessions.dialog.issues.some(issue => issue.kind === 'control-target' && issue.id === JSON.stringify(['fx', 'missing-rack', 'missing-module', 'Mix'])));
    assert(await button('session:connection:0').isVisible());
    assert.equal((await state()).rig.sessionLibrary.current.id, 'session-1');
    await click('session:dependency-cancel');

    // The existing media-repair journey remains explicit and may precede control repair.
    await seed('media');await page.evaluate(() => segnoDemo.expressionConnect(0, false));await open();
    assert((await state()).sessions.recovery.draft);await click('recover:choose:missing-audio');await click('recover:file:inside-1');await click('recover:open');
    assert.equal((await state()).sessions.dialog.type, 'dependencies');
    assert(await button('session:dependency-cancel').isVisible());
    await page.evaluate(() => segnoDemo.expressionConnect(0, true));await click('session:dependency-retry');
    assert.equal((await state()).rig.audioLibrary.backing.id, 'inside-1');
    assert.equal((await state()).sessions.recovery.draft, null);

    // A real writer failure keeps the entire old rig and destination archive.
    await seed();await click('session:library');await click('session:row:session-2');
    const failedBefore = await live(), failedStored = await persisted();
    await page.evaluate(key => {window.ownershipWriter = Storage.prototype.setItem;Storage.prototype.setItem = function(k, v) {if (k === key) throw new DOMException('Full', 'QuotaExceededError');return window.ownershipWriter.call(this, k, v);};}, key);
    await click('session:load');assert.match((await state()).sessions.error, /Could not save/);
    assert.deepEqual(await live(), failedBefore);assert.equal(await persisted(), failedStored);
    await page.evaluate(() => {Storage.prototype.setItem = window.ownershipWriter;delete window.ownershipWriter;});
    await click('session:load');assert.equal((await state()).rig.sessionLibrary.current.id, 'session-2');

    // Metadata and New loop do not revalidate connections already absent in the live rig.
    await seed('held');await page.evaluate(() => segnoDemo.externalSwitchInput(0, 0, true));
    assert.equal((await state()).rig.expressionMix.Guitar.level, .8);
    await click('session:library');await click('session:new');await click('session:confirm-new');
    loaded = await state();
    const outgoing = loaded.rig.sessionLibrary.sessions.find(s => s.id === 'session-1');
    assert.equal(outgoing.snapshot.expressionMix.Guitar.level, .2);
    assert.equal(loaded.rig.expressionMix.Guitar.level, .2);
    assert.equal(loaded.expression.switches.contact[0][0], true, 'physical held input stays suppressed until its real release');
    await page.evaluate(() => segnoDemo.externalSwitchInput(0, 0, false));
    await page.evaluate(() => segnoDemo.expressionConnect(0, false));
    await page.evaluate(() => segnoDemo.dispatchMapping('session:save'));
    const previousId = (await state()).rig.sessionLibrary.current.id;
    await page.evaluate(() => segnoDemo.dispatchMapping('command:new-loop'));
    assert.notEqual((await state()).rig.sessionLibrary.current.id, previousId);

    fs.mkdirSync(output, {recursive:true});
    for (const scene of ['session-ownership', 'session-ownership-missing']) {
      await page.goto(base + '?review=' + scene + '&canvas=actual');await page.waitForFunction(() => window.segnoDemo);
      await page.evaluate(() => document.fonts.ready);
      const outside = await page.locator('.session-dialog button,.session-dialog h2').evaluateAll(elements => {
        const s = document.querySelector('#screen').getBoundingClientRect();
        return elements.filter(e => {const r = e.getBoundingClientRect();return r.top < s.top || r.bottom > s.bottom || r.left < s.left || r.right > s.right;}).map(e => e.textContent);
      });
      assert.deepEqual(outside, []);
      await page.locator('#screen').screenshot({path:path.join(output, kind + '-' + scene + '.png')});
    }
    assert.deepEqual(errors, []);
    console.log(kind + ': normal-URL musical recall, current physical/global ownership, dependency touch/encoder/STOP/MODE Retry/Cancel, candidate targets, media repair, failed publication, reload, held release and offline New loop passed.');
  } finally { await browser.close(); }
}
(async () => {for (const kind of ['chrome', 'firefox']) await verify(kind);})()
  .catch(error => {console.error(error);process.exitCode = 1;});
