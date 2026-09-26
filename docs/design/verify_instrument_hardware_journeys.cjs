'use strict';

const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');

// Runs the browser's saved controller editors and physical-contact entrypoints.
// These are simulated contacts; this does not establish real-device behavior.
(async () => {
  for (const kind of ['chrome', 'firefox']) {
    const browser = await (kind === 'chrome' ? chromium : firefox).launch({
      headless: true,
      ...(kind === 'chrome' ? {executablePath: process.env.ATLAS_CHROME} : {}),
    });
    try {
      const page = await browser.newPage({viewport: {width: 1920, height: 1200}});
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      const action = id => page.locator(`[data-action=${JSON.stringify(id)}]`);
      const snapshot = () => page.evaluate(() => instrumentDemo.snapshot());
      const openInstruments = async () => {
        await action('settings').click();
        await action('route:open').click();
        await action('route:instruments').click();
      };
      await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?simulate=1');
      await openInstruments();

      // Assign a held note using the shared built-in editor, then enter Custom
      // through the real MODE hold and drive its saved physical assignment.
      await action('controls').click();
      await action('shared:pedals').click();
      await action('setup:context:custom').click();
      await action('setup:select:4').click();
      await action('setup:edit:4:hold').click();
      await action('setup:choose:None').click();
      await action('setup:edit:4:press').click();
      await action('setup:action-group:instruments').click();
      await action('setup:choose:instrument:instrument-1:notes:held').click();
      await action('setup:save').click();
      await action('stage').click();
      await page.evaluate(() => segnoDemo.performanceDown(3, 'mode'));
      await page.waitForFunction(() => segnoDemo.snapshot().performance.view === 'custom');
      await page.evaluate(() => segnoDemo.performanceUp('mode'));
      await page.evaluate(() => segnoDemo.performanceDown(4, 'instrument-note'));
      await page.waitForFunction(() => instrumentDemo.snapshot().voices.length === 1);
      assert.equal((await snapshot()).voices[0].note, 48);
      assert.equal((await snapshot()).voices[0].id, 'instrument-1');
      await page.evaluate(() => segnoDemo.performanceUp('instrument-note'));
      assert.deepEqual((await snapshot()).voices, []);

      // Assign external sustain through its own editor and prove that the host
      // connects physical contacts to instrument MIDI notes and their release.
      await openInstruments();
      await action('controls').click();
      await action('shared:expression').click();
      await action('expr:type:single').click();
      await action('expr:switch:edit:press').click();
      await action('expr:switch:action-group:instruments').click();
      await action('expr:switch:choose:instrument:instrument-1:sustain:held').click();
      await action('expr:save').click();
      await page.evaluate(() => segnoDemo.externalSwitchInput(0, 0, true));
      assert.equal((await snapshot()).sustainActive, true);
      await page.evaluate(() => segnoDemo.midiReceive('usb', [144, 60, 100]));
      await page.waitForFunction(() => instrumentDemo.snapshot().voices.length === 1);
      await page.evaluate(() => segnoDemo.midiReceive('usb', [144, 60, 0]));
      assert.equal((await snapshot()).voices[0].sustained, true);
      await page.evaluate(() => segnoDemo.externalSwitchInput(0, 0, false));
      assert.deepEqual((await snapshot()).voices, []);
      assert.equal((await snapshot()).sustainActive, false);
      assert.deepEqual(errors, []);
      console.log(kind + ': shared built-in/external editors, saved physical assignments, instrument notes and sustain release passed');
    } finally {
      await browser.close();
    }
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
