// Author-only browser proof for the silent D2 prototype; no audio/device claim.
const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const base = process.env.FX_PROTOTYPE_URL || 'http://127.0.0.1:8768/fx-ux-prototype.html';
const previews = path.join(__dirname, 'pedal-closure-previews');
const content = s => ({parts: s.recordedParts, length: s.rig.trackLength, layers: s.rig.trackLayers, racks: s.rig.racks, labels: s.trackLabels, pedals: s.rig.pedalSettings});

(async () => {
  fs.mkdirSync(previews, {recursive: true});
  for (const [kind, type] of [['chrome', chromium], ['firefox', firefox]]) {
    const browser = await type.launch({headless: true, ...(kind === 'chrome' ? {executablePath: process.env.ATLAS_CHROME} : {})});
    try {
      const p = await browser.newPage({viewport: {width: 1920, height: 1080}}), errors = [];
      p.setDefaultTimeout(8000); p.on('pageerror', error => errors.push(error.message));
      await p.clock.install();
      const open = async scene => {await p.goto(base + (scene ? '?review=' + scene + '&canvas=actual' : '?canvas=actual')); await p.waitForFunction(() => window.segnoDemo);};
      const snap = () => p.evaluate(() => segnoDemo.snapshot());
      const click = id => p.locator('[data-action=' + JSON.stringify(id) + ']').click();
      const dispatch = key => p.evaluate(key => segnoDemo.dispatchMapping(key, 'browser-assignment'), key);
      const foot = async (id, hold = false) => {
        await p.evaluate(id => segnoDemo.performanceDown(id, 'browser-foot'), id);
        if (hold) await p.clock.runFor(850);
        await p.evaluate(() => segnoDemo.performanceUp('browser-foot'));
      };
      const screenshot = async name => {
        await p.evaluate(() => document.fonts.ready);
        await p.clock.runFor(100);
        await p.locator('#screen').screenshot({path: path.join(previews, kind + '-' + name + '.png')});
        const outside = await p.locator('#screen').evaluate(screen => {
          const bounds = screen.getBoundingClientRect();
          return [...screen.querySelectorAll('button,.dialog,.transpose-overview,.performance-caption')].filter(element => {
            const rect = element.getBoundingClientRect();
            return rect.left < bounds.left - 1 || rect.right > bounds.right + 1 || rect.bottom > bounds.bottom + 1 || rect.top < bounds.top - 1 || element.scrollWidth > element.clientWidth + 2;
          }).map(element => element.textContent);
        });
        assert.deepEqual(outside, [], name + ' stays within the display');
      };

      await open('performance-transpose'); await foot(5);
      let before = await snap(); const pitches = before.performance.transpose.pitches;
      await foot(0, true); let after = await snap();
      assert.equal(after.performance.transpose.enabled, false);
      assert.deepEqual(after.performance.transpose.pitches, pitches);
      assert.deepEqual(after.performance.transpose.effectivePitches, Array(8).fill(0));
      assert.deepEqual(after.rig.lastTrackPedalEvent, before.rig.lastTrackPedalEvent, 'hold consumes Record / Play');
      await screenshot('transpose-bypassed');
      await foot(9); await foot(4); await foot(0, true);
      after = await snap(); assert.equal(after.bank, 1); assert.equal(after.performance.transpose.enabled, true);
      assert.deepEqual(after.performance.transpose.pitches, pitches);
      assert.deepEqual(after.performance.transpose.effectivePitches, pitches);
      await dispatch('command:transpose-bypass'); await foot(8, true);
      after = await snap(); assert.equal(after.performance.transpose.enabled, false);
      for (const i of [0, 1, 4]) assert.equal(after.performance.transpose.pitches[i], 0);
      await foot(3); assert.equal((await snap()).performance.view, 'tracks');
      await dispatch('command:transpose-bypass'); assert.equal((await snap()).performance.view, 'tracks');
      await dispatch('mode:transpose'); before = await snap();
      await p.evaluate(() => segnoDemo.performanceDown(0, 'cancelled-bypass')); await p.clock.runFor(400);
      await p.evaluate(() => segnoDemo.performanceUp('cancelled-bypass', true)); await p.clock.runFor(500);
      assert.equal((await snap()).performance.transpose.enabled, before.performance.transpose.enabled);

      await open('pedal-custom'); before = await snap();
      await click('setup:clear-custom'); await screenshot('clear-custom-confirm');
      await p.keyboard.press('Escape'); assert.equal((await snap()).pedalSetup.clearPending, false);
      assert.deepEqual((await snap()).pedalSetup.draft, before.pedalSetup.draft);
      await click('setup:clear-custom');
      await p.locator('[data-action="setup:clear-confirm"]').focus(); await p.evaluate(() => segnoDemo.press());
      after = await snap(); assert.equal(after.pedalSetup.clearPending, false); assert.equal(after.pedalSetup.canRestore, true);
      assert.equal(after.pedalSetup.draft.custom[4].press, 'None');
      assert.ok(after.pedalSetup.draft.bankB.every(pair => pair.press === 'None' && pair.hold === 'None'));
      assert.deepEqual(after.rig.pedalSettings, before.rig.pedalSettings);
      await click('setup:save'); const cleared = (await snap()).rig.pedalSettings;
      assert.deepEqual(cleared.custom[3], before.rig.pedalSettings.custom[3]);
      assert.deepEqual(cleared.custom[9], before.rig.pedalSettings.custom[9]);
      assert.deepEqual(cleared.leds, before.rig.pedalSettings.leds);
      await screenshot('clear-custom-saved');
      await click('setup:restore-custom'); await click('setup:save');
      assert.deepEqual((await snap()).rig.pedalSettings, before.rig.pedalSettings);

      // Assign each mode through the real Custom chooser, then trigger by foot.
      for (const [mode, name] of [['multi', 'Multi'], ['sync', 'Sync'], ['song', 'Song'], ['band', 'Band'], ['free', 'Free']]) {
        await open('loop-mode-playing');
        if (mode === 'free') {await click('loop:mode:multi'); await click('loop:mode-confirm:multi'); await p.evaluate(() => segnoDemo.setPlayback('Track 1', true));}
        await click('stage'); await click('settings'); await click('pedal-setup'); await click('setup:context:custom');
        await click('setup:edit:4:press'); await click('setup:action-group:loop-modes'); await click('setup:choose:' + name + ' loop mode'); await click('setup:save');
        await click('stage'); await dispatch('mode:custom'); before = await snap();
        await foot(4); after = await snap();
        assert.equal(after.modal?.mode, mode); assert.equal(after.loopSettings.mode, before.loopSettings.mode);
        assert.deepEqual(after.trackPlayback, before.trackPlayback);
        assert.deepEqual(content(after), content(before));
        if (mode === 'song') await screenshot('loop-mode-foot-confirm');
        await foot(3); assert.equal((await snap()).modal, null); assert.deepEqual((await snap()).trackPlayback, before.trackPlayback);
        await foot(4); await foot(1); after = await snap();
        assert.equal(after.loopSettings.mode, mode); assert.equal(after.modal, null);
        assert.equal(after.performance.view, 'custom'); assert.equal(after.bank, before.bank); assert.equal(after.soundTrack, before.soundTrack);
        assert.ok(Object.values(after.trackPlayback).every(playing => !playing)); assert.deepEqual(content(after), content(before));
      }

      await open('loop-mode-incompatible'); await click('stage'); before = await snap();
      for (const mode of ['multi', 'sync', 'band']) {await dispatch('loop-mode:' + mode); after = await snap(); assert.equal(after.loopSettings.mode, 'free'); assert.equal(after.modal, null); assert.deepEqual(content(after), content(before));}
      for (const scene of ['loop-mode-capture', 'loop-mode-queued']) {await open(scene); await click('stage'); before = await snap(); await dispatch('loop-mode:song'); after = await snap(); assert.equal(after.loopSettings.mode, 'free'); assert.equal(after.modal, null); assert.deepEqual(content(after), content(before));}
      await open('loop-mode-playing'); await click('stage'); await dispatch('loop-mode:song');
      await p.evaluate(() => segnoDemo.setCapture('Track 1', 'overdubbing')); before = await snap(); await foot(1);
      after = await snap(); assert.equal(after.loopSettings.mode, 'free'); assert.deepEqual(after.trackPlayback, before.trackPlayback);
      await foot(3); assert.equal((await snap()).modal, null);

      // Persist a real fixture, then test reload and storage failure on normal URL.
      await open('performance-transpose'); before = await snap();
      await p.evaluate(s => {localStorage.clear(); localStorage.setItem('segno-fx-factory-design-2026-09-06-channels', JSON.stringify({...s.rig, recordedParts: s.recordedParts, loopSettings: s.loopSettings, trackPlayback: s.trackPlayback}));}, before);
      await open(); await dispatch('command:transpose-bypass'); await p.reload(); await p.waitForFunction(() => window.segnoDemo);
      assert.equal((await snap()).performance.transpose.enabled, false);
      assert.deepEqual((await snap()).performance.transpose.pitches, before.performance.transpose.pitches);
      await p.evaluate(() => {window.originalStorageWrite = Storage.prototype.setItem; Storage.prototype.setItem = function () {throw Error('Test storage unavailable');};});
      await dispatch('command:transpose-bypass'); assert.equal((await snap()).performance.transpose.enabled, false);
      await click('settings'); await click('pedal-setup'); await click('setup:context:custom'); before = await snap();
      await click('setup:clear-custom'); await click('setup:clear-confirm'); await click('setup:save'); after = await snap();
      assert.deepEqual(after.rig.pedalSettings, before.rig.pedalSettings); assert.match(after.pedalSetup.saveError, /Could not save/);
      await p.evaluate(() => Storage.prototype.setItem = window.originalStorageWrite); await click('setup:save');
      await p.reload(); await p.waitForFunction(() => window.segnoDemo); assert.equal((await snap()).rig.pedalSettings.custom[4].press, 'None');
      assert.deepEqual(errors, []);
      fs.writeFileSync(path.join(previews, kind + '-verification.json'), JSON.stringify({browser: kind, checks: ['global bypass and pitch retention', 'hold consumption and cancelled gesture', 'bank/reset independence', 'clear both banks, encoder confirmation, Escape, Save and Restore', 'all five custom mode assignments with foot cancel/confirm', 'incompatible/capture/queued refusal', 'capture recheck at foot confirmation', 'reload and storage-failure rollback', '1920 × 1080 dialog and heading bounds'], errors}, null, 2) + '\n');
      console.log(kind + ': D2 pedal closure browser journeys passed.');
    } finally {await browser.close();}
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
