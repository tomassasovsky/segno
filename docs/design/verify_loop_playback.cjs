// Author-side checks of the target UX, not audio-engine integration.
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
  const decay=page.locator('[data-action="loop:decay"]');
  const edit=async delta=>{await decay.focus();await page.evaluate(d=>{segnoDemo.press();segnoDemo.turn(d);},delta);};
  const setDecay=async value=>decay.fill(String(value));
  await page.goto(base+'?review=loop-playback-default');
  assert.equal((await snap()).loopView.target,'Track 3');
  assert.deepEqual((await snap()).loopView.playback,{once:false,decay:0});
  const fx=(await snap()).rig.racks;
  await click('loop:once:false');
  assert.deepEqual((await snap()).loopSettings.trackPlayback['Track 3'],{once:false},'matching default is still an explicit override');
  await click('loop:scope:defaults');await click('loop:once:true');await setDecay(20);
  await click('loop:scope:Track 3');
  assert.deepEqual((await snap()).loopView.playback,{once:false,decay:20},'inheritance is independent for each field');
  await click('loop:playback-inherit:once');assert.equal((await snap()).loopView.playback.once,true);
  await edit(15);assert.equal((await snap()).loopView.playback.decay,35);
  assert.equal(await decay.evaluate(e=>e.classList.contains('editing')),true,'encoder editing is visible');
  await page.keyboard.press('Escape');assert.equal((await snap()).loopView.playback.decay,20);assert.equal((await snap()).loopView.playbackOrigins.decay,'Default');
  await edit(15);await click('loop:scope:Track 4');await click('loop:scope:Track 3');assert.equal((await snap()).loopView.playbackOrigins.decay,'Default','scope switch cancels the previous track draft');
  await edit(80);await page.evaluate(()=>segnoDemo.press());assert.equal((await snap()).loopView.playback.decay,100);
  await decay.dblclick();assert.equal((await snap()).loopView.playback.decay,20,'double tap restores track inheritance');
  await setDecay(0);assert.equal((await snap()).loopView.playbackOrigins.decay,'Custom');
  assert.match(await page.locator('[data-decay-note]').innerText(),/full volume/);
  await setDecay(100);assert.match(await page.locator('[data-decay-note]').innerText(),/replaces earlier audio/);
  await click('loop:scope:Track 8');assert.equal((await snap()).loopView.playback.decay,20,'track edits do not affect another track');
  await click('loop:scope:defaults');await decay.dblclick();assert.equal((await snap()).loopView.playback.decay,0,'default reset is no decay');
  for(const mode of ['multi','sync','song','band','free']){
   await click('back');await click('loop:page:loop-mode');await click('loop:mode:'+mode);await click('back');await click('loop:page:loop-playback');
   await click('loop:once:false');await click('loop:once:true');await setDecay(25);
   assert.deepEqual((await snap()).loopView.playback,{once:true,decay:25},mode+' permits the target controls');
  }
  await page.evaluate(()=>segnoDemo.setCapture('Track 1','overdubbing'));
  await click('loop:once:false');await setDecay(40);assert.deepEqual((await snap()).loopView.playback,{once:false,decay:40},'settings remain available during overdub');
  await page.evaluate(()=>segnoDemo.setCapture('Track 1','idle'));
  assert.deepEqual((await snap()).rig.racks,fx,'playback setup never mutates FX');
  // Pedal-triggered saves exclude encoder drafts; committed state survives reload.
  await page.goto(base);await page.evaluate(()=>localStorage.clear());await page.reload();await click('back');await click('loop:page:loop-settings');await click('loop:page:loop-playback');await click('loop:scope:Track 3');
  await edit(30);await page.evaluate(()=>{segnoDemo.pedalDown(0);segnoDemo.pedalUp(0);});
  const saved=await page.evaluate(()=>Object.values(localStorage).map(s=>{try{return JSON.parse(s)}catch{return null}}).find(s=>s?.loopSettings));
  assert.equal(saved.loopSettings.trackPlayback?.['Track 3']?.decay,undefined);
  await page.keyboard.press('Escape');await click('loop:once:true');await setDecay(25);
  await page.reload();await click('back');await click('loop:page:loop-settings');await click('loop:page:loop-playback');await click('loop:scope:Track 3');
  assert.deepEqual((await snap()).loopView.playback,{once:true,decay:25});
  const reviews=['loop-settings','loop-playback','loop-playback-default','loop-playback-custom'];
  for(const review of reviews){
   await page.goto(base+'?review='+review);await page.evaluate(()=>document.fonts.ready);
   const geometry=await page.locator('#screen').evaluate(root=>{
    const r=root.getBoundingClientRect();
    const controls=[...root.querySelectorAll('button,input')].filter(e=>e.getBoundingClientRect().width);
    return {width:root.offsetWidth,height:root.offsetHeight,small:controls.filter(e=>e.offsetWidth<56||e.offsetHeight<56).map(e=>e.dataset.action),outside:controls.filter(e=>{const b=e.getBoundingClientRect();return b.left<r.left||b.right>r.right+1||b.bottom>r.bottom+1;}).map(e=>e.dataset.action)};
   });
   assert.deepEqual(geometry,{width:1920,height:1080,small:[],outside:[]},review);
   if(review!=='loop-settings'){
    const edges=await page.locator('.main').evaluate(main=>['.scope-defaults','.playback-choices','.decay-controls'].map(s=>Math.round(main.querySelector(s).getBoundingClientRect().left)));
    assert.deepEqual(edges,[edges[0],edges[0],edges[0]],'selector and both setting rows align');
    assert.equal(await page.locator('.length-scopes button').count(),9);
    // Traverse every encoder stop; hidden recovery actions must not be selected.
    await page.evaluate(()=>segnoDemo.turn(-100));
    for(let i=0;i<25;i++){await page.evaluate(()=>segnoDemo.turn(1));assert.equal(await page.locator('.focus').evaluate(e=>e.getBoundingClientRect().width>0),true);}
   }
   await page.locator('#screen').screenshot({path:path.join(__dirname,'fx-ux-previews',(process.env.FX_BROWSER==='firefox'?'firefox-':'')+review+'.png')});
  }
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(__dirname,'fx-ux-previews',(process.env.FX_BROWSER==='firefox'?'firefox-':'')+'loop-playback-verification.json'),JSON.stringify({checks:['per-field defaults and overrides','Loop/Once selectable in all five modes','live overdub edits','direct touch and encoder editing','encoder cancellation preserves inheritance','double tap restores default ownership','scope-switch draft cancellation','decay endpoints and bounds','pedal saves exclude drafts','committed state survives reload','FX isolation','visible encoder stops only','all eight tracks visible; 1920x1080 canvas and aligned rows'],errors,engineValidation:false,physicalValidation:false},null,2)+'\n');
  console.log('Playback and overdub target UX checks passed.');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
