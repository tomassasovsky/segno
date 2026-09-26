// Silent browser interaction checks, not DSP or appliance validation.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await (kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const base='http://127.0.0.1:8768/fx-ux-prototype.html';
  const button=id=>page.locator('[data-action='+JSON.stringify(id)+']');
  const foot=id=>button('perform:'+id);
  const snap=()=>page.evaluate(()=>segnoDemo.snapshot());
  const pitch=async()=>(await snap()).performance.transpose;
  const hold=async id=>{if(await foot(id).count()){await foot(id).focus();await page.keyboard.down(' ');}else await page.evaluate(id=>segnoDemo.performanceDown(id,' '),id);await page.waitForTimeout(850);};
  await page.goto(base+'?review=performance-custom&canvas=actual');
  await hold(5);await page.keyboard.up(' ');assert.equal((await snap()).performance.view,'tuner','Tuner Hold enters Tuner and consumes the FX short press');await foot(3).click();assert.equal((await snap()).performance.view,'tracks','Tuner exits by foot');await hold(3);await page.keyboard.up(' ');assert.equal((await snap()).performance.view,'custom','Mode hold returns to Custom');
  await foot(4).click();assert.equal((await snap()).performance.view,'transpose');
  assert.deepEqual((await pitch()).selected,[0]);assert.equal(await foot(7).isDisabled(),true);
  await foot(5).click();await foot(8).click();assert.deepEqual((await pitch()).pitches.slice(0,3),[1,1,0]);
  await hold(2);assert.deepEqual((await pitch()).pitches.slice(0,3),[0,0,0]);await page.keyboard.up(' ');assert.deepEqual((await pitch()).pitches.slice(0,3),[0,0,0],'reset consumes the short press');
  await foot(2).focus();await page.keyboard.down(' ');await page.evaluate(()=>dispatchEvent(new Event('blur')));await page.keyboard.up(' ');assert.deepEqual((await pitch()).pitches.slice(0,3),[0,0,0],'cancelled gesture does nothing');
  await page.goto(base+'?review=performance-transpose&canvas=actual');
  await foot(5).click();await foot(8).click();assert.deepEqual((await pitch()).pitches.slice(0,3),[3,-2,0],'steps retain relative offsets');
  await foot(9).click();await foot(4).click();assert.deepEqual((await pitch()).selected,[0,1,4]);await foot(2).click();assert.deepEqual((await pitch()).pitches.slice(0,5),[2,-3,0,0,6]);
  await foot(9).click();assert.equal(await foot(4).locator('.pedal-led').getAttribute('data-state'),'active');assert.equal(await foot(5).locator('.pedal-led').getAttribute('data-state'),'active');
  await foot(3).click();assert.equal((await snap()).performance.view,'tracks');assert.equal((await pitch()).pitches[4],6,'Exit retains recorded pitch');
  await hold(3);await page.keyboard.up(' ');await foot(4).click();assert.equal((await snap()).performance.view,'transpose');
  assert.deepEqual((await pitch()).selected,[0],'entry starts with the current track');
  // A pitch press held across Exit cannot reset or step a different screen.
  await foot(8).focus();await page.keyboard.down(' ');await foot(3).click();await page.waitForTimeout(850);await page.keyboard.up(' ');assert.equal((await pitch()).pitches[0],2);assert.equal((await snap()).performance.view,'tracks');
  await page.goto(base+'?review=performance-transpose-empty&canvas=actual');assert.deepEqual((await pitch()).selected,[]);assert.equal(await foot(2).isDisabled(),true);assert.equal(await foot(8).isDisabled(),true);
  await foot(4).click();assert.equal(await foot(8).isEnabled(),true);
  await page.goto(base+'?review=performance-transpose-limit&canvas=actual');const before=(await pitch()).pitches;assert.equal((await pitch()).canUp,false);await foot(8).click();assert.deepEqual((await pitch()).pitches,before,'a group stops together at the limit');await foot(2).click();assert.equal((await pitch()).pitches[0],11);assert.equal((await pitch()).pitches[1],-4);
  await hold(8);await page.keyboard.up(' ');assert.deepEqual((await pitch()).pitches.slice(0,2),[0,0]);
  // Transport remains distinct from the transpose target selection.
  await page.evaluate(()=>{segnoDemo.setPlayback('Track 1',true);segnoDemo.setPlayback('Track 2',true);});await foot(1).click();assert.equal((await snap()).trackPlayback['Track 1'],false);assert.equal((await snap()).trackPlayback['Track 2'],false);await foot(0).click();assert.equal((await snap()).rig.lastTrackPedalEvent.track,'Track 1');
  // Normal prototype storage restores pitch independently of the interaction mode.
  await page.goto(base+'?canvas=actual');await page.evaluate(()=>localStorage.clear());await page.reload();assert.equal((await snap()).page,'stage','reload returns directly to Stage');await hold(3);await page.keyboard.up(' ');await foot(4).click();await foot(8).click();await foot(8).click();assert.equal((await pitch()).pitches[0],2);await page.reload();assert.equal((await pitch()).pitches[0],2);assert.equal((await snap()).performance.view,'tracks');
  for(const review of ['performance-transpose','performance-transpose-bank','performance-transpose-empty','performance-transpose-limit']){
   await page.goto(base+'?review='+review+'&canvas=actual');await page.evaluate(()=>document.fonts.ready);
   const bad=await page.evaluate(()=>[...document.querySelectorAll('#screen button,.transpose-overview')].filter(e=>{const r=e.getBoundingClientRect();return r.x<0||r.y<0||r.right>1921||r.bottom>1081||e.scrollWidth>e.clientWidth+2||e.scrollHeight>e.clientHeight+2;}).map(e=>e.textContent));assert.deepEqual(bad,[]);
   if(kind==='chrome'){fs.mkdirSync('docs/design/transpose-previews',{recursive:true});await page.locator('#screen').screenshot({path:'docs/design/transpose-previews/'+review+'.png'});}
  }
  assert.deepEqual(errors,[]);console.log(kind+': Transpose foot entry, multi-track selection, banks, relative steps, reset/Exit cancellation, limits, transport intents, persistence and layout passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
