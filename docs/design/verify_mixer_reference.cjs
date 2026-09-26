const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{
 for(const kind of ['chrome','firefox']){
  const browser=await (kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
  try{
   const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
   page.on('pageerror',e=>errors.push(e.message));
   await page.clock.install({time:new Date('2026-09-08T06:00:00Z')});
   await page.clock.pauseAt(new Date('2026-09-08T06:00:01Z'));
   const button=id=>page.locator('[data-action='+JSON.stringify(id)+']');
   const state=()=>page.evaluate(()=>segnoDemo.displayState());
   const saved=()=>page.evaluate(()=>segnoDemo.snapshot());
   await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review=stage-layout-mixer&canvas=actual');
   await page.evaluate(()=>document.fonts.ready);
   assert.equal(await page.locator('.stage-track').count(),4);
   assert.equal(await page.locator('.stage-stereo-lane').count(),8);
   const geometry=await page.locator('.stage-meter-fader,.stage-db-scale').evaluateAll(es=>es.map(e=>({y:e.getBoundingClientRect().y,h:e.getBoundingClientRect().height})));
   assert.ok(geometry.every(g=>Math.abs(g.y-geometry[0].y)<1&&Math.abs(g.h-geometry[0].h)<1),'shared signal scales align with both sides of all meters: '+JSON.stringify(geometry));
   const initial=await saved();
   await button('stage-solo:0').click();
   let s=await state();assert.equal(s.tracks[0].solo,true);assert.equal(s.tracks[1].suppressed,true);assert.equal(s.tracks[1].stereo.left,0);
   assert.deepEqual((await saved()).trackPlayback,initial.trackPlayback,'Solo does not stop playback');
   assert.deepEqual((await saved()).rig.mutedTracks,initial.rig.mutedTracks,'Solo does not overwrite manual mute');
   await button('stage-solo:1').click();s=await state();assert.ok(s.tracks[0].solo&&s.tracks[1].solo);assert.equal(s.tracks[1].suppressed,false);
   await button('stage-bank').click();s=await state();assert.ok(s.tracks.slice(4).every(t=>t.suppressed));
   await button('stage-bank').click();await button('stage-mute:0').click();assert.equal((await state()).tracks[0].stereo.left,0,'Manual mute still works on a soloed track');
   await button('stage-clear-solo').click();assert.ok((await state()).tracks.every(t=>!t.solo));assert.equal((await state()).tracks[0].muted,true);
   await button('stage-mute:0').click();
   await button('stage-mix:0:level').fill('-6');assert.ok(Math.abs((await state()).tracks[0].level-10**(-6/20))<1e-9);
   await button('stage-mix:0:level').focus();await page.evaluate(()=>segnoDemo.press());await page.evaluate(()=>segnoDemo.turn(2));
   assert.ok(Math.abs((await state()).tracks[0].level-10**(-5/20))<1e-9,'encoder uses half-decibel increments');
   await page.keyboard.press('Escape');assert.ok(Math.abs((await state()).tracks[0].level-10**(-6/20))<1e-9,'cancel restores the exact gain');
   await button('stage-mix:0:level').dblclick();assert.equal((await state()).tracks[0].level,1);
   await button('stage-mix:0:pan').fill('0');assert.equal((await state()).tracks[0].stereo.right,0,'hard pan silences the opposite simulated channel');
   await button('stage-mix:0:pan').dblclick();assert.equal((await state()).tracks[0].pan,.5);
   await button('stage-mix:0:level').fill('-60');assert.equal((await state()).tracks[0].level,0);assert.equal(await page.locator('[data-stage-value="stage-mix:0:level"]').textContent(),'−∞ dB');
   await button('stage-fx-power:0').click();let rig=(await saved()).rig;assert.equal(rig.trackFxBypass['Track 1'],true);
   assert.deepEqual(rig.racks,initial.rig.racks,'track FX gate retains all rack states and parameters');assert.equal((await state()).tracks[0].fx.active,0);
   await button('stage-fx:0').click();assert.equal((await saved()).page,'sounds');assert.equal((await saved()).source,'Track 1');assert.equal(await page.locator('.mixer-fx-bypass-notice').count(),1);
   await button('stage-fx-power:0').click();assert.equal((await saved()).rig.trackFxBypass['Track 1'],false);await button('back').click();assert.equal((await state()).displayView,'mixer');
   await button('stage-mix:1:level').fill('-12');await button('stage-mix:1:pan').fill('0.2');await button('stage-solo:1').click();await button('stage-mute:0').click();await button('stage-fx-power:0').click();
   const beforeReset=(await saved()).rig;
   await button('stage-reset').click();assert.equal(await page.getByRole('dialog',{name:'Reset mixer'}).count(),1);await button('stage-reset-cancel').click();assert.deepEqual((await saved()).rig.expressionMix,beforeReset.expressionMix);
   await button('stage-reset').click();await button('stage-reset-confirm').click();s=await state();assert.ok(s.tracks.every(t=>t.level===1&&t.pan===.5));rig=(await saved()).rig;
   for(const key of ['mutedTracks','soloTracks','trackFxBypass','racks'])assert.deepEqual(rig[key],beforeReset[key],'reset preserves '+key);
   await page.evaluate(()=>localStorage.setItem('segno-fx-factory-design-2026-09-06-channels',JSON.stringify(segnoDemo.snapshot().rig)));
   await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?canvas=actual');assert.equal((await state()).displayView,'track');assert.equal((await state()).tracks[1].solo,true);assert.equal((await state()).tracks[0].fx.bypassed,true);
   await button('stage-view-menu').click();await button('stage-view:mixer').click();
   assert.deepEqual(errors,[]);
   if(kind==='chrome'){
    await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review=stage-layout-mixer&canvas=actual');
    fs.mkdirSync('docs/design/mixer-reference-previews',{recursive:true});
    await page.locator('#screen').screenshot({path:'docs/design/mixer-reference-previews/mixer.png'});
    await button('stage-solo:0').click();await button('stage-solo:1').click();
    await page.locator('#screen').screenshot({path:'docs/design/mixer-reference-previews/multi-solo.png'});
   }
   console.log(kind+': Mixer stereo/gain, multi-solo, bank persistence, manual mute, encoder/cancel/reset, FX gate/edit/back, whole-mix reset and reload pass.');
  }finally{await browser.close();}
 }
})().catch(e=>{console.error(e);process.exitCode=1;});
