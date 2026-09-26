const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
(async()=>{
 for(const kind of ['Chrome','Firefox']){
  const browser=await(kind==='Chrome'?chromium:firefox).launch(kind==='Chrome'?{executablePath:process.env.ATLAS_CHROME}:{});
  try {
   const page=await browser.newPage({viewport:{width:1920,height:1080}});
   for(const scene of ['stage-layout','stage-layout-wave','stage-layout-mixer']){
    await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review='+scene+'&canvas=actual');
    await page.evaluate(()=>document.fonts.ready);
    assert.equal(await page.locator('[data-stage-primary]').count(),1);
    const primary=await page.locator('[data-stage-primary]').getAttribute('data-stage-primary');
    await page.locator('[data-action="stage-track:1"]').first().click();
    assert.equal(await page.locator('[data-stage-primary]').getAttribute('data-stage-primary'),primary,'Selection does not move the crown');
    if(scene==='stage-layout'){
     const levels=await page.locator('.stage-meter').evaluateAll(es=>es.map(e=>({width:e.clientWidth,fill:e.querySelector('.stage-meter-fill')?.getBoundingClientRect().width})));
     assert.equal(levels.length,4,'The active bank has four meter surfaces');
     assert(levels.some(e=>e.fill>0),'The populated fixture has a visible meter fill');
     assert(levels.filter(e=>e.fill).every(e=>Math.abs(e.width-e.fill)<2),'Tracks use one whole-width meter');
    }
   }
   await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review=timing-clock-loss&canvas=actual');
   await page.evaluate(()=>document.fonts.ready);
   const fit=await page.locator('.stage-feedback').evaluate(e=>{const b=e.getBoundingClientRect(),p=e.parentElement.getBoundingClientRect(),r=document.createRange();r.selectNodeContents(e.querySelector('strong'));return {text:e.textContent,inside:b.left>=p.left&&b.right<=p.right&&b.top>=p.top&&b.bottom<=p.bottom,textFits:[...r.getClientRects()].every(t=>t.left>=b.left&&t.right<=b.right),interactive:!!e.querySelector('button,input,[tabindex]')};});
   assert.match(fit.text,/Captured audio kept/);assert(fit.inside&&fit.textFits,'Recovery cue fits in its track');assert(!fit.interactive);
   await page.goto('http://127.0.0.1:8768/stage-two-screen-preview.html?review=stage-layout');
   await page.waitForFunction(()=>!document.querySelector('#track-primary').hidden);
   const frame=page.frames().find(f=>f.url().includes('fx-ux-prototype'));
   await frame.locator('[data-action="stage-track:1"]').click();
   await page.waitForFunction(()=>document.querySelector('#track-primary').hidden);
   console.log(kind+': crown ownership on selection, whole-track meter, readable recovery cue and selected-display crown passed');
  } finally {await browser.close();}
 }
})().catch(e=>{console.error(e);process.exitCode=1;});
