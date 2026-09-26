// Author verification of saved-target repair. Normal storage URL; no native audio.
const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const base = process.env.FX_PROTOTYPE_URL || 'http://127.0.0.1:8768/fx-ux-prototype.html';
const key = 'segno-fx-factory-design-2026-09-06-channels';
const output = path.join(__dirname, 'session-target-previews');
const destinationAction = id => 'session:target-destination:' + encodeURIComponent(id);
const targetAction = id => 'session:target-choice:' + encodeURIComponent(id);

async function verify(kind) {
  const browser = await (kind === 'chrome' ? chromium : firefox).launch({headless:true,
    ...(kind === 'chrome' ? {executablePath:process.env.ATLAS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'} : {})});
  try {
    const page = await browser.newPage({viewport:{width:1920, height:1080}}), errors = [];
    page.setDefaultTimeout(6000);page.on('pageerror', e => errors.push(e.message));
    const state = () => page.evaluate(() => segnoDemo.snapshot());
    const dialog = async () => (await state()).sessions.dialog;
    const button = id => page.locator('[data-action=' + JSON.stringify(id) + ']');
    const click = id => button(id).click();
    const stored = () => page.evaluate(key => localStorage.getItem(key), key);
    const live = async () => {const s = await state();return {rig:s.rig, parts:s.recordedParts, playback:s.trackPlayback, capture:s.captureState, held:s.held, bank:s.bank};};
    const unchanged = async (before, saved) => {assert.deepEqual(await live(), before);assert.equal(await stored(), saved);};
    const open = async () => {await click('session:library');await click('session:row:session-2');await click('session:load');};
    const foot = id => page.evaluate(id => {segnoDemo.performanceDown(id, 'target-foot');segnoDemo.performanceUp('target-foot');}, id);
    const encoder = async id => {
      const count = await page.locator('.session-dialog button:not(:disabled)').count();
      await page.evaluate(count => {for (let n = 0; n <= count; n++) segnoDemo.turn(-1);}, count);
      for (let n = 0; n <= count && (await state()).focusId !== id; n++) await page.evaluate(() => segnoDemo.turn(1));
      assert.equal((await state()).focusId, id, 'encoder reaches ' + id);await page.evaluate(() => segnoDemo.press());
    };
    const footChoice = async id => {
      for (let n = 0; n < 30; n++) {
        const mark = button(id).locator('.session-foot-label');
        if (await mark.count()) {const number = Number(await mark.innerText());assert(number >= 1 && number <= 4);await foot(number + 3);return;}
        assert(await button('session:connection-page').isVisible(), 'BANK can reach ' + id);await foot(9);
      }
      assert.fail('foot choice did not appear: ' + id);
    };
    const shot = async name => {
      await page.evaluate(() => document.fonts.ready);
      const outside = await page.locator('.session-dialog h2,.session-dialog .actions button').evaluateAll(elements => {
        const s = document.querySelector('#screen').getBoundingClientRect();
        return elements.filter(e => {const r = e.getBoundingClientRect();return r.top < s.top || r.bottom > s.bottom || r.left < s.left || r.right > s.right;}).map(e => e.textContent);
      });
      assert.deepEqual(outside, []);
      const overflow = await page.locator('.session-target-options .session-connection-option').evaluateAll(buttons => buttons.flatMap(button => {
        const b = button.getBoundingClientRect();
        return [...button.querySelectorAll('span,small')].filter(child => {const c = child.getBoundingClientRect();return c.top < b.top - 1 || c.bottom > b.bottom + 1 || c.left < b.left - 1 || c.right > b.right + 1;}).map(child => child.textContent);
      }));
      assert.deepEqual(overflow, [], 'control label and detail fit within their own button');fs.mkdirSync(output, {recursive:true});
      await page.locator('#screen').screenshot({path:path.join(output, kind + '-session-target-' + name + '.png')});
    };
    await page.goto(base + '?canvas=actual');await page.waitForFunction(() => window.segnoDemo);
    const initial = await state();
    async function seed(mode = 'module') {
      const expected = await page.evaluate(({initial, key, mode}) => {
        const rig = structuredClone(initial.rig), names = Array.from({length:8}, (_, i) => 'Track ' + (i + 1));
        Object.assign(rig, {recordedParts:{}, trackPlayback:{}, trackLayers:{}, trackLength:{},
          trackLabels:structuredClone(initial.trackLabels), liveMonitoring:structuredClone(initial.liveMonitoring), recordingInputs:structuredClone(initial.recordingInputs),
          inputLabels:structuredClone(initial.inputLabels), outputLabels:structuredClone(initial.outputLabels),
          expressionSettings:structuredClone(initial.expression.saved), audioLibrary:structuredClone(initial.audioLibrary.state)});
        delete rig.performanceRecording;
        for (const name of names) {rig.recordedParts[name] = [];rig.trackPlayback[name] = false;rig.trackLayers[name] = {layers:[]};rig.trackLength[name] = {audio:[], durationBeats:0, note:''};}
        rig.mutedTracks = Array(8).fill(false);rig.soloTracks = Array(8).fill(false);rig.trackFade = {};
        rig.loopSettings = {...structuredClone(initial.loopSettings), mode:'free', tempo:96};
        rig.audioLibrary.prepared = [];rig.audioLibrary.backing = null;rig.audioLibrary.trackImports = {};
        for (const port of rig.expressionSettings.ports) {port.mappings = [];for (const s of port.switches) Object.assign(s, {hardware:'momentary', press:'none', hold:'none', change:'none', mappings:[]});}
        const ports = rig.expressionSettings.ports;
        ports[0].type = 'expression';ports[0].calibration = {heel:.2, toe:.75};
        ports[1].type = 'dual';ports[1].calibration = null;
        const rack = rig.racks.find(r => r.modules.some(m => SegnoFxParameters.powerParameter(m)));
        const module = rack.modules.find(m => SegnoFxParameters.powerParameter(m)), power = SegnoFxParameters.powerParameter(module);
        module.expressionId = 'incoming-only-control';
        SegnoFxParameters.targets(rig);
        rig.trackLabels['Track 1'] = 'Saved verse';
        const replacement = JSON.stringify(['fx', rack.id, module.expressionId, power[0]]);
        const missing = JSON.stringify(['fx', rack.id, mode === 'parameter' ? module.expressionId : 'removed-processor', mode === 'parameter' ? 'Removed parameter' : power[0]]);
        ports[0].mappings = [{id:'expression-old', target:missing, label:'Old tone', detail:'Guitar', heel:.2, toe:.8}];
        ports[1].switches[0].mappings = [{id:'external-old', target:missing, label:'Old tone', detail:'Guitar', condition:'held', active:.7, inactive:.1}];
        ports[1].switches[1].mappings = [{id:'external-second', target:missing, label:'Old tone', detail:'Guitar', condition:'held', active:.9, inactive:.3}];
        rig.midiMappings = [{id:'midi-old', device:'usb', enabled:true, behavior:'continuous', source:{kind:'cc', channel:2, number:11},
          controls:[{kind:'parameter', key:missing, label:'Old tone', detail:'Guitar', low:.1, high:.9}]}];
        rig.midiMappings.push({...structuredClone(rig.midiMappings[0]), id:'midi-second', source:{kind:'cc', channel:3, number:12}});
        if (mode === 'duplicate') ports[0].mappings.push({id:'already-assigned', target:replacement, label:'Already assigned', detail:'Guitar', heel:0, toe:1});
        if (mode === 'compose') {ports[1].type = 'expression';ports[1].calibration = {heel:.12, toe:.89};ports[1].switches.forEach(s => s.mappings = []);}
        const snapshot = SegnoSessionFieldOwnership.capture(rig);
        if (mode === 'compose') {snapshot.audioLibrary.prepared = ['missing-audio'];snapshot.audioLibrary.backing = {id:'missing-audio', name:'Lost backing.wav', seconds:222, format:'WAV'};}
        module.expressionId = 'outgoing-only-control';rig.trackLabels['Track 1'] = 'Current part';
        ports[0].mappings = [];ports[1].switches.forEach(s => s.mappings = []);rig.midiMappings = [];
        if (mode === 'compose') ports[0].type = 'dual';
        rig.loopSettings.tempo = 120;rig.midiControlSettings = {enabled:false};rig.syncSettings = {source:'internal', thru:true};
        rig.inputLabels.Guitar = 'Stage vocal';rig.audioDeviceConfig = {id:'stage', rate:96000, frames:128, measurement:null};
        rig.recordedParts['Track 1'] = ['Guitar'];rig.trackLength['Track 1'] = {audio:[], durationBeats:8, note:'Current loop'};
        rig.trackLayers['Track 1'] = {layers:[{id:'current-take', beats:8, gain:1, regions:[{offsetBeats:0, beats:8}]}]};
        rig.sessionLibrary = {nextId:3, current:{id:'session-1', name:'Current loop', updated:1}, folders:[], sessions:[{id:'session-2', name:'Evening set', updated:1, snapshot}]};
        localStorage.setItem(key, JSON.stringify(rig));
        return {current:rig, snapshot, missing, replacement, destination:rack.source, moduleName:module.name, powerName:power[0], mode};
      }, {initial, key, mode});
      await page.goto(base + '?canvas=actual');await page.waitForFunction(() => window.segnoDemo);
      assert.equal(new URL(page.url()).searchParams.has('review'), false);
      await page.evaluate(() => segnoDemo.expressionConnect(1, true));return expected;
    }
    const startTarget = async expected => {await click('session:connection:0');assert.deepEqual((await dialog()).connection, {kind:'target', id:expected.missing});};
    const reviewTarget = async expected => {await startTarget(expected);await click(destinationAction(expected.destination));await click(targetAction(expected.replacement));};
    const assertRepair = (candidate, expected, expressionPort = 0) => {
      const expression = candidate.expressionSettings.ports[expressionPort].mappings.find(m => m.id === 'expression-old');
      assert.equal(expression.target, expected.replacement);assert.deepEqual([expression.heel, expression.toe], [0,1]);
      if (expected.mode !== 'compose') {
        for (let i = 0; i < 2; i++) {
          const external = candidate.expressionSettings.ports[1].switches[i].mappings[0];
          assert.equal(external.id, i ? 'external-second' : 'external-old');assert.equal(external.target, expected.replacement);
          assert.equal(external.condition, 'held');assert.deepEqual([external.active, external.inactive], [1,0]);
        }
      }
      for (let i = 0; i < 2; i++) {
        const midi = candidate.midiMappings[i];assert.equal(midi.id, i ? 'midi-second' : 'midi-old');assert.equal(midi.device, 'usb');
        assert.deepEqual(midi.source, {kind:'cc', channel:i ? 3 : 2, number:i ? 12 : 11});assert.equal(midi.behavior, 'continuous');assert.equal(midi.enabled, true);
        assert.equal(midi.controls[0].key, expected.replacement);assert.deepEqual([midi.controls[0].low, midi.controls[0].high], [0,1]);
      }
      assert.deepEqual(candidate.racks, expected.snapshot.racks, 'assignment repair never writes the replacement parameter itself');
    };
    const assertLoaded = (s, expected, expressionPort = 0) => {
      assertRepair(s.rig, expected, expressionPort);assert.equal(s.rig.sessionLibrary.current.id, 'session-2');
      for (const field of ['audioDeviceConfig','midiControlSettings','syncSettings']) assert.deepEqual(s.rig[field], expected.current[field]);
      assert.equal(s.inputLabels.Guitar, 'Stage vocal');
      for (let i = 0; i < 2; i++) {assert.equal(s.rig.expressionSettings.ports[i].type, expected.current.expressionSettings.ports[i].type);assert.deepEqual(s.rig.expressionSettings.ports[i].calibration, expected.current.expressionSettings.ports[i].calibration);}
      assert(Object.values(s.trackPlayback).every(v => !v));assert(Object.values(s.captureState).every(v => v === 'idle'));
      assert.deepEqual(s.rig.sessionLibrary.sessions.find(s => s.id === 'session-1').snapshot.trackLayers['Track 1'], expected.current.trackLayers['Track 1']);
    };

    // One missing exact key is reviewed across all three source families; choice is not a live write.
    let expected = await seed(), before = await live(), saved = await stored();await open();
    assert.equal((await dialog()).issues.filter(i => i.kind === 'control-target').length, 1);await shot('missing');
    assert(!before.rig.racks.some(r => r.modules.some(m => m.expressionId === 'incoming-only-control')));
    await startTarget(expected);await shot('destinations');
    assert.match(await button(destinationAction('Track 1')).innerText(), /Saved verse/);
    assert.doesNotMatch(await button(destinationAction('Track 1')).innerText(), /Current part/);
    await click(destinationAction(expected.destination));await shot('controls');
    const outgoing = JSON.stringify(['fx', JSON.parse(expected.replacement)[1], 'outgoing-only-control', expected.powerName]);
    assert.equal(await button(targetAction(outgoing)).count(), 0, 'live-only processor is absent from the incoming target catalogue');
    assert(await button(targetAction(expected.replacement)).isEnabled());await click(targetAction(expected.replacement));
    assert.equal((await dialog()).targetChoice, expected.replacement);assert.equal((await dialog()).repaired, null);
    let formatted = await page.locator('.session-dialog').innerText();
    assert(await button('session:target-page:next').isEnabled());await click('session:target-page:next');
    assert.equal((await dialog()).targetPage, 1);formatted += await page.locator('.session-dialog').innerText();
    await click('session:target-page:previous');assert.equal((await dialog()).targetPage, 0);
    assert.match(formatted, /Heel/);assert.match(formatted, /Toe/);assert.match(formatted, /Released/);assert.match(formatted, /Held/);
    assert.match(formatted, /From/);assert.match(formatted, /To/);assert.match(formatted, /Off/);assert.match(formatted, /On/);
    await unchanged(before, saved);await shot('review');await click('session:target-use');
    assertRepair((await dialog()).repaired, expected);await unchanged(before, saved);await shot('ready');
    await click('session:connection-reset');assert.deepEqual((await dialog()).repaired, expected.snapshot);await unchanged(before, saved);
    await reviewTarget(expected);await click('session:dependency-cancel');assert.equal(await dialog(), null);await unchanged(before, saved);

    // Missing parameter on an existing processor and a removed processor follow the same exact-ID repair.
    for (const mode of ['module','parameter']) {
      expected = await seed(mode);before = await live();saved = await stored();await open();await reviewTarget(expected);await click('session:target-use');
      const pending = structuredClone((await dialog()).repaired);
      await page.evaluate(key => {window.targetWriter = Storage.prototype.setItem;Storage.prototype.setItem = function(k, v) {if (k === key) throw new DOMException('Full', 'QuotaExceededError');return window.targetWriter.call(this, k, v);};}, key);
      try {await click('session:dependency-retry');assert.match((await state()).sessions.error, /Could not save/);assert.deepEqual((await dialog()).repaired, pending);await unchanged(before, saved);}
      finally {await page.evaluate(() => {Storage.prototype.setItem = window.targetWriter;delete window.targetWriter;});}
      await click('session:dependency-retry');assertLoaded(await state(), expected);await page.reload();assertLoaded(await state(), expected);
    }

    // A same-source duplicate disables that target instead of merging assignments.
    expected = await seed('duplicate');before = await live();saved = await stored();await open();await startTarget(expected);await click(destinationAction(expected.destination));
    assert(await button(targetAction(expected.replacement)).isDisabled());assert.match(await button(targetAction(expected.replacement)).innerText(), /already|duplicate/i);
    await click('session:dependency-cancel');await unchanged(before, saved);

    // Earlier backing-file, CTRL and target repairs compose in one pending snapshot and reset together.
    expected = await seed('compose');before = await live();saved = await stored();await open();
    assert((await state()).sessions.recovery.draft);
    await click('recover:choose:missing-audio');await click('recover:file:inside-1');await click('recover:open');
    const mediaBase = structuredClone((await dialog()).base);assert.equal(mediaBase.audioLibrary.backing.id, 'inside-1');
    await unchanged(before, saved);
    await click('session:connection:0');await click('session:replacement:1');assert.equal((await dialog()).changes.length, 1);
    await reviewTarget(expected);await click('session:target-use');assert.equal((await dialog()).changes.length, 2);
    assertRepair((await dialog()).repaired, expected, 1);await unchanged(before, saved);
    await click('session:connection-reset');assert.deepEqual((await dialog()).repaired, mediaBase);await unchanged(before, saved);
    await click('session:connection:0');await click('session:replacement:1');await reviewTarget(expected);await click('session:target-use');
    const composed = structuredClone((await dialog()).repaired);assert.equal(composed.audioLibrary.backing.id, 'inside-1');
    await page.evaluate(key => {window.targetWriter = Storage.prototype.setItem;Storage.prototype.setItem = function(k, v) {if (k === key) throw new DOMException('Full', 'QuotaExceededError');return window.targetWriter.call(this, k, v);};}, key);
    try {await click('session:dependency-retry');assert.match((await state()).sessions.error, /Could not save/);assert.deepEqual((await dialog()).repaired, composed);await unchanged(before, saved);}
    finally {await page.evaluate(() => {Storage.prototype.setItem = window.targetWriter;delete window.targetWriter;});}
    await click('session:dependency-retry');assertLoaded(await state(), expected, 1);
    assert.equal((await state()).rig.audioLibrary.backing.id, 'inside-1');assert.equal((await state()).sessions.recovery.draft, null);
    await page.reload();assertLoaded(await state(), expected, 1);assert.equal((await state()).rig.audioLibrary.backing.id, 'inside-1');

    // Full encoder and foot journeys enter the same destination/control/review states.
    expected = await seed();before = await live();saved = await stored();await open();
    for (const id of ['session:connection:0', destinationAction(expected.destination), targetAction(expected.replacement), 'session:target-page:next', 'session:target-page:previous', 'session:target-use']) await encoder(id);
    await unchanged(before, saved);await encoder('session:dependency-retry');assertLoaded(await state(), expected);
    expected = await seed();await click('session:library');await click('stage');before = await live();saved = await stored();
    await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));
    for (const id of ['session:connection:0', destinationAction(expected.destination), targetAction(expected.replacement)]) await footChoice(id);
    assert.equal((await dialog()).targetChoice, expected.replacement);await foot(5);assert.equal((await dialog()).targetPage, 1);
    assert.match(await page.locator('.session-dialog').innerText(), /CC 12/);await foot(4);assert.equal((await dialog()).targetPage, 0);
    await foot(1);assertRepair((await dialog()).repaired, expected);await unchanged(before, saved);
    await foot(1);assertLoaded(await state(), expected);assert.equal((await state()).page, 'stage');

    // A previous Use contact cannot survive Back/reentry, another target choice, or Cancel/reopen.
    for (const retire of ['back-reenter','another-target','cancel-reopen','review-page']) {
      expected = await seed();await click('session:library');await click('stage');before = await live();saved = await stored();
      await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));await reviewTarget(expected);
      await page.evaluate(() => segnoDemo.performanceDown(1, 'held-use'));
      if (retire === 'review-page') {await foot(5);assert.equal((await dialog()).targetPage, 1);}
      else if (retire === 'cancel-reopen') {await foot(3);await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));await reviewTarget(expected);}
      else {
        await click('session:connection-back');
        if (retire === 'another-target') {
          const other = await page.locator('[data-action^="session:target-choice:"]:not(:disabled)').evaluateAll((els, excluded) => els.map(e => e.dataset.action).find(id => id !== excluded), targetAction(expected.replacement));
          assert(other, 'another incoming target is available');await click(other);
        } else await click(targetAction(expected.replacement));
      }
      const pending = structuredClone(await dialog());await page.evaluate(() => segnoDemo.performanceUp('held-use'));
      assert.deepEqual(await dialog(), pending);assert.equal((await dialog()).repaired, null);await unchanged(before, saved);await foot(3);
      assert.equal((await state()).page, 'stage');await unchanged(before, saved);
    }
    // Held destination/control contacts are retired even when Back returns to the same page.
    for (const level of ['destination','control','control-page']) {
      expected = await seed();await click('session:library');await click('stage');before = await live();saved = await stored();
      await page.evaluate(() => segnoDemo.dispatchMapping('session:next'));await startTarget(expected);
      if (level !== 'destination') await click(destinationAction(expected.destination));
      const action = level === 'destination' ? destinationAction(expected.destination) : targetAction(expected.replacement);
      const number = Number(await button(action).locator('.session-foot-label').innerText());assert(number >= 1 && number <= 4);
      await page.evaluate(id => segnoDemo.performanceDown(id, 'held-picker'), number + 3);
      if (level === 'control-page') await foot(9);
      else {
        await click('session:connection-back');
        if (level === 'destination') await startTarget(expected);else await click(destinationAction(expected.destination));
      }
      const pending = structuredClone(await dialog());await page.evaluate(() => segnoDemo.performanceUp('held-picker'));
      assert.deepEqual(await dialog(), pending);assert.equal((await dialog()).targetChoice, null);await unchanged(before, saved);await foot(3);
    }
    assert.deepEqual(errors, []);
    console.log(kind + ': saved-target exact repair, typed ranges, staged cancel/reset, duplicate refusal, storage failure/retry/reload, connection composition, encoder/foot and stale contacts passed; five screenshots captured.');
  } finally {await browser.close();}
}
(async () => {for (const kind of ['chrome','firefox']) await verify(kind);})().catch(error => {console.error(error);process.exitCode = 1;});
