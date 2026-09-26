const {chromium, firefox} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const base = process.env.FX_REFERENCE_URL || 'http://127.0.0.1:8768/fx-reference-inspector.html';
const output = process.env.FX_REFERENCE_OUTPUT || path.join(__dirname, 'fx-reference-evidence/previews');
(async () => {
  for (const kind of ['chrome','firefox']) {
    const browser = await (kind === 'chrome' ? chromium : firefox).launch({headless:true,
      ...(kind === 'chrome' ? {executablePath:process.env.ATLAS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'} : {})});
    try {
      const page = await browser.newPage({viewport:{width:1920,height:1080}}), errors = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('response', response => {if (response.status() >= 400) errors.push(response.status() + ' ' + response.url());});
      await page.goto(base); await page.evaluate(() => {localStorage.setItem('evidence-sentinel','unchanged');}); await page.reload();
      await page.evaluate(() => document.fonts.ready);
      const stored = await page.evaluate(() => JSON.stringify(localStorage));
      assert.equal(await page.locator('#items .item').count(), 52);
      assert.equal(await page.locator('#detail h2').innerText(), 'Amp Drive');
      assert.match(await page.locator('#saved-value').innerText(), /0\.180000007/);
      await page.locator('#native-evidence summary').click();
      assert.match(await page.locator('#native-evidence').innerText(), /%\.1f %%/);
      assert.match(await page.locator('#detail').innerText(), /Factory reset default\s+Unverified/);
      fs.mkdirSync(output, {recursive:true});
      await page.screenshot({path:path.join(output,kind+'-amp-drive.png'),fullPage:true});
      await page.locator('#search').fill('Cab');
      assert.equal(await page.locator('#items .item').count(), 1);
      assert.equal(await page.locator('#detail h2').innerText(), 'Cab');
      await page.locator('#native-evidence summary').click();
      assert.match(await page.locator('#native-evidence').innerText(), /D\.I\..*BRIT.*4x12/);
      await page.locator('#preset').selectOption({label:'Bass Amp Dirty'});
      const expected = await page.evaluate(() => {
        const f=LOOPERX_FACTORY.families.find(f=>f.name==="Ed's Rack");
        return Number(f.presets.find(p=>p.name==='Bass Amp Dirty').parameters.Cab.toPrecision(9));
      });
      assert.match(await page.locator('#saved-value').innerText(), new RegExp(String(expected).replace('.', '\\.')));
      await page.screenshot({path:path.join(output,kind+'-cab-evidence.png'),fullPage:true});
      await page.locator('#family').selectOption('Guitar Rack');
      assert.equal(await page.locator('#native-evidence').count(), 0);
      assert.match(await page.locator('#detail').innerText(), /No completed native constructor-to-UI trace/);
      await page.locator('#search').fill(''); await page.locator('#status').selectOption('module-enable');
      assert(await page.locator('#items .item').count() > 0);
      assert.equal(await page.locator('#items .item').filter({hasText:'Unresolved'}).count(), 0);
      await page.locator('[data-tab="singles"]').click();
      assert.equal(await page.locator('#items .item').count(), 26);
      assert.match(await page.locator('#detail').innerText(), /Native Single FX schema unresolved/);
      await page.screenshot({path:path.join(output,kind+'-single-schema.png'),fullPage:true});
      await page.locator('[data-tab="audio"]').click();
      assert.equal(await page.locator('#items .item').count(), 302);
      await page.locator('#search').fill('035 6-8 Brushes 1.wav');
      assert.equal(await page.locator('#items .item').count(), 1);
      assert.match(await page.locator('#detail').innerText(), /Playback requires the original audio file/);
      assert.equal(await page.locator('audio').count(), 0);
      await page.screenshot({path:path.join(output,kind+'-factory-audio.png'),fullPage:true});
      const downloadEvent = page.waitForEvent('download'); await page.locator('#download').click();
      const download = await downloadEvent, stream = await download.createReadStream(), chunks=[];
      for await (const chunk of stream) chunks.push(chunk);
      const missing = JSON.parse(Buffer.concat(chunks));
      assert.equal(missing.unresolvedControls.length,239); assert.equal(missing.unavailableFactoryAudio.length,302);
      await page.locator('#search').fill('no such file');
      assert.match(await page.locator('#detail').innerText(), /No matching evidence/);
      await page.goto(base+'?tab=audio&search=035%206-8%20Brushes%201.wav');
      assert.equal(await page.locator('#items .item').count(),1);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      assert.equal(overflow, false);
      assert.equal(await page.evaluate(() => JSON.stringify(localStorage)),stored);
      assert.deepEqual(errors,[]);
      console.log(kind+': exact source selection, family isolation, all collections, missing-source download, no playback or storage mutation passed.');
    } finally {await browser.close();}
  }
})().catch(error => {console.error(error);process.exitCode=1;});
