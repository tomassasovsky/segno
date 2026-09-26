const { chromium, firefox } = require('playwright');
const assert = require('node:assert/strict');
const path = require('node:path');

(async () => {
  for (const kind of ['chrome', 'firefox']) {
    const browser = await (kind === 'chrome' ? chromium : firefox).launch({
      headless: true,
      ...(kind === 'chrome' ? { executablePath: process.env.ATLAS_CHROME } : {}),
    });
    try {
      const page = await browser.newPage({ viewport: { width: 1920, height: 1200 } });
      const errors = [];
      page.on('pageerror', e => errors.push(e.message));
      const a = id => page.locator(`[data-action=${JSON.stringify(id)}]`);
      const snap = () => page.evaluate(() => instrumentDemo.snapshot());
      const cc = (value, extra = {}) => page.evaluate(event => instrumentDemo.receiveMidi(event), {
        device: 'usb', channel: 1, kind: 'cc', number: 64, value, ...extra,
      });
      const noteDown = async key => {
        await page.keyboard.down(key);
        await page.waitForFunction(() => instrumentDemo.snapshot().heldNotes.length > 0);
      };
      await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html'); await a('settings').click(); await a('route:open').click(); await a('route:instruments').click();
      await cc(63);
      assert.equal((await snap()).sustainActive, false);
      await cc(64, { channel: 2 });
      await cc(127, { device: 'Other keyboard' });
      assert.equal((await snap()).sustainActive, false, 'unassigned sources do not sustain');
      await cc(64);
      await noteDown('a');
      await page.keyboard.up('a');
      assert.deepEqual((await snap()).heldNotes, []);
      assert.deepEqual((await snap()).sustainedNotes, [48]);
      assert.equal(await page.locator('#sustain-indicator').isVisible(), true);
      assert.equal(await page.locator('[data-note="48"]').evaluate(el => el.classList.contains('sustained')), true);
      await page.screenshot({ path: path.join(__dirname, 'virtual-instrument-previews', `${kind}-sustain.png`) });

      // Pedal release ends sustained voices without interrupting physically held keys.
      await noteDown('s');
      await cc(0);
      assert.deepEqual((await snap()).sustainedNotes, []);
      assert.deepEqual((await snap()).heldNotes, [50]);
      await page.keyboard.up('s');
      assert.deepEqual((await snap()).activeNotes, []);

      // Repeated strikes under sustain remain independent voices and all release.
      await cc(127);
      for (let i = 0; i < 2; i++) { await noteDown('a'); await page.keyboard.up('a'); }
      assert.deepEqual((await snap()).sustainedNotes, [48, 48]);
      await cc(0);
      assert.deepEqual((await snap()).activeNotes, []);

      await page.locator('#instrument-sustain').focus();
      await page.keyboard.down(' ');
      await noteDown('a'); await page.keyboard.up('a');
      assert.equal((await snap()).sustainActive, true, 'releasing a note does not release the simulated pedal');
      assert.deepEqual((await snap()).sustainedNotes, [48]);
      await page.keyboard.up(' ');
      assert.deepEqual((await snap()).activeNotes, []);

      // Shared sustain contributions release independently, including latched state.
      await page.evaluate(()=>window.releaseSustain=segnoDemo.dispatchMapping('instrument:instrument-1:sustain:held','external:0:0'));
      await noteDown('a');await page.keyboard.up('a');await cc(127);
      await page.evaluate(()=>window.releaseSustain());assert.equal((await snap()).sustainActive,true);
      await cc(0);assert.deepEqual((await snap()).activeNotes,[]);
      await page.evaluate(()=>segnoDemo.dispatchMapping('instrument:instrument-1:sustain:latch','external:0:0'));
      await noteDown('a');await page.keyboard.up('a');
      await page.evaluate(()=>segnoDemo.dispatchMapping('instrument:instrument-1:sustain:latch','external:0:0'));
      assert.equal((await snap()).sustainActive,false);assert.deepEqual((await snap()).activeNotes,[]);
      await page.evaluate(()=>segnoDemo.dispatchMapping('instrument:instrument-1:sustain:latch','external:0:0'));
      await page.reload();await a('settings').click();await a('route:open').click();await a('route:instruments').click();
      assert.equal((await snap()).sustainActive,false,'reload has no active control contacts');

      // Enter on an on-screen key releases correctly, including after sustain.
      await page.locator('[data-note="60"]').focus();
      await noteDown('Enter');
      await page.keyboard.up('Enter');
      assert.deepEqual((await snap()).activeNotes, []);
      await cc(127); await noteDown('a'); await page.keyboard.up('a');
      await page.locator('#instrument-panic').click();
      assert.equal((await snap()).sustainActive, false);
      assert.deepEqual((await snap()).activeNotes, []);
      await cc(127); await noteDown('a'); await page.keyboard.up('a');
      await page.evaluate(() => window.dispatchEvent(new Event('blur')));
      assert.equal((await snap()).sustainActive, false);
      assert.deepEqual((await snap()).activeNotes, []);

      // Drums retain their own decay instead of becoming held instrument notes.
      await a('select:instrument-2').click();
      await cc(127,{channel:10});await page.evaluate(()=>instrumentDemo.receiveMidi({device:'usb',channel:10,kind:'note',number:36,value:100}));await page.waitForFunction(()=>instrumentDemo.snapshot().voices.some(v=>v.id==='instrument-2'));await page.evaluate(()=>instrumentDemo.receiveMidi({device:'usb',channel:10,kind:'note',number:36,value:0}));assert.deepEqual((await snap()).sustainedNotes,[]);await cc(0,{channel:10});
      await a('select:instrument-1').click();
      assert.equal((await snap()).sustainActive, false);
      await page.setViewportSize({ width: 1280, height: 900 });
      await a('controls').click();
      await page.evaluate(() => instrumentDemo.turn(1));
      const geometry = await page.evaluate(() => {
        const screen = document.querySelector('#screen').getBoundingClientRect();
        const viewport = document.querySelector('.viewport').getBoundingClientRect();
        const dialog = document.querySelector('.dialog').getBoundingClientRect();
        return { aligned: Math.abs(screen.left - viewport.left) < 1, fits: dialog.top >= screen.top && dialog.bottom <= screen.bottom };
      });
      assert.ok(geometry.aligned && geometry.fits);
      assert.deepEqual(errors, []);
      console.log(kind + ': sustain release, held keys, retrigger, source isolation, momentary/latch assignments, persistence, panic, focus loss, drums and scaled layout passed');
    } finally { await browser.close(); }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
