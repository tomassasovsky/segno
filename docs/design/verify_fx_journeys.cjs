// Author-side UX study checks. These do not exercise audio processing.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.ATLAS_CHROME?{executablePath:process.env.ATLAS_CHROME}:{})});
 try {
  const page=await browser.newPage({viewport:{width:1920,height:1080},hasTouch:true});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
  const click=id=>page.locator('[data-action='+JSON.stringify(id)+']').click();
  const snap=()=>page.evaluate(()=>segnoDemo.snapshot());
  await page.goto(base+'?review=pedal-chain');
  const initial=(await snap()).rig.racks[3];
  await click('save-rack');await click('cancel-modal');assert.equal((await snap()).rig.saved.length,0);
  await click('save-rack');await click('key:clear');assert.equal(await page.locator('[data-action="preset-save"]').isDisabled(),true);
  for(const c of 'WARM DELAY')await click('key:'+(c===' '?'space':c));
  await click('preset-save');let s=await snap();assert.equal(s.rig.saved[0].name,'WARM DELAY');assert.equal(s.rig.racks[3].name,initial.name,'preset naming does not rename the instance');
  await click('save-rack');await click('key:clear');for(const c of 'WARM DELAY')await click('key:'+(c===' '?'space':c));await click('preset-save');
  assert.equal((await snap()).modal.type,'preset-exists');await click('cancel-modal');assert.equal((await snap()).rig.saved.length,1,'collision cancellation preserves existing preset');
  await click('save-rack');await click('key:clear');for(const c of 'WARM DELAY')await click('key:'+(c===' '?'space':c));await click('preset-save');await click('preset-other-name');await click('key:X');await click('preset-save');assert.equal((await snap()).rig.saved.length,2);
  await click('back');await click('sound:Vocal');await click('add');await click('saved');await click('fxpresets:load:0');s=await snap();const loaded=s.rig.racks.at(-1);assert.equal(s.page,'chain');assert.equal(loaded.source,'Vocal');assert.ok(loaded.bypass);assert.deepEqual(loaded.rule,{pedal:null,condition:'always'},'a sound preset does not copy another input pedal assignment');assert.deepEqual(loaded.modules.map(m=>m.params.map(p=>p[1])),initial.modules.map(m=>m.params.map(p=>p[1])));
  const editable=page.locator('input[data-action^="inline:"]').first(),oldValue=Number(await editable.inputValue());await editable.focus();await page.evaluate(delta=>{segnoDemo.press();segnoDemo.turn(delta);segnoDemo.press();},oldValue>.5?-8:8);assert.notEqual(Number(await page.locator('input[data-action^="inline:"]').first().inputValue()),oldValue,'an editable parameter changes');assert.deepEqual((await snap()).rig.saved[0].modules,initial.modules,'editing the new instance cannot rewrite saved definition');
  await click('save-rack');await click('preset-save');assert.equal((await snap()).modal.type,'preset-exists');await click('preset-replace');s=await snap();assert.equal(s.rig.saved.length,2);assert.deepEqual(s.rig.saved[0].modules,s.rig.racks.at(-1).modules);assert.deepEqual(s.rig.racks[3].modules,initial.modules,'replacing preset cannot change other instances');
  await click('back');assert.equal((await snap()).page,'sounds','one Back returns to the destination');assert.equal((await snap()).source,'Vocal');
  await click('add');await click('single');await page.getByRole('button',{name:'Delay',exact:true}).click();assert.equal((await snap()).page,'chain');assert.equal(await page.locator('.single-effect-body').count(),1);await click('back');assert.equal((await snap()).source,'Vocal');
  await page.goto(base+'?review=pedal-chain');await click('rack-options');await click('order-modules');
  const before=(await snap()).rig.racks[3];const originalOrder=(await snap()).orderDraft.items;
  await click('order-select:0');await page.evaluate(()=>segnoDemo.turn(2));s=await snap();assert.equal(s.orderDraft.items[2],'0');assert.deepEqual(s.rig.racks[3],before,'reorder remains a draft');
  await page.evaluate(()=>{segnoDemo.pedalDown(0);segnoDemo.pedalUp(0);});assert.deepEqual((await snap()).rig.racks[3].modules,before.modules,'pedal event does not commit order draft');
  await page.keyboard.press('Escape');assert.deepEqual((await snap()).rig.racks[3].modules,before.modules,'Back cancels order');
  await click('rack-options');await click('order-modules');await click('order-select:0');await page.evaluate(()=>{segnoDemo.turn(2);segnoDemo.press();});assert.equal((await snap()).orderDraft.moving,false,'encoder press drops the moving card');await click('order-done');s=await snap();assert.equal(s.page,'chain');assert.deepEqual(s.rig.racks[3].modules[2],before.modules[0]);assert.equal(s.rig.racks[3].modules.at(-1).name,'Master','output level remains after all effects');assert.deepEqual(s.rig.racks[3].rule,before.rule);
  await click('back');await click('order-racks');const rackOrder=(await snap()).orderDraft.items;await click('order-move:1');await click('order-cancel');assert.deepEqual((await snap()).rig.racks.filter(r=>r.source==='Guitar').map(r=>r.id),rackOrder);
  await click('order-racks');await click('order-move:1');await click('order-done');assert.equal((await snap()).rig.racks.filter(r=>r.source==='Guitar')[1].id,rackOrder[0]);
  await click('order-racks');const cards=page.locator('.order-card'),grip=await cards.first().locator('.drag-grip').boundingBox(),target=await cards.nth(2).boundingBox();const dragKey=(await snap()).orderDraft.items[0];
  const cdp=await page.context().newCDPSession(page);await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:grip.x+grip.width/2,y:grip.y+grip.height/2}]});await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:target.x+target.width/2,y:grip.y+grip.height/2}]});await page.waitForTimeout(120);await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});assert.equal((await snap()).orderDraft.items[2],dragKey,'touch drag moves the chosen card');await click('order-cancel');
  await page.goto(base+'?review=pedal-chain');await click('rack-options');await click('remove-module');await click('pick-remove-module:0');await click('cancel-modal');assert.equal((await snap()).rig.racks[3].modules.length,initial.modules.length);await click('rack-options');await click('remove-module');await click('pick-remove-module:0');await click('remove-module-confirmed');assert.equal((await snap()).page,'chain');assert.equal((await snap()).rig.racks[3].modules.length,initial.modules.length-1);
  await click('save-rack');await click('preset-save');await click('rack-options');await click('remove');await click('remove-confirmed');s=await snap();assert.equal(s.page,'sounds');assert.equal(s.rig.saved.length,1);assert.ok(!s.rig.racks.some(r=>r.id===initial.id));
  assert.deepEqual(errors,[]);console.log('FX add, edit, reorder, save, replace, reuse and removal journeys passed.');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
