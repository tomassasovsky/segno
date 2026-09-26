const { chromium, firefox } = require('playwright');
const assert = require('node:assert/strict');
const path = require('node:path');

(async () => {
  for (const kind of ['chrome', 'firefox']) {
    const browser = await (kind === 'chrome' ? chromium : firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
    try {
      const page = await browser.newPage({viewport:{width:1920,height:1200}});
      const errors=[];page.on('pageerror',e=>errors.push(e.message));
      const a=id=>page.locator(`[data-action=${JSON.stringify(id)}]`);
      const snap=async()=>{const s=await page.evaluate(()=>instrumentDemo.snapshot()),vs=s.voices.filter(v=>v.id===s.state.selected);return {...s,activeNotes:vs.map(v=>v.note)};};
      const pressNote=async n=>{const el=page.locator(`.mapping-target [data-note="${n}"]`);await el.click({position:{x:12,y:110}});};
      await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html'); await a('settings').click(); await a('route:open').click(); await a('route:instruments').click();
      await a('maps').click();if(await a('map-add').count())await a('map-add').click();await a('map-learn').click();
      assert.equal(await page.locator('[data-action^="map-kind:"]').count(),0,'computer editor does not contain MIDI selection');
      await page.keyboard.press('z');
      assert.equal((await snap()).modal.source.code,'KeyZ');
      for(const n of [48,52,55])await pressNote(n);
      assert.deepEqual((await snap()).modal.notes,[48,52,55]);
      await page.screenshot({path:path.join(__dirname,'virtual-instrument-previews',`${kind}-map-chord.png`)});
      await a('map-keep').click();await a('maps-save').click();if(await a('midi-save').count())await a('midi-save').click();
      await page.keyboard.down('z');
      await page.waitForFunction(()=>instrumentDemo.snapshot().voices.filter(v=>v.id==='instrument-1').length===3);
      assert.deepEqual((await snap()).activeNotes,[48,52,55]);
      await page.keyboard.up('z');assert.deepEqual((await snap()).activeNotes,[]);

      // Cancelling a changed source leaves the saved mapping intact.
      await a('maps').click();await a('map-edit:13').click();await a('map-learn').click();
      await page.keyboard.press('x');await a('map-back').click();await a('cancel').click();
      assert.equal((await snap()).state.instruments[0].mappings[13].source.code,'KeyZ');
      await a('maps').click();if(await a('map-add').count())await a('map-add').click();await a('map-learn').click();
      await page.keyboard.press('z');await pressNote(60);
      assert.equal(await a('map-keep').isDisabled(),true,'same source cannot be added twice');
      await a('map-back').click();await a('cancel').click();

      // Learn simulated MIDI Note On, retain source identity, and map a chord.
      const beforeMidi=(await snap()).state.instruments[0].mappings;
      await a('midi').click();await a('map-midi').click();await a('map-add').click();await a('map-learn').click();
      await page.locator('#instrument-midi-pad').click();await pressNote(60);
      await a('map-keep').click();await a('maps-save').click();await a('cancel').click();
      assert.deepEqual((await snap()).state.instruments[0].mappings,beforeMidi,'outer Cancel discards nested MIDI edits');
      await a('midi').click();await a('map-midi').click();if(await a('map-add').count())await a('map-add').click();await a('map-learn').click();
      await page.locator('#instrument-midi-pad').click();
      assert.deepEqual((await snap()).modal.source,{type:'midi',device:'usb',channel:10,kind:'note',number:36});
      for(const n of [60,64,67])await pressNote(n);
      await a('map-keep').click();await a('maps-save').click();if(await a('midi-save').count())await a('midi-save').click();
      const pad=await page.locator('#instrument-midi-pad').boundingBox();
      await page.mouse.move(pad.x+10,pad.y+10);await page.mouse.down();
      await page.waitForFunction(()=>instrumentDemo.snapshot().voices.filter(v=>v.id==='instrument-1').length===3);
      assert.deepEqual((await snap()).activeNotes,[60,64,67]);
      await page.mouse.up();assert.deepEqual((await snap()).activeNotes,[]);
      await page.evaluate(()=>instrumentDemo.receiveMidi({device:'Another keyboard',channel:1,kind:'note',number:36,value:100}));
      await page.waitForTimeout(30);assert.deepEqual((await snap()).activeNotes,[]);

      // Any MIDI pitch is reachable, including both boundaries.
      await a('midi').click();await a('map-midi').click();if(await a('map-add').count())await a('map-add').click();await a('map-learn').click();
      await page.locator('#instrument-midi-cc').click();
      assert.equal((await snap()).modal.source.kind,'cc');
      for(let i=0;i<4;i++)await a('map-octave:-12').click();
      await pressNote(0);
      for(let i=0;i<9;i++)await a('map-octave:12').click();
      await pressNote(127);
      assert.deepEqual((await snap()).modal.notes,[0,127]);
      await a('map-keep').click();await a('maps-save').click();if(await a('midi-save').count())await a('midi-save').click();
      await page.reload(); await a('settings').click(); await a('route:open').click(); await a('route:instruments').click();assert.equal((await snap()).state.instruments[0].mappings.length,16);
      await a('maps').click();
      assert.equal(await page.locator('.mapping-row').count(),14,'computer list excludes MIDI mappings');
      await page.screenshot({path:path.join(__dirname,'virtual-instrument-previews',`${kind}-mappings.png`)});
      const bounds=await page.locator('.dialog').evaluate(el=>{const r=el.getBoundingClientRect(),s=document.querySelector('#screen').getBoundingClientRect();return {fits:r.top>=s.top&&r.bottom<=s.bottom,overflow:el.scrollHeight>el.clientHeight+1};});
      assert.ok(bounds.fits&&!bounds.overflow);
      await a('cancel').click();
      for(const number of [0,24,84,127]){
        await page.evaluate(number=>instrumentDemo.receiveMidi({device:'usb',channel:1,kind:'note',number,value:100}),number);
        await page.waitForFunction(number=>instrumentDemo.snapshot().heldNotes.includes(number),number);
        await page.evaluate(number=>instrumentDemo.receiveMidi({device:'usb',channel:1,kind:'note',number,value:0}),number);
      }
      assert.deepEqual((await snap()).activeNotes,[],'unmapped notes pass through over the entire MIDI range');
      // Editing a name never triggers mapped computer notes.
      await a('rename').click();await page.getByRole('textbox',{name:'Instrument name'}).fill('zz');
      assert.deepEqual((await snap()).activeNotes,[]);
      assert.deepEqual(errors,[]);
      console.log(kind+': custom chords, release, cancel, duplicate prevention, MIDI note/CC learn, source isolation, all note pitches, reload and dialog layout passed');
    } finally {await browser.close();}
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
