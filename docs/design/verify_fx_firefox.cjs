// Author-side Firefox verification for the standalone FX interaction study.
const {firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
(async()=>{
 const browser=await firefox.launch({headless:true});
 const errors=[];
 const previews=path.join(__dirname,'fx-ux-previews');
 const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
 try{
  const page=await browser.newPage({viewport:{width:1920,height:1080}});
  page.on('pageerror',e=>errors.push(e.message));
  const click=action=>page.locator('[data-action='+JSON.stringify(action)+']').click();
  const snap=()=>page.evaluate(()=>segnoDemo.snapshot());
  for(const review of ['pedal-chain','single-delay','long-tracks','many-inputs','parameter-scroll','add-effects','add-effect']){
   await page.setViewportSize({width:1920,height:1080});
   await page.goto(base+'?review='+review);
   await page.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode()));});
   assert.equal(await page.locator('#screen').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(17, 18, 21)','theme background loads');
   if(review==='pedal-chain'){
    const range=page.locator('[data-action="inline:0:0"]');
    const css=await range.evaluate(e=>{const s=getComputedStyle(e),thumb=getComputedStyle(e,'::-moz-range-thumb');return {height:s.height,edge:thumb.backgroundColor,width:thumb.width};});
    assert.deepEqual(css,{height:'56px',edge:'rgb(186, 204, 230)',width:'2px'},'Firefox uses the filled slate-blue slider');
    assert.equal(await page.evaluate(()=>document.fonts.check('18px SegnoMono')),true,'local design-system font loads');
    const original=(await snap()).rig.racks[3].modules[0].params[0][1];
    const box=await range.boundingBox();
    await page.mouse.click(box.x+box.width*.8,box.y+box.height/2);
    assert.ok((await snap()).rig.racks[3].modules[0].params[0][1]>.7,'pointer changes native Firefox range');
    await page.waitForTimeout(320);await range.dblclick();
    assert.equal((await snap()).rig.racks[3].modules[0].params[0][1],original,'double click restores exact baseline');
    await range.focus();await page.keyboard.press('Enter');await page.keyboard.press('ArrowRight');await page.keyboard.press('Escape');
    assert.equal((await snap()).rig.racks[3].modules[0].params[0][1],original,'encoder cancellation works in Firefox');
    await click('channel-input');await click('choose-channel-input:right');await click('channel-output:mono');
    assert.equal((await snap()).rig.channels['rack-4'].input,'right');
    assert.equal(await page.locator('[data-action="inline:-1:0"]').getAttribute('aria-label'),'Rack Pan');
    await page.goto(base+'?review=pedal-chain');await page.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode()));});
   }else if(review==='single-delay'){
    assert.equal(await page.locator('.single-effect-body').count(),1);assert.equal(await page.locator('.pedal-column').count(),0);assert.equal(await page.locator('[data-action="channel-input"]').getAttribute('aria-label'),'Effect input: Stereo');
   }else if(review==='long-tracks'){
    assert.equal(await page.locator('.source-card').count(),9);
    assert.ok(await page.locator('.source-grid').evaluate(e=>{const a=e.firstElementChild.getBoundingClientRect(),b=e.lastElementChild.getBoundingClientRect(),t=document.querySelector('.titlebar').getBoundingClientRect();return Math.abs(a.left-t.left)<1&&Math.abs(b.right-t.right)<1;}),'track row aligns with both content edges');
   }else if(review==='add-effect'||review==='add-effects'){
    assert.equal(await page.locator('.subtitle').count(),0,'library title has no duplicate source');assert.equal(await page.locator('.dialog').count(),0,'adding uses a full page');if(review==='add-effect')assert.equal(await page.locator('.effect-card').count(),26);else assert.equal(await page.locator('.catalog-grid .catalog-card').count(),10);
   }else if(review==='parameter-scroll'){
    const panel=page.locator('[data-parameters="4"]'),fields=panel.locator('.inline-fields'),bar=panel.locator('.parameter-scrollbar');assert.ok(await bar.isVisible(),'persistent scrollbar is visible in Firefox');const r=await bar.boundingBox();await bar.click({position:{x:r.width/2,y:r.height-4}});assert.ok(await fields.evaluate(e=>e.scrollTop)>100,'scrollbar reaches lower parameters in Firefox');assert.ok(await bar.isVisible(),'scrollbar remains visible at the end');assert.equal(await page.locator('.chain-scroll').evaluate(e=>e.scrollLeft),0,'vertical scroll remains within pedal');await page.goto(base+'?review=parameter-scroll');
   }else{
    await page.locator('.source-strip').hover();await page.mouse.wheel(600,0);await page.waitForTimeout(100);
    assert.ok(await page.locator('.source-strip').evaluate(e=>e.scrollLeft)>0,'Firefox source strip scrolls horizontally');
    await page.goto(base+'?review=many-inputs');await page.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode()));});
   }
   await page.locator('#screen').screenshot({path:path.join(previews,'firefox-'+review+'.png')});
  }
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(previews,'firefox-verification.json'),JSON.stringify({browser:'Firefox '+browser.version(),checks:['per-pedal hidden-parameter cues and vertical scrolling','theme and local fonts','filled slate-blue sliders','pointer editing','exact double-click reset','encoder cancellation','channel selection and pan','aligned track edges','horizontal source scrolling'],errors},null,2)+'\n');
  console.log('Firefox theme, gestures, channel controls and 7 preview captures passed.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
