const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {scenes, apply} = require('./performance-feedback-scenes.cjs');

(async () => {
  for (const kind of ['chrome', 'firefox']) {
    const browser = await (kind === 'chrome' ? chromium : firefox).launch({headless: true, ...(kind === 'chrome' ? {executablePath: process.env.ATLAS_CHROME} : {})});
    try {
      const page = await browser.newPage({viewport: {width: 1920, height: 1080}});
      const errors = [];
      page.on('pageerror', e => errors.push(e.message));
      await page.clock.install({time: new Date('2026-09-07T18:00:00Z')});
      await page.clock.pauseAt(new Date('2026-09-07T18:00:01Z'));
      const foot = id => page.locator(`[data-action="perform:${id}"]`);
      const open = review => page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review=' + review + '&canvas=actual');
      const snap = () => page.evaluate(() => segnoDemo.snapshot().performance);
      const down = id => foot(id).dispatchEvent('pointerdown', {pointerId: id, button: 0});
      const up = (id, cancel = false) => page.evaluate(({id, cancel}) => dispatchEvent(new PointerEvent(cancel ? 'pointercancel' : 'pointerup', {pointerId: id})), {id, cancel});
      const tap = async id => {await down(id); await up(id);};
      const lit = id => foot(id).locator('.pedal-led').getAttribute('data-state');
      const progress = id => foot(id).locator('[data-hold-progress]').evaluate(e => parseFloat(e.style.width));
      await open('performance-tracks');
      const size = await foot(3).boundingBox(), focusStops = await page.locator('#screen [data-action]').count();
      await down(3); await page.clock.runFor(240);
      assert.equal((await snap()).view, 'tracks');
      assert.equal(await progress(3), 30);
      assert.equal(await lit(3), 'idle', 'pending Hold does not light the state LED');
      assert.deepEqual(await foot(3).boundingBox(), size, 'feedback does not move the layout');
      assert.equal(await page.locator('#screen [data-action]').count(), focusStops, 'progress adds no encoder stop');
      assert.equal(await foot(3).locator('.pedal-hold-progress').getAttribute('aria-hidden'), 'true');
      await page.clock.runFor(400); assert.equal(await progress(3), 80);
      await up(3, true); await page.clock.runFor(400);
      assert.equal((await snap()).view, 'tracks');
      assert.equal(await page.locator('.pedal-hold-progress').count(), 0);
      await down(3); await page.clock.runFor(810);
      assert.equal((await snap()).view, 'custom');
      assert.equal(await page.locator('.pedal-hold-progress').count(), 0);
      await up(3); assert.equal((await snap()).view, 'custom', 'release after Hold cannot execute Press');
      await open('performance-tracks'); await down(3); await page.clock.runFor(200); await up(3);
      assert.equal((await snap()).view, 'mute', 'a short press retains the saved action');
      await open('performance-tracks'); await down(3); await page.clock.runFor(300);
      await page.evaluate(() => dispatchEvent(new Event('blur'))); await page.clock.runFor(600);
      assert.equal((await snap()).view, 'tracks'); assert.equal((await snap()).pending, 0);
      assert.equal(await page.locator('.pedal-contact,.pedal-hold-progress').count(), 0);

      await open('performance-fx'); await tap(4);
      assert.equal(await lit(4), 'active'); assert.equal(await foot(4).evaluate(e => e.classList.contains('pedal-contact')), false, 'latched LED stays on after release');
      await down(5); assert.equal(await lit(5), 'active');
      assert.equal(await foot(5).evaluate(e => e.classList.contains('momentary-contact')), true);
      await tap(9);
      assert.equal(await lit(5), 'idle'); assert.equal(await foot(5).evaluate(e => e.classList.contains('pedal-contact')), false, 'new bank does not inherit the old contact');
      await up(5); assert.equal((await snap()).fx[1].held, false); assert.equal((await snap()).fx[5].held, false);
      await tap(9); assert.equal(await lit(4), 'active'); await down(5); await tap(3);
      assert.equal((await snap()).fx[1].held, false); assert.equal(await page.locator('.momentary-contact').count(), 0);
      await up(5); assert.equal((await snap()).view, 'tracks');

      // Completed reset stays in its view; its progress disappears at the threshold.
      await open('performance-transpose'); await down(2); await page.clock.runFor(400);
      assert.equal(await progress(2), 50); await page.clock.runFor(410);
      assert.equal((await snap()).transpose.pitches[0], 0);
      assert.equal(await page.locator('.pedal-hold-progress').count(), 0);
      await up(2); assert.equal((await snap()).transpose.pitches[0], 0);
      // A pending track hold follows the newly visible bank, as agreed.
      await open('performance-fade'); await down(4); await page.clock.runFor(320); await tap(9);
      assert.equal(await progress(4), 40, 'a redraw does not restart progress');
      await page.clock.runFor(490); await up(4);
      assert.equal((await snap()).fade.selected, 4);

      for (const [name, review] of Object.entries(scenes)) {
        await open(review); await page.evaluate(() => document.fonts.ready); await apply(page, name);
        const overflow = await page.evaluate(() => [...document.querySelectorAll('#screen button')].filter(e => {const r = e.getBoundingClientRect(); return r.x < 0 || r.y < 0 || r.right > 1921 || r.bottom > 1081 || e.scrollWidth > e.clientWidth + 2 || e.scrollHeight > e.clientHeight + 2;}).map(e => e.textContent.trim()));
        assert.deepEqual(overflow, [], name);
        if (kind === 'chrome') {fs.mkdirSync('docs/design/performance-feedback-previews', {recursive: true}); await page.locator('#screen').screenshot({path: `docs/design/performance-feedback-previews/${name}.png`});}
      }
      assert.deepEqual(errors, []);
      console.log(kind + ': hold progress, unchanged geometry and focus stops, exclusive actions, cancellation, reset, bank targeting and FX contact/latched LEDs passed.');
    } finally {await browser.close();}
  }
})().catch(e => {console.error(e); process.exitCode = 1;});
