// Author-side silent prototype checks, not engine or appliance validation.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const context={window:{}};vm.runInNewContext(fs.readFileSync(__dirname+'/loop-ux-study.js','utf8'),context);
let settings={mode:'free',tempo:84},busy=false,pending=false,tracks=[];
const model=context.window.createLoopStudy({getSettings:()=>settings,recording:()=>busy,modeContext:()=>({tracks,pending}),tracks:[]});
const available=mode=>model.modeAvailability(mode).enabled;
const lengths=values=>tracks=values.map((beats,i)=>({id:'Track '+(i+1),hasAudio:true,beats}));
for(const mode of ['multi','sync','song','band','free'])assert.ok(available(mode));
lengths([16,16]);assert.ok(available('multi'));
lengths([8,16,4]);assert.ok(!available('multi'));assert.ok(available('sync'));assert.ok(available('band'));
lengths([12,16,8]);assert.ok(!available('sync'));assert.ok(!available('band'));assert.ok(available('song'));
settings.primaryTrack='Track 3';assert.ok(available('sync')===false,'primary relationship is checked without converting lengths');
lengths([8,12,4]);assert.ok(available('sync'),'explicit 1-bar primary supports 2- and 3-bar followers');
settings.primaryTrack=null;assert.ok(!available('sync'),'first recorded track is primary when none was chosen');
lengths([4,4.0001]);assert.ok(!available('multi'),'do not round displayed bars to force compatibility');
lengths([4,NaN]);assert.ok(!available('song'),'unknown lengths cannot be committed');
lengths([4,4]);busy=true;assert.ok(!available('free'));busy=false;pending=true;assert.ok(!available('song'));pending=false;

