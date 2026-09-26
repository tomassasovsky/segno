// Author-side browser simulation, not a physical jack/firmware check.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await (kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}: {})});
 try{
  const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const base='http://127.0.0.1:8768/fx-ux-prototype.html';
  const button=id=>page.locator('[data-action='+JSON.stringify('expr:'+id)+']');
  const click=async id=>{if(id.startsWith('switch:choose:')){const key=id.slice(14),group=key.startsWith('track:')?'tracks':key.startsWith('fx:')?'fx':'functions';await button('switch:action-group:'+group).click();}await button(id).click();};
  const snap=()=>page.evaluate(()=>segnoDemo.snapshot());
  const input=(p,i,down)=>page.evaluate(args=>segnoDemo.externalSwitchInput(...args),[p,i,down]);
  const tap=async(p,i)=>{await input(p,i,true);await input(p,i,false);};
  await page.goto(base+'?review=external-dual&canvas=actual');
  await input(0,0,true);assert.equal((await snap()).performance.view,'tracks','press waits when hold is assigned');
  await page.waitForTimeout(850);assert.equal((await snap()).performance.view,'custom');await input(0,0,false);assert.equal((await snap()).performance.view,'custom','release cannot trigger press after hold');
  await tap(0,0);assert.equal((await snap()).performance.view,'mute','short press runs press action');
  await input(0,1,true);assert.equal((await snap()).held[0],true);assert.equal((await snap()).rig.latched[0],true);await input(0,1,false);assert.equal((await snap()).held[0],false,'momentary FX release reaches original assignment');
  await click('switch:select:1');await click('switch:edit:press');await click('switch:choose:bank:next');assert.equal((await snap()).expression.saved.ports[0].switches[1].press,'fx:0');await click('cancel');assert.equal((await snap()).expression.draft.ports[0].switches[1].press,'fx:0');
  await click('type:single');await click('save');let prior=(await snap()).rig.latched[0];await tap(0,1);assert.equal((await snap()).rig.latched[0],prior,'single input ignores second contact');
  await click('type:expression');await click('cancel');assert.equal((await snap()).expression.draft.ports[0].type,'single');
  // Both ports can own different types and independent switch assignments.
  await click('port:1');await click('type:single');await click('switch:edit:press');await click('switch:choose:bank:next');await click('save');await page.evaluate(()=>segnoDemo.expressionConnect(1,true));let bank=(await snap()).bank;await tap(1,0);assert.equal((await snap()).bank,1-bank);
  await click('switch:hardware:latching');assert.equal(await button('switch:edit:hold').count(),0);await click('switch:edit:change');await click('switch:choose:bank:next');await click('save');bank=(await snap()).bank;await input(1,0,true);assert.equal((await snap()).bank,1-bank);await input(1,0,true);assert.equal((await snap()).bank,1-bank,'duplicate contact ignored');await input(1,0,false);assert.equal((await snap()).bank,bank,'each latching change fires once');
  // Disconnect/Save must consume a pending gesture, never emit a delayed action.
  await click('port:0');await click('switch:edit:press');await click('switch:choose:bank:next');await click('switch:edit:hold');await click('switch:choose:mode:fx');await click('save');bank=(await snap()).bank;const view=(await snap()).performance.view;
  await input(0,0,true);await page.evaluate(()=>segnoDemo.expressionConnect(0,false));await page.waitForTimeout(850);assert.equal((await snap()).performance.view,view);assert.equal((await snap()).bank,bank);await page.evaluate(()=>segnoDemo.expressionConnect(0,true));await input(0,0,false);assert.equal((await snap()).bank,bank,'reconnect release is consumed');await tap(0,0);assert.equal((await snap()).bank,1-bank);
  bank=(await snap()).bank;await input(0,0,true);await click('save');await input(0,0,false);assert.equal((await snap()).bank,bank,'saving during pending hold consumes release');
  // Encoder can navigate choices, Back closes the picker, and save survives reload.
  await click('switch:edit:press');await page.keyboard.press('Escape');assert.equal((await snap()).expression.switches.picker,null);
  await button('switch:edit:press').focus();await page.evaluate(()=>segnoDemo.press());await page.evaluate(()=>segnoDemo.turn(1));await page.evaluate(()=>segnoDemo.press());assert.equal((await snap()).expression.switches.picker,null);
  await page.goto(base+'?canvas=actual');await page.evaluate(()=>localStorage.clear());await page.reload();await page.locator('[data-action="back"]').click();await page.locator('[data-action="pedal-setup"]').click();await page.locator('[data-action="expression"]').click();await click('type:dual');await click('switch:edit:press');await click('switch:choose:mode:fx');await click('save');const saved=(await snap()).expression.saved;await click('type:single');await page.reload();assert.deepEqual((await snap()).expression.saved,saved);
  await page.goto(base+'?review=external-tracks&canvas=actual');assert.equal((await snap()).bank,0);await tap(0,0);assert.equal((await snap()).rig.lastTrackPedalEvent.track,'Track 5');await tap(0,1);assert.equal((await snap()).rig.lastTrackPedalEvent.track,'Track 6');await page.locator('[data-action="stage"]').click();await page.locator('[data-action="perform:9"]').click();assert.equal((await snap()).bank,1);await tap(0,0);assert.equal((await snap()).rig.lastTrackPedalEvent.track,'Track 5','absolute target survives bank switch');await tap(0,1);assert.equal((await snap()).rig.lastTrackPedalEvent.track,'Track 6');
  // External button states are direct FX sources, independent of the eight FX slots.
  await page.goto(base+'?review=external-fx-states&canvas=actual');
  const four=async()=>{const s=await snap();return [1,2,3,4].map(i=>s.effective['rack-'+i]);};
  assert.deepEqual(await four(),[false,true,false,true]);await input(0,0,true);assert.deepEqual(await four(),[true,false,true,false]);await input(0,0,false);assert.deepEqual(await four(),[true,false,false,true]);await input(0,0,true);assert.deepEqual(await four(),[false,true,true,false]);await input(0,0,false);assert.deepEqual(await four(),[false,true,false,true]);
  assert.deepEqual((await snap()).rig.latched,Array(8).fill(false),'external states do not borrow built-in FX slots');
  await click('switch:select:1');await click('switch:add-control');await click('switch:control-destination:Guitar');await click('switch:add-target:rack-1');await click('switch:state:held');await click('save');assert.deepEqual((await snap()).rig.racks[0].rule,{pedal:'external:0:1',condition:'held'});await input(0,1,true);assert.equal((await snap()).effective['rack-1'],true);await page.evaluate(()=>segnoDemo.expressionConnect(0,false));assert.equal((await snap()).effective['rack-1'],false,'disconnect releases momentary source');
  // Save external state and restore without a press or unintended retargeting.
  await page.goto(base+'?canvas=actual');await page.evaluate(()=>localStorage.clear());await page.reload();await page.locator('[data-action="back"]').click();await page.locator('[data-action="pedal-setup"]').click();await page.locator('[data-action="expression"]').click();await click('type:dual');await click('save');await page.locator('[data-action="stage"]').click();await page.locator('[data-action="settings"]').click();await page.locator('[data-action="effects"]').click();await page.locator('[data-action="rack:rack-1"]').click();await page.locator('[data-action="activation"]').click();assert.equal(await page.locator('[data-action^="pick:external:"]').count(),0);await page.locator('[data-action="stage"]').click();await page.locator('[data-action="settings"]').click();await page.locator('[data-action="pedal-setup"]').click();await page.locator('[data-action="expression"]').click();await click('switch:panel:controls');await click('switch:add-control');await click('switch:control-destination:Guitar');await click('switch:add-target:rack-1');await click('switch:state:on');await click('save');await tap(0,0);assert.equal((await snap()).effective['rack-1'],true);await page.reload();assert.equal((await snap()).effective['rack-1'],true);assert.equal((await snap()).rig.racks[0].rule.pedal,'external:0:0');
  for(const review of ['external-fx-states','external-tracks','external-single','external-dual','external-latching']){
   await page.goto(base+'?review='+review+'&canvas=actual');
   const bad=await page.evaluate(()=>[...document.querySelectorAll('#screen button')].filter(el=>{const r=el.getBoundingClientRect();if(el.closest('.list'))return el.scrollWidth>el.clientWidth+2;return r.x<0||r.y<0||r.right>1921||r.bottom>1081||el.scrollWidth>el.clientWidth+2;}).map(el=>el.textContent));assert.deepEqual(bad,[]);
   if(kind==='chrome'){fs.mkdirSync('docs/design/expression-previews',{recursive:true});await page.locator('#screen').screenshot({path:'docs/design/expression-previews/'+review+'.png'});}
  }
  assert.deepEqual(errors,[]);console.log(kind+': external types, separate switches/ports, exclusive gestures, latch edges, cancellation, encoder, persistence and layout passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
