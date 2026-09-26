// Author checks of placement and output UX, not DSP or audible tail validation.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await (process.env.FX_BROWSER==='firefox'?firefox:chromium).launch({headless:true,...(process.env.ATLAS_CHROME&&process.env.FX_BROWSER!=='firefox'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try {
  const page=await browser.newPage({viewport:{width:1920,height:1080},hasTouch:true});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
  const click=id=>page.locator('[data-action='+JSON.stringify(id)+']').click();
  const snap=()=>page.evaluate(()=>segnoDemo.snapshot());
  await page.goto(base+'?review=fx-pre-post&canvas=actual');
  const before=(await snap()).rig.racks;
  assert.deepEqual(await page.locator('.placement-tag').allTextContents(),['Pre','Pre','Pre','Post']);
  await click('rack:rack-4');
  await page.locator('[data-action="placement:pre"]').focus();await page.evaluate(()=>segnoDemo.press());
  let s=await snap(),r=s.rig.racks.find(r=>r.id==='rack-4');assert.equal(s.placements[r.id],'pre');assert.equal(s.focusId,'placement:pre');assert.deepEqual(r.modules,before[3].modules);assert.deepEqual(r.rule,before[3].rule);
  assert.equal(await page.locator('.dialog').count(),0,'placement is direct, without a popup');
  assert.equal(await page.locator('.placement-hint').textContent(),'Recorded into loop');
  await click('placement:post');assert.equal(await page.locator('.placement-hint').textContent(),'Can ring after Stop');await click('placement:pre');
  assert.deepEqual(s.rig.racks.filter(r=>r.source.startsWith('Track ')),before.filter(r=>r.source.startsWith('Track ')),'input placement does not rewrite existing takes');
  await click('back');await click('rack:rack-1');await click('placement:post');await click('back');
  assert.equal(await page.locator('.sound-rack').last().getAttribute('data-action'),'rack:rack-1','post follows pre regardless of old rack position');
  await click('order-racks');const order=(await snap()).orderDraft.items;await click('order-select:rack-1');
  assert.equal(await page.locator('[data-action="order-move:-1"]').isDisabled(),true,'reordering cannot turn a Post effect into Pre');
  await page.evaluate(()=>segnoDemo.turn(-3));assert.deepEqual((await snap()).orderDraft.items,order);
  await click('order-cancel');await click('kind:tracks');assert.equal(await page.locator('.source-card').count(),9);
  await click('sound-part');await click('part:Guitar');await click('rack:rack-13');await click('placement:pre');
  s=await snap();assert.equal(s.placements['rack-13'],'pre');assert.deepEqual(s.rig.racks.find(r=>r.id==='rack-14'),before[13],'another recorded input is isolated');
  await page.evaluate(()=>{segnoDemo.setPlayback('Track 1',true);segnoDemo.setPlayback('Track 1',false);});assert.equal((await snap()).placements['rack-13'],'pre','transport cannot alter placement');
  await click('back');await click('sound:All tracks');assert.match(await page.locator('.sound-context').textContent(),/combined loop audio/);await click('rack:rack-11');assert.equal(await page.locator('[data-action^="placement:"]').count(),0);assert.equal(await page.locator('.placement-block').count(),0,'fixed output placement has no redundant label');
  await click('back');await click('kind:outputs');assert.equal((await snap()).source,'Main output');assert.match(await page.locator('.sound-context').textContent(),/live inputs, tracks, click & backing/);assert.equal(await page.locator('[data-action^="monitor:"]').count(),0);assert.equal(await page.locator('.placement-tag').count(),0,'outputs omit placement tags');
  await click('rack:rack-15');assert.equal(await page.locator('.single-effect-body').count(),1);assert.ok((await snap()).rig.racks.find(r=>r.id==='rack-15').modules.length,'output has a real source-catalogue effect');assert.equal(await page.locator('[data-action^="placement:"]').count(),0);
  await click('save-rack');await click('preset-save');assert.equal((await snap()).rig.saved[0].placement,undefined,'sound preset does not carry routing placement');await click('back');await click('sound:Monitor output');assert.equal(await page.locator('.sound-rack').count(),0);
  await click('add');await click('saved');await click('user-preset:0');s=await snap();assert.equal(s.rig.racks.at(-1).source,'Monitor output');assert.equal(s.placements[s.rig.racks.at(-1).id],'post');assert.ok(s.rig.racks.at(-1).bypass);await click('back');assert.equal((await snap()).soundOutput,'Monitor output');
  await click('kind:live');await click('kind:outputs');assert.equal((await snap()).source,'Monitor output','tab remembers its output');
  assert.equal(await page.locator('.main [data-action*="playback"],.main [data-action*="transport"]').count(),0,'no transport controls added to FX');
  // Direct placement survives save/reload, with controls and other rack state intact.
  await page.goto(base);await page.evaluate(()=>localStorage.clear());await page.reload();await click('rack:rack-1');await click('placement:post');await page.evaluate(()=>{segnoDemo.pedalDown(0);segnoDemo.pedalUp(0);});await page.reload();assert.equal((await snap()).placements['rack-1'],'post');
  // Every reviewed canvas retains reachable controls and no horizontal footer overflow.
  for(const review of ['fx-pre-post','fx-placement','fx-post','outputs','output-reverb','output-monitor','single-delay','many-inputs','long-tracks']){
   await page.goto(base+'?review='+review+'&canvas=actual');await page.evaluate(()=>document.fonts.ready);
   const bad=await page.evaluate(()=>[...document.querySelectorAll('.rack-channels,.placement-options,.sound-context')].filter(e=>e.scrollWidth>e.clientWidth+2).map(e=>e.className));assert.deepEqual(bad,[],review+' fits');
   if(review==='many-inputs'){assert.equal(await page.locator('.source-card').count(),18);await click('scroll-sources:1');await page.waitForTimeout(400);assert.ok(await page.locator('.source-strip').evaluate(e=>e.scrollLeft)>0);}
  }
  assert.deepEqual(errors,[]);console.log('FX placement, stage order, recorded-part isolation, output journeys, persistence and layout passed. No DSP is exercised.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
