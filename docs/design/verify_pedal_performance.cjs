const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');

(async () => {
  for (const kind of ['chrome', 'firefox']) {
    const browser = await (kind === 'chrome' ? chromium : firefox).launch({headless: true, ...(kind === 'chrome' ? {executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'} : {})});
    try {
      const p = await browser.newPage({viewport: {width: 1920, height: 1080}});
      const errors = [];
      p.on('pageerror', e => errors.push(e.message));
      const button = action => p.locator('[data-action=' + JSON.stringify(action) + ']');
      const foot = id => button('perform:' + id);
      const snapshot = () => p.evaluate(() => segnoDemo.snapshot().performance);
      const state = async expected => assert.equal((await snapshot()).view, expected);
      const led = id => foot(id).locator('.pedal-led');
      const hold = async id => {await foot(id).focus(); await p.keyboard.down(' '); await p.waitForTimeout(900);};
      await p.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review=pedal-setup&canvas=actual');
      await button('stage').click();
      await state('tracks');
      await foot(3).focus(); await p.keyboard.down(' '); await state('tracks'); await p.keyboard.up(' '); await state('mute');
      await foot(4).click(); assert.equal((await snapshot()).muted[0], true); assert.equal(await led(4).getAttribute('data-state'), 'active');
      await foot(3).click(); await state('tracks');
      await hold(3); await state('custom'); await p.keyboard.up(' '); await state('custom');
      assert.equal((await snapshot()).muted[0], true);
      if (kind === 'chrome') await p.screenshot({path: '/tmp/pedal-performance-custom.png'});
      await foot(5).click(); await state('fx');
      await foot(4).click(); const shared=await p.evaluate(()=>segnoDemo.snapshot());assert.equal(shared.effective['rack-1'],false);assert.equal(shared.effective['rack-2'],true);assert.equal((await snapshot()).fx[0].active, true); assert.equal(await led(4).getAttribute('data-state'), 'active');
      await foot(5).focus(); await p.keyboard.down(' '); assert.equal((await snapshot()).fx[1].active, true);
      if (kind === 'chrome') await p.screenshot({path: '/tmp/pedal-performance-fx.png'});
      await foot(9).click(); assert.equal((await snapshot()).bank, 1); assert.equal(await led(5).getAttribute('data-state'), 'idle');
      await p.keyboard.up(' '); assert.equal((await snapshot()).fx[1].active, false); assert.equal((await snapshot()).fx[5].active, false);
      await foot(9).click(); assert.equal(await led(4).getAttribute('data-state'), 'active');
      await foot(5).focus(); await p.keyboard.down(' '); await foot(3).click(); await state('tracks');
      assert.equal((await snapshot()).fx[1].active, false); assert.equal((await snapshot()).fx[0].active, true);
      await p.keyboard.up(' '); await state('tracks');
      await hold(3); await p.keyboard.up(' '); await foot(5).click(); await state('fx');
      assert.equal(await led(4).getAttribute('data-state'), 'active');
      await foot(4).click(); assert.equal((await snapshot()).fx[0].active, false);
      await foot(5).focus(); await p.keyboard.down(' '); await p.evaluate(() => dispatchEvent(new Event('blur')));
      assert.equal((await snapshot()).fx[1].active, false); assert.equal(await led(5).getAttribute('data-state'), 'idle', 'focus loss redraws the released LED'); await p.keyboard.up(' ');
      await foot(3).click(); await state('tracks');
      await foot(3).dispatchEvent('pointerdown', {pointerId: 77, button: 0});
      await p.evaluate(() => dispatchEvent(new PointerEvent('pointercancel', {pointerId: 77})));
      await p.waitForTimeout(900); await state('tracks'); assert.equal((await snapshot()).pending, 0);
      // A saved setup change drives the performance entry, not a duplicate default.
      await button('settings').click();await button('pedal-setup').click();await button('setup:context:tracks').click(); await button('setup:select:3').click(); await button('setup:edit:3:press').click();
      await button('setup:choose:FX').click(); await button('setup:save').click(); await button('stage').click();
      await foot(3).click(); await state('fx');
      const overflowing = await p.evaluate(() => [...document.querySelectorAll('#screen button')].filter(e => {
        const r = e.getBoundingClientRect(); return r.top < 0 || r.bottom > 1081 || r.left < 0 || r.right > 1921 || e.scrollWidth > e.clientWidth + 2 || e.scrollHeight > e.clientHeight + 2;
      }).map(e => e.textContent.trim()));
      assert.deepEqual(overflowing, []); assert.deepEqual(errors, []);
      console.log(kind + ': saved assignments, Press/Hold exclusivity, Tracks/Custom/FX/Mute, banks, state LEDs, momentary release after bank/Exit, cancellation and layout passed.');
    } finally {await browser.close();}
  }
})();
