// Author checks of target configuration UX. No time-stretch DSP is run here.
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
  await page.goto(base+'?review=loop-audio-tempo-midi');
  const fx=(await snap()).rig.racks;
  assert.deepEqual((await snap()).loopView.audioTempo,{follow:true,keepPitch:true});
  await click('loop:audio-tempo:keepPitch:false');
  assert.equal((await snap()).loopView.effectivePitch,'follows-speed');
  await click('loop:audio-tempo:follow:false');
  assert.deepEqual((await snap()).loopView.audioTempo,{follow:false,keepPitch:false},'pitch preference is retained');
  assert.equal((await snap()).loopView.effectivePitch,'unchanged','original speed keeps original pitch even with another stored preference');
  assert.equal(await page.locator('[data-action^="loop:audio-tempo:keepPitch:"]').count(),0,'irrelevant pitch controls do not become dead encoder stops');
  assert.equal(await page.locator('.original-pitch').innerText(),'Unchanged');
  await click('loop:audio-tempo:follow:true');assert.equal((await snap()).loopView.effectivePitch,'follows-speed');
  await click('loop:audio-tempo-inherit:keepPitch');assert.equal((await snap()).loopView.audioTempoOrigins.keepPitch,'Default');assert.equal((await snap()).focusId,'loop:audio-tempo:keepPitch:true');
  await click('loop:audio-tempo:keepPitch:true');assert.equal((await snap()).loopView.audioTempoOrigins.keepPitch,'Custom','matching value is an intentional override');
  await click('loop:scope:defaults');await click('loop:audio-tempo:keepPitch:false');await click('loop:audio-tempo:follow:false');
  await click('loop:scope:Track 3');assert.deepEqual((await snap()).loopView.audioTempo,{follow:true,keepPitch:true},'track overrides remain independent from default changes');
  await click('loop:audio-tempo-inherit:follow');assert.equal((await snap()).loopView.audioTempo.follow,false);assert.equal((await snap()).focusId,'loop:audio-tempo:follow:false');
  await click('loop:scope:Track 8');assert.deepEqual((await snap()).loopView.audioTempo,{follow:false,keepPitch:false},'another track follows both defaults');
  await click('loop:scope:defaults');await click('loop:audio-tempo:follow:true');await click('loop:scope:Track 8');assert.equal((await snap()).loopView.effectivePitch,'follows-speed');
  // All five modes can configure this target behavior; current DSP limits do not gate the UI.
  for(const mode of ['multi','sync','song','band','free']){
   await click('back');await click('loop:page:loop-mode');await click('loop:mode:'+mode);await click('back');await click('loop:page:loop-audio-tempo');
   await click('loop:audio-tempo:follow:false');await click('loop:audio-tempo:follow:true');await click('loop:audio-tempo:keepPitch:true');assert.equal((await snap()).loopView.effectivePitch,'unchanged');
  }
  await page.evaluate(()=>segnoDemo.setCapture('Track 1','overdubbing'));await click('loop:audio-tempo:keepPitch:false');assert.equal((await snap()).loopView.effectivePitch,'follows-speed');
  await page.evaluate(()=>segnoDemo.setCapture('Track 1','idle'));assert.deepEqual((await snap()).rig.racks,fx,'audio-tempo choices do not modify FX');
  // Touch and encoder reach the same choice; an immediate choice is a committed setting.
  await page.locator('[data-action="loop:audio-tempo:keepPitch:true"]').focus();await page.evaluate(()=>segnoDemo.press());assert.equal((await snap()).loopView.effectivePitch,'unchanged');
  await page.goto(base);await page.evaluate(()=>localStorage.clear());await page.reload();await click('back');await click('loop:page:loop-settings');await click('loop:page:loop-audio-tempo');await click('loop:scope:Track 3');await click('loop:audio-tempo:keepPitch:false');
  await page.reload();await click('back');await click('loop:page:loop-settings');await click('loop:page:loop-audio-tempo');await click('loop:scope:Track 3');assert.deepEqual((await snap()).loopSettings.trackAudioTempo['Track 3'],{keepPitch:false});
  // Tempo edits share the existing tempo page and return path; no duplicate BPM editor.
  await click('back');await click('loop:page:loop-timing');await page.locator('[data-action="loop:tempo"]').fill('100');await click('back');await click('loop:page:loop-audio-tempo');
  assert.equal((await snap()).loopSettings.tempo,100);assert.deepEqual((await snap()).loopView.audioTempo,{follow:true,keepPitch:false});assert.equal((await snap()).loopView.target,'Track 3');
  for(const review of ['loop-settings','loop-audio-tempo','loop-audio-tempo-pitch','loop-audio-tempo-original','loop-audio-tempo-midi']){
   await page.goto(base+'?review='+review);await page.evaluate(()=>document.fonts.ready);
   const geometry=await page.locator('#screen').evaluate(root=>{
    const r=root.getBoundingClientRect(),controls=[...root.querySelectorAll('button,input')].filter(e=>e.getBoundingClientRect().width);
    return {width:root.offsetWidth,height:root.offsetHeight,small:controls.filter(e=>e.offsetWidth<56||e.offsetHeight<56).map(e=>e.dataset.action),outside:controls.filter(e=>{const b=e.getBoundingClientRect();return b.left<r.left||b.right>r.right+1||b.bottom>r.bottom+1;}).map(e=>e.dataset.action)};
   });
   assert.deepEqual(geometry,{width:1920,height:1080,small:[],outside:[]},review);
   if(review!=='loop-settings'){
    assert.equal(await page.locator('.length-scopes button').count(),9);
    const edges=await page.locator('.main').evaluate(main=>['.scope-defaults','.audio-tempo-choices','.pitch-choices,.original-pitch'].map(s=>Math.round(main.querySelector(s).getBoundingClientRect().left)));
    assert.deepEqual(edges,[edges[0],edges[0],edges[0]]);
    await page.evaluate(()=>segnoDemo.turn(-100));for(let i=0;i<25;i++){await page.evaluate(()=>segnoDemo.turn(1));assert.equal(await page.locator('.focus').evaluate(e=>e.getBoundingClientRect().width>0),true);}
   }
   await page.locator('#screen').screenshot({path:path.join(__dirname,'fx-ux-previews',(process.env.FX_BROWSER==='firefox'?'firefox-':'')+review+'.png')});
  }
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(__dirname,'fx-ux-previews',(process.env.FX_BROWSER==='firefox'?'firefox-':'')+'loop-audio-tempo-verification.json'),JSON.stringify({checks:['independent per-field defaults and overrides','pitch choice retained while original speed determines effective pitch','MIDI permits tempo-follow opt-out','all five modes and overdub edits','touch and encoder choices agree','reset returns focus to the effective choice','committed state survives reload','same tempo editor and target remembered','FX isolation','eight visible tracks and aligned controls','1920x1080 geometry and minimum targets'],errors,engineValidation:false,physicalValidation:false},null,2)+'\n');
  console.log('Audio tempo and pitch target UX checks passed.');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