(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const p=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];p.on('pageerror',e=>errors.push(e.message));
  const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
  const click=id=>p.locator('[data-action='+JSON.stringify(id)+']').click();
  const snap=()=>p.evaluate(()=>segnoDemo.snapshot());
  const content=s=>({parts:s.recordedParts,length:s.rig.trackLength,layers:s.rig.trackLayers,racks:s.rig.racks,monitor:s.liveMonitoring,pedals:s.rig.pedalSettings,backing:s.audioLibrary.performance});
  await p.goto(base+'?review=loop-mode');assert.equal(await p.locator('.mode-choices button:disabled').count(),0);
  for(const mode of ['sync','song','band','free','multi']){await click('loop:mode:'+mode);assert.equal((await snap()).loopSettings.mode,mode);assert.equal((await snap()).modal,null);}
  await p.goto(base+'?review=loop-mode-existing');let before=await snap();await click('loop:mode:sync');let after=await snap();
  assert.equal(after.loopSettings.mode,'sync');assert.equal(after.loopSettings.primaryTrack,'Track 1');assert.deepEqual(content(after),content(before));assert.equal(after.modal,null);
  await p.goto(base+'?review=loop-mode-incompatible');assert.equal(await p.locator('.mode-choices button:disabled').count(),3);
  assert.match(await p.locator('[data-action="loop:mode:multi"]').textContent(),/Tracks need equal lengths/);
  await p.locator('[data-action="loop:mode:song"]').focus();await p.evaluate(()=>segnoDemo.press());assert.equal((await snap()).loopSettings.mode,'song','encoder skips unavailable choices');
  await p.goto(base+'?review=loop-mode-playing');before=await snap();await click('loop:mode:song');after=await snap();
  assert.equal(after.loopSettings.mode,'free');assert.deepEqual(after.trackPlayback,before.trackPlayback);assert.equal(after.focusId,'cancel-modal');
  await p.keyboard.press('Escape');assert.equal((await snap()).modal,null);assert.deepEqual(content(await snap()),content(before));
  await click('loop:mode:song');await p.evaluate(()=>segnoDemo.turn(1));assert.equal((await snap()).focusId,'loop:mode-confirm:song');await p.evaluate(()=>segnoDemo.press());after=await snap();
  assert.equal(after.loopSettings.mode,'song');assert.equal(after.page,'loop-mode');assert.equal(after.focusId,'loop:mode:song');assert.equal(after.modal,null);assert.ok(Object.values(after.trackPlayback).every(v=>!v));assert.deepEqual(content(after),content(before));
  // A gesture after opening the dialog must not let confirmation finish a take.
  await p.goto(base+'?review=loop-mode-playing');await click('loop:mode:multi');await p.evaluate(()=>segnoDemo.setCapture('Track 1','overdubbing'));
  assert.equal(await p.locator('[data-action="loop:mode-confirm:multi"]').isDisabled(),true);assert.match(await p.locator('.dialog').textContent(),/Finish recording/);await click('cancel-modal');
  for(const review of ['loop-mode-capture','loop-mode-queued']){await p.goto(base+'?review='+review);assert.equal(await p.locator('.mode-choices button:disabled').count(),5);}
  // Ordinary session path: use persisted content, fail a write, retry, then reload.
  await p.goto(base+'?review=loop-mode-existing');const fixture=await snap();
  await p.evaluate(s=>{localStorage.clear();localStorage.setItem('segno-fx-factory-design-2026-09-06-channels',JSON.stringify({...s.rig,recordedParts:s.recordedParts,loopSettings:s.loopSettings,trackPlayback:s.trackPlayback}));},fixture);
  await p.goto(base);await click('back');await click('loop:page:loop-settings');await click('loop:page:loop-mode');
  assert.equal(await p.locator('[data-action="loop:mode:multi"]').isDisabled(),true,'normal session uses real recorded lengths');
  await p.evaluate(()=>segnoDemo.setPlayback('Track 1',true));before=await snap();await click('loop:mode:song');
  await p.evaluate(()=>{window.originalSetItem=Storage.prototype.setItem;Storage.prototype.setItem=function(){throw Error('test full storage');};});
  await click('loop:mode-confirm:song');after=await snap();assert.equal(after.loopSettings.mode,'free');assert.deepEqual(after.trackPlayback,before.trackPlayback);assert.deepEqual(content(after),content(before));assert.match(await p.locator('.dialog').textContent(),/Could not save/);
  await p.evaluate(()=>Storage.prototype.setItem=window.originalSetItem);await click('loop:mode-confirm:song');assert.equal((await snap()).loopSettings.mode,'song');
  await p.reload();assert.equal((await snap()).loopSettings.mode,'song');assert.deepEqual(content(await snap()),content(before));
  const dir=__dirname+'/loop-mode-previews';fs.mkdirSync(dir,{recursive:true});
  for(const review of ['loop-mode-existing','loop-mode-incompatible','loop-mode-confirm','loop-mode-capture']){
   await p.goto(base+'?review='+review+'&canvas=actual');await p.evaluate(()=>document.fonts.ready);
   assert.equal(await p.locator('.mode-choices button').count(),5);
   const outside=await p.locator('#screen').evaluate(s=>{const r=s.getBoundingClientRect();return [...s.querySelectorAll('.mode-choices,.dialog,.loop-choice')].filter(e=>{const b=e.getBoundingClientRect();return b.left<r.left-1||b.right>r.right+1||b.bottom>r.bottom+1;}).length;});assert.equal(outside,0,review+' stays within the appliance canvas');
   await p.locator('#screen').screenshot({path:dir+'/'+kind+'-'+review+'.png'});
  }
  assert.deepEqual(errors,[]);fs.writeFileSync(dir+'/'+kind+'-verification.json',JSON.stringify({browser:kind,checks:['empty and recorded length compatibility','primary and exact beat relationships','touch and encoder commit','playing confirmation and cancellation','capture recheck and queued guard','no content or assignment mutations','ordinary Settings path','storage failure rollback and reload','1920 × 1080 geometry'],errors},null,2)+'\n');
  console.log(kind+': mode compatibility, confirmation, cancellation, encoder, recording guard, persistence and visual bounds passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
