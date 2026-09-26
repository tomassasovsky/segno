// Author-side interaction checks; no audio engine or physical ADC is exercised.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{
for(const kind of ['chrome','firefox']){
 const browser=await (kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}:{})});
 try{
  const p=await browser.newPage({viewport:{width:1920,height:1080},hasTouch:true});const errors=[];p.on('pageerror',e=>errors.push(e.message));
  const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
  const button=id=>p.locator('[data-action='+JSON.stringify(id)+']');
  const click=id=>button(id).click();const snap=()=>p.evaluate(()=>segnoDemo.snapshot());
  const sweep=(port,value)=>p.evaluate(([port,value])=>segnoDemo.expressionInput(port,value),[port,value]);
  const slider=key=>p.locator('[data-action="expr:'+key+'"]');
  const change=async(key,value)=>{await slider(key).evaluate((el,value)=>{el.value=value;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));},String(value));};
  const targetValue=s=>{const m=s.expression.saved.ports[0].mappings[0];const [,rid,mid,param]=JSON.parse(m.target);return s.rig.racks.find(r=>r.id===rid).modules.find(m=>m.expressionId===mid).params.find(p=>p[0]===param)[1];};
  await p.goto(base+'?review=expression&canvas=actual');assert.equal(await p.locator('h1').textContent(),'External pedals');
  const original=(await snap()).expression.saved;await change('heel',.8);await change('toe',.2);assert.deepEqual((await snap()).expression.saved,original,'range edits are a draft');
  await sweep(0,0);assert.equal((await snap()).expression.values[0].value,.8,'reverse heel preview');assert.equal(targetValue(await snap()),0,'saved sweep is independent of pending range');
  await click('expr:save');await sweep(0,1);assert.ok(Math.abs(targetValue(await snap())-.2)<.001,'inverted toe applies to real rig parameter');
  await slider('heel').focus();await p.evaluate(()=>{segnoDemo.press();segnoDemo.turn(-20);});assert.equal((await snap()).expression.draft.ports[0].mappings[0].heel,.6);await p.keyboard.press('Escape');assert.equal((await snap()).expression.draft.ports[0].mappings[0].heel,.8,'encoder cancel restores opening value');
  await slider('heel').dblclick();assert.equal((await snap()).expression.draft.ports[0].mappings[0].heel,0,'double tap resets heel');await click('expr:cancel');assert.equal((await snap()).expression.draft.ports[0].mappings[0].heel,.8);
  await click('expr:add');await click('expr:destination:Guitar');const duplicate=p.locator('[data-action^="expr:target:"]').filter({hasText:'Delay · Mix'}).first();assert.equal(await duplicate.isDisabled(),true);
  await p.locator('[data-action^="expr:target:"]').filter({hasText:'Volume'}).first().click();assert.equal((await snap()).expression.draft.ports[0].mappings.length,2);await click('expr:save');await sweep(0,.75);assert.equal((await snap()).rig.expressionMix.Guitar.level,.75,'one sweep drives multiple targets');
  await click('expr:port:1');assert.equal((await snap()).expression.draft.ports[1].mappings.length,0);assert.equal(await button('expr:calibrate').isDisabled(),true);
  await p.evaluate(()=>segnoDemo.expressionConnect(1,true));await click('expr:calibrate');assert.equal(await button('expr:calibration-use').isDisabled(),true);
  await sweep(1,.3);await click('expr:capture:heel');await sweep(1,.32);await click('expr:capture:toe');assert.equal(await button('expr:calibration-use').isDisabled(),true,'jitter is not a valid calibration');
  await sweep(1,.9);await click('expr:capture:heel');await sweep(1,.1);await click('expr:capture:toe');await click('expr:calibration-use');assert.deepEqual((await snap()).expression.draft.ports[1].calibration,{heel:.9,toe:.1},'reversed pedal wiring calibrates');assert.equal((await snap()).expression.saved.ports[1].calibration,null,'calibration remains a draft');
  await click('expr:save');await sweep(1,.5);assert.equal((await snap()).expression.position,.5);
  await click('expr:add');await click('expr:kind:outputs');await click('expr:destination:Main%20output');await p.locator('[data-action^="expr:target:"]').filter({hasText:'Volume'}).first().click();await click('expr:save');await sweep(1,.3);assert.ok(Math.abs((await snap()).rig.expressionMix['Main output'].level-.75)<.001,'calibrated source reaches output target');
  await p.evaluate(()=>segnoDemo.expressionConnect(1,false));await sweep(1,.8);assert.ok(Math.abs((await snap()).rig.expressionMix['Main output'].level-.75)<.001,'disconnect retains controlled value');
  await click('expr:port:0');await click('expr:remove');await click('expr:cancel');assert.equal((await snap()).expression.draft.ports[0].mappings.length,2,'cancel restores removed mapping');
  await click('back');assert.equal((await snap()).page,'pedal-setup');
  // Durable save, parameter identity after reorder, and unavailable-target recovery.
  await p.goto(base+'?canvas=actual');await p.evaluate(()=>localStorage.clear());await p.reload();await click('settings');await click('pedal-setup');await click('expression');
  await click('expr:calibrate');await sweep(0,0);await click('expr:capture:heel');await sweep(0,1);await click('expr:capture:toe');await click('expr:calibration-use');
  await click('expr:add');await click('expr:destination:Guitar');await p.locator('[data-action^="expr:target:"]').filter({hasText:'Delay · Mix'}).first().click();await change('toe',.7);await click('expr:save');const committed=(await snap()).expression.saved;
  await change('toe',.4);await p.evaluate(()=>{segnoDemo.pedalDown(0);segnoDemo.pedalUp(0);});await p.reload();assert.deepEqual((await snap()).expression.saved,committed,'unrelated saves exclude expression drafts');
  await click('settings');await click('effects');await click('rack:rack-1');await click('rack-options');await click('order-modules');await click('order-select:0');await p.evaluate(()=>segnoDemo.turn(2));await click('order-done');await sweep(0,0);await sweep(0,.5);assert.ok(Math.abs(targetValue(await snap())-.35)<.001,'binding follows module identity through reorder');
  await click('back');await click('rack:rack-1');await click('rack-options');await click('remove');await click('remove-confirmed');await click('stage');await click('settings');await click('pedal-setup');await click('expression');assert.equal((await snap()).expression.values[0].available,false);assert.equal(await slider('heel').isDisabled(),true,'missing target stays visible without editing wrong parameter');
  await click('expr:replace');await click('repair:destination:Guitar');await click('repair:target:'+encodeURIComponent(JSON.stringify(['mix','Guitar','level'])));await click('repair:apply');assert.equal((await snap()).expression.values[0].available,true);assert.equal((await snap()).focusId,'expr:replace');
  // Capture the review states and inspect bounds, including native scrolling.
  for(const review of ['expression','expression-empty','expression-calibrate','expression-destination','expression-controls']){
   await p.goto(base+'?review='+review+'&canvas=actual');const bad=await p.evaluate(()=>[...document.querySelectorAll('#screen button,#screen input[type=range]')].filter(el=>!el.closest('.expression-target-list,.expression-destinations')).filter(el=>{const r=el.getBoundingClientRect();return r.x<0||r.y<0||r.right>1921||r.bottom>1081||el.scrollWidth>el.clientWidth+2;}).map(el=>el.textContent));assert.deepEqual(bad,[],kind+' '+review);
   if(review==='expression-controls'){assert.equal(await p.locator('.expression-more').isVisible(),true);assert.equal(await p.locator('.expression-more').getAttribute('aria-hidden'),'true');assert.equal(await p.locator('.expression-more').getAttribute('data-action'),null);await p.locator('.expression-target-list').hover();await p.mouse.wheel(0,500);await p.waitForTimeout(100);assert.ok(await p.locator('.expression-target-list').evaluate(el=>el.scrollTop)>100,'parameter picker scrolls normally');}
   if(kind==='chrome'){fs.mkdirSync('docs/design/expression-previews',{recursive:true});await p.locator('#screen').screenshot({path:'docs/design/expression-previews/'+review+'.png'});}
  }
  assert.deepEqual(errors,[]);console.log(kind+': expression targets, fan-out, inverted sweeps, calibration, cancellation, disconnect, persistence, reorder identity, missing-target recovery and layout passed.');
 }finally{await browser.close();}
}
})().catch(e=>{console.error(e);process.exitCode=1;});
