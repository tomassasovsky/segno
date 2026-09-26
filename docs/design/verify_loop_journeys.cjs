// Author-side UI simulation checks; no engine or appliance claims.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
(async()=>{
 const browser=await (process.env.FX_BROWSER==='firefox'?firefox:chromium).launch({headless:true,...(process.env.ATLAS_CHROME&&process.env.FX_BROWSER!=='firefox'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try {
  const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
  const click=id=>page.locator('[data-action='+JSON.stringify(id)+']').click();
  const snap=()=>page.evaluate(()=>segnoDemo.snapshot());
  await page.goto(base+'?review=settings');await click('loop:page:loop-settings');await click('loop:page:loop-recording');
  const fx=(await snap()).rig.racks;await click('loop:recDub:true');await click('loop:start:sound');let s=await snap();assert.equal(s.loopSettings.recDub,true);assert.equal(s.loopSettings.start,'sound');assert.equal(s.loopSettings.countIn,0,'sound activation clears count-in');assert.deepEqual(s.rig.racks,fx,'recording setup does not mutate FX');
  await click('back');assert.equal((await snap()).page,'loop-settings');await click('loop:page:loop-timing');
  const tempo=page.locator('[data-action="loop:tempo"]');await tempo.focus();await page.evaluate(()=>{segnoDemo.press();segnoDemo.turn(10);});assert.equal((await snap()).loopSettings.tempo,94);await page.evaluate(()=>{segnoDemo.pedalDown(0);segnoDemo.pedalUp(0);});await page.keyboard.press('Escape');assert.equal((await snap()).loopSettings.tempo,84,'cancel restores opening tempo');assert.equal((await snap()).page,'loop-timing');
  await tempo.focus();await page.evaluate(()=>{segnoDemo.press();segnoDemo.turn(10);segnoDemo.press();});assert.equal((await snap()).loopSettings.tempo,94);
  await tempo.dblclick();assert.equal((await snap()).loopSettings.tempo,84,'double tap restores the prepared tempo');await click('loop:click:always');await click('loop:countIn:2');assert.equal((await snap()).loopSettings.start,'press','count-in restores pedal start');await click('loop:page:loop-signature');assert.equal(await page.locator('.signature-grid button').count(),17);await click('loop:signature:7/8');assert.equal((await snap()).page,'loop-timing');assert.equal((await snap()).loopSettings.signature,'7/8');
  await click('back');await click('loop:page:loop-mode');await click('loop:mode:band');assert.equal((await snap()).loopSettings.mode,'band');
  await page.goto(base+'?review=loop-mode-incompatible');assert.equal(await page.locator('.mode-choices button:disabled').count(),3,'incompatible lengths disable only incompatible modes');
  await page.goto(base+'?review=loop-midi');assert.equal(await tempo.isDisabled(),true);assert.equal(await page.locator('[data-action="loop:page:loop-signature"]').isEnabled(),true,'empty loop permits signature under external clock');assert.equal(await page.locator('[data-action^="loop:countIn:"]:disabled').count(),0);
  await page.goto(base+'?review=loop-recording-locked');assert.equal(await page.locator('.loop-choice:disabled').count(),4);await page.evaluate(()=>segnoDemo.setCapture('Track 1','idle'));await click('loop:recDub:true');assert.equal((await snap()).loopSettings.recDub,true);
  await page.goto(base+'?review=loop-length');assert.equal((await snap()).loopSettings.lengthTiming.bars,0);
  await click('loop:length:fixed');await click('loop:bars-step:1');assert.equal((await snap()).loopSettings.lengthTiming.bars,5);
  const bars=page.locator('[data-action="loop:bars"]');await bars.focus();await page.evaluate(()=>{segnoDemo.press();segnoDemo.turn(12);});assert.equal((await snap()).loopSettings.lengthTiming.bars,17);await page.keyboard.press('Escape');assert.equal((await snap()).loopSettings.lengthTiming.bars,5,'cancel restores the opening length');
  await bars.focus();await page.evaluate(()=>{segnoDemo.press();segnoDemo.turn(100);segnoDemo.press();});assert.equal((await snap()).loopSettings.lengthTiming.bars,64);assert.equal(await page.locator('[data-action="loop:bars-step:1"]').isDisabled(),true);
  await click('loop:length:auto');assert.equal((await snap()).loopSettings.lengthTiming.bars,0);await click('loop:length:fixed');assert.equal((await snap()).loopSettings.lengthTiming.bars,64,'returning to bars remembers the value');
  for(const choice of ['loop','bar','half','quarter','eighth','sixteenth','immediate']){await click('loop:quantize:'+choice);assert.equal((await snap()).loopSettings.lengthTiming.quantize,choice);}
  await click('back');await click('loop:page:loop-timing');await click('loop:click:off');await click('back');await click('loop:page:loop-length');assert.equal((await snap()).loopSettings.lengthTiming.bars,64,'audible click does not change the proposed fixed length');
  await page.goto(base+'?review=loop-length-locked');assert.equal(await bars.isDisabled(),true);assert.equal(await page.locator('[data-action="loop:quantize:immediate"]').isDisabled(),true);await page.evaluate(()=>segnoDemo.setCapture('Track 1','idle'));await click('loop:length:auto');assert.equal((await snap()).loopSettings.lengthTiming.bars,0);
  await page.goto(base+'?review=loop-length-midi');assert.equal(await bars.isDisabled(),false);await click('loop:quantize:loop');assert.equal((await snap()).loopSettings.lengthTiming.quantize,'loop');
  // Inheritance is per field, and matching values are still explicit overrides.
  await page.goto(base+'?review=loop-track-default');
  assert.equal(await page.locator('.length-scopes button').count(),9,'defaults and all eight tracks remain visible');
  const firstView=(await snap()).loopView;assert.deepEqual({target:firstView.target,effective:firstView.effective,origins:firstView.origins},{target:'Track 3',effective:{bars:4,quantize:'bar'},origins:{bars:'Default',quantize:'Default'}});
  await click('loop:quantize:bar');assert.deepEqual((await snap()).loopSettings.trackLengthTiming['Track 3'],{quantize:'bar'});
  await click('loop:scope:defaults');await click('loop:bars-step:1');await click('loop:quantize:quarter');await click('loop:scope:Track 3');
  assert.deepEqual((await snap()).loopView.effective,{bars:5,quantize:'bar'},'only the inherited field follows default changes');
  await click('loop:inherit:quantize');assert.equal((await snap()).loopView.effective.quantize,'quarter');assert.equal((await snap()).loopView.origins.quantize,'Default');
  await bars.focus();await page.evaluate(()=>{segnoDemo.press();segnoDemo.turn(3);});assert.equal((await snap()).loopView.origins.bars,'Custom');
  await page.keyboard.press('Escape');assert.equal((await snap()).loopView.origins.bars,'Default','cancel restores ownership, not a copy of the old default');assert.equal((await snap()).loopView.effective.bars,5);
  await bars.focus();await page.evaluate(()=>{segnoDemo.press();segnoDemo.turn(3);});await click('loop:scope:Track 4');assert.equal((await snap()).loopView.effective.bars,5);await click('loop:scope:Track 3');assert.equal((await snap()).loopView.origins.bars,'Default','changing target cancels the old target draft');
  await click('loop:length:auto');assert.deepEqual((await snap()).loopSettings.trackLengthTiming['Track 3'],{bars:0},'Auto can override a fixed default');
  await click('loop:scope:defaults');await click('loop:bars-step:1');await click('loop:scope:Track 3');assert.equal((await snap()).loopView.effective.bars,0);await click('loop:inherit:bars');assert.equal((await snap()).loopView.effective.bars,6);
  await bars.focus();await page.evaluate(()=>{segnoDemo.press();segnoDemo.turn(2);segnoDemo.press();});assert.equal((await snap()).loopView.effective.bars,8);assert.equal((await snap()).loopView.origins.bars,'Custom');
  await click('loop:scope:Track 8');assert.equal((await snap()).loopView.effective.bars,6,'overrides never change another track');
  await page.goto(base+'?review=loop-track-multi');assert.equal(await bars.isDisabled(),true);assert.equal((await snap()).loopView.effective.bars,4);assert.equal((await snap()).loopView.origins.bars,'Shared in Multi');assert.equal(await page.locator('[data-action="loop:inherit:bars"]').count(),0);await click('loop:quantize:eighth');assert.equal((await snap()).loopView.effective.quantize,'eighth');
  await click('back');await click('loop:page:loop-mode');await click('loop:mode:sync');await click('back');await click('loop:page:loop-length');assert.equal((await snap()).loopView.effective.bars,8,'shared mode does not erase the independent-mode setting');
  await page.goto(base+'?review=loop-track-locked');assert.equal(await page.locator('[data-action="loop:inherit:bars"]').isDisabled(),true);await click('loop:scope:Track 8');assert.equal((await snap()).loopView.target,'Track 8','locked settings remain inspectable');
  await page.goto(base+'?review=loop-track-midi');assert.equal(await bars.isDisabled(),false);assert.equal(await page.locator('[data-action="loop:inherit:bars"]').isDisabled(),false);await click('loop:inherit:quantize');assert.equal((await snap()).loopView.origins.quantize,'Default');
  // The ordinary URL persists committed overrides, never an encoder preview.
  await page.goto(base);await page.evaluate(()=>localStorage.clear());await page.reload();await click('settings');await click('loop:page:loop-settings');await click('loop:page:loop-mode');await click('loop:mode:sync');await click('back');await click('loop:page:loop-length');await click('loop:length:fixed');await click('loop:scope:Track 3');
  await bars.focus();await page.evaluate(()=>{segnoDemo.press();segnoDemo.turn(9);segnoDemo.pedalDown(0);segnoDemo.pedalUp(0);});
  const saved=await page.evaluate(()=>Object.values(localStorage).map(s=>{try{return JSON.parse(s)}catch{return null}}).find(s=>s?.loopSettings));assert.equal(saved.loopSettings.trackLengthTiming?.['Track 3']?.bars,undefined,'pedal saves cannot persist a draft override');
  await page.keyboard.press('Escape');await click('loop:quantize:eighth');await page.reload();await click('settings');await click('loop:page:loop-settings');await click('loop:page:loop-length');await click('loop:scope:Track 3');assert.deepEqual((await snap()).loopView.effective,{bars:4,quantize:'eighth'});assert.deepEqual((await snap()).loopView.origins,{bars:'Default',quantize:'Custom'});
  const previews=path.join(__dirname,'fx-ux-previews');
  for(const review of ['loop-settings','loop-mode','loop-recording','loop-timing','loop-signature','loop-mode-incompatible','loop-midi','loop-recording-locked','loop-length','loop-length-fixed','loop-length-locked','loop-length-midi','loop-track-default','loop-track-custom','loop-track-multi','loop-track-locked','loop-track-midi']){
   await page.goto(base+'?review='+review);await page.evaluate(()=>document.fonts.ready);
   const layout=await page.locator('#screen').evaluate(s=>({width:s.offsetWidth,height:s.offsetHeight,small:[...s.querySelectorAll('button:not(:disabled),input:not(:disabled)')].filter(e=>e.offsetWidth<56||e.offsetHeight<56).map(e=>e.dataset.action),outside:[...s.querySelectorAll('.main,.titlebar,.loop-menu,.mode-choices,.recording-layout,.timing-layout,.length-timing,.length-scopes,.scope-tab,.length-controls,.quantize-options,.signature-grid')].filter(e=>{const b=e.getBoundingClientRect(),r=s.getBoundingClientRect();return b.left<r.left-1||b.right>r.right+1||b.bottom>r.bottom+1;}).map(e=>e.className)}));
   assert.deepEqual(layout,{width:1920,height:1080,small:[],outside:[]},review+' dimensions and targets');
   if(await page.locator('.length-timing').count()){
    const edges=await page.locator('.main').evaluate(main=>{
     const boxes=['.titlebar','.length-scopes','.length-timing'].map(sel=>main.querySelector(sel).getBoundingClientRect());
     return boxes.map(b=>({left:Math.round(b.left),right:Math.round(b.right)}));
    });
    assert.deepEqual(edges,[edges[0],edges[0],edges[0]],review+' horizontal edges match');
    const controlLefts=await page.locator('.main').evaluate(main=>['.scope-defaults','.length-kind'].map(sel=>Math.round(main.querySelector(sel).getBoundingClientRect().left)));
    assert.equal(controlLefts[0],controlLefts[1],review+' selector and length controls align in both selection states');
   }
   await page.locator('#screen').screenshot({path:path.join(previews,(process.env.FX_BROWSER==='firefox'?'firefox-':'')+review+'.png')});
  }
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(previews,(process.env.FX_BROWSER==='firefox'?'firefox-':'')+'loop-verification.json'),JSON.stringify({checks:['recording choices isolated from FX','direct tempo encoder commit and cancellation','time signature return and all 17 choices','click and count-in choices','per-mode compatibility with existing audio','MIDI ownership','recording locks and unlock','sound start and count-in are exclusive','loop length encoder commit/cancel and 1–64 bounds','seven distinct quantization choices','fixed length independent of click audibility (proposed)','length and timing locks','per-field inheritance, explicit matching overrides, and independent Auto','reset restores inheritance','encoder cancel and scope switch preserve ownership','Multi shared length and independent track timing','committed overrides survive reload; drafts do not','seventeen 1920 × 1080 screens with minimum 56px targets'],errors},null,2)+'\n');
  console.log('Loop setup interactions and seventeen preview captures passed.');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
