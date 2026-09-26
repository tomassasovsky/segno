// Browser behavior checks for editing FX activation from External pedals.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await (kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const base='http://127.0.0.1:8768/fx-ux-prototype.html';
  const button=id=>page.locator('[data-action='+JSON.stringify('expr:'+id)+']');
  const click=id=>button(id).click();
  const snap=()=>page.evaluate(()=>segnoDemo.snapshot());
  const rule=async id=>(await snap()).rig.racks.find(r=>r.id===id).rule;
  const input=(i,down)=>page.evaluate(args=>segnoDemo.externalSwitchInput(0,...args),[i,down]);
  const add=async id=>{
   const r=(await snap()).rig.racks.find(r=>r.id===id);
   await click('switch:add-control');await click('switch:control-destination:'+encodeURIComponent(r.source));await click('switch:add-target:'+encodeURIComponent(id));
  };
  await page.goto(base+'?review=external-controls&canvas=actual');
  assert.equal((await snap()).expression.switches.mappings.length,4);
  await click('switch:control:rack-1');await click('switch:state:released');
  assert.equal((await rule('rack-1')).condition,'on','editing never changes the live FX rule');
  await input(0,true);await input(0,false); // An unrelated state save must not commit setup.
  assert.equal((await rule('rack-1')).condition,'on');
  await click('switch:control:rack-2');await click('switch:state:held');
  await click('switch:select:1');await add('rack-5');await click('switch:state:off');
  await click('port:1');await click('type:single');await click('switch:panel:controls');await add('rack-6');
  await click('port:0');await click('cancel');
  assert.equal((await rule('rack-1')).condition,'on');assert.equal((await rule('rack-2')).condition,'off');
  assert.equal((await snap()).expression.switches.changes.length,0);
  assert.equal((await snap()).expression.draft.ports[1].type,'expression');
  // Several effects on one button, with independent conditions; another button is separate.
  await click('switch:control:rack-1');await click('switch:state:released');
  await click('switch:control:rack-2');await click('switch:state:held');
  await click('switch:select:1');await add('rack-5');await click('switch:state:off');
  await click('save');assert.deepEqual(await rule('rack-5'),{pedal:'external:0:1',condition:'off'});
  await input(0,true);assert.equal((await snap()).effective['rack-1'],false);assert.equal((await snap()).effective['rack-2'],true);
  await input(0,false);assert.equal((await snap()).effective['rack-1'],true);assert.equal((await snap()).effective['rack-2'],false);
  const original=(await rule('rack-5'));await input(1,true);assert.equal((await snap()).effective['rack-5'],false);await input(1,false);
  assert.deepEqual(await rule('rack-5'),original);
  // Removal stages an always-on rule and preserves other mappings and bypass state.
  const bypass=(await snap()).rig.racks.find(r=>r.id==='rack-5').bypass;
  await click('switch:remove-control');assert.deepEqual(await rule('rack-5'),original);await click('save');
  assert.deepEqual(await rule('rack-5'),{pedal:null,condition:'always'});
  assert.equal((await snap()).rig.racks.find(r=>r.id==='rack-5').bypass,bypass);
  assert.equal((await rule('rack-2')).condition,'held');
  // Latching hardware cannot claim foot-down duration, and the picker supports Back.
  await click('switch:panel:actions');await click('switch:hardware:latching');await click('switch:panel:controls');await add('rack-5');
  assert.equal(await button('switch:state:held').isDisabled(),true);assert.equal(await button('switch:state:released').isDisabled(),true);
  await click('switch:add-control');await click('switch:control-destination:Guitar');await page.keyboard.press('Escape');
  assert.equal((await snap()).expression.switches.controlView,'destinations');await page.keyboard.press('Escape');
  assert.equal((await snap()).expression.switches.controlView,null);
  // Saved source assignments are visible in the existing FX editor, without a duplicate store.
  await click('cancel');await page.locator('[data-action="stage"]').click();await page.locator('[data-action="settings"]').click();await page.locator('[data-action="effects"]').click();await page.locator('[data-action="rack:rack-1"]').click();await page.locator('[data-action="activation"]').click();
  assert.equal((await snap()).page,'expression','external assignments open their sole editor');assert.equal((await snap()).expression.switches.control,'rack-1');
  assert.equal(await button('switch:state:released').getAttribute('aria-pressed'),'true');await click('switch:state:on');await click('save');
  await page.locator('[data-action="stage"]').click();await page.locator('[data-action="settings"]').click();await page.locator('[data-action="pedal-setup"]').click();await page.locator('[data-action="expression"]').click();
  assert.equal((await snap()).expression.switches.mappings.find(m=>m.id==='rack-1').rule.condition,'on');
  // Encoder focus reveals mappings past the first three rows. Indicator is not a stop.
  await page.goto(base+'?review=external-controls&canvas=actual');await click('switch:control:rack-3');await page.evaluate(()=>segnoDemo.turn(1));
  assert.equal((await snap()).focusId,'expr:switch:control:rack-4');await page.evaluate(()=>segnoDemo.press());
  assert.equal((await snap()).expression.switches.control,'rack-4');
  assert.equal(await page.locator('.expression-more[data-action],.expression-more[tabindex]').count(),0);
  // Normal (non-review) persistence and abandoning draft mappings.
  await page.goto(base+'?canvas=actual');await page.evaluate(()=>localStorage.clear());await page.reload();
  assert.equal((await snap()).page,'stage');await page.locator('[data-action="settings"]').click();await page.locator('[data-action="pedal-setup"]').click();await page.locator('[data-action="expression"]').click();
  await click('type:dual');await click('switch:panel:controls');await add('rack-1');await click('switch:state:held');await add('rack-2');await click('switch:state:off');await click('save');
  await click('switch:state:on');await page.reload();assert.deepEqual(await rule('rack-1'),{pedal:'external:0:0',condition:'held'});assert.deepEqual(await rule('rack-2'),{pedal:'external:0:0',condition:'off'});
  await page.goto(base+'?review=external-controls-knob&canvas=actual');
  const parameter=async()=>{const s=await snap();const m=s.expression.saved.ports[0].switches[0].mappings[0];const [,rack,module,name]=JSON.parse(m.target);return s.rig.racks.find(r=>r.id===rack).modules.find(m=>m.expressionId===module).params.find(p=>p[0]===name)[1];};
  const initialValue=await parameter();await input(0,true);assert.equal(await parameter(),.65);await input(0,false);assert.equal(await parameter(),.65,'release leaves On value latched');await input(0,true);assert.equal(await parameter(),.2);await input(0,false);
  await click('switch:state:held');await click('save');await input(0,true);assert.equal(await parameter(),.65);await input(0,false);assert.equal(await parameter(),.2,'Released uses its chosen value');
  await input(0,true);await page.evaluate(()=>segnoDemo.expressionConnect(0,false));assert.equal(await parameter(),.2,'disconnect ends a held parameter change');await page.evaluate(()=>segnoDemo.expressionConnect(0,true));await input(0,false);
  // Encoder edit cancellation and direct touch use the shared parameter controls.
  await button('switch:value:active').focus();await page.evaluate(()=>segnoDemo.press());await page.evaluate(()=>segnoDemo.turn(5));assert.equal((await snap()).expression.switches.mappings.find(m=>m.parameter).parameter.active,.7);await page.keyboard.press('Escape');assert.equal((await snap()).expression.switches.mappings.find(m=>m.parameter).parameter.active,.65);
  const slider=button('switch:value:active');await slider.evaluate(el=>{el.value='0.8';el.dispatchEvent(new Event('input',{bubbles:true}));});assert.equal((await snap()).expression.switches.mappings.find(m=>m.parameter).parameter.active,.8);assert.equal(await parameter(),.2,'editing an endpoint does not dispatch it');await click('cancel');assert.equal((await snap()).expression.switches.mappings.find(m=>m.parameter).parameter.active,.65);
  const defaultValue=(await snap()).expression.switches.mappings.find(m=>m.parameter).defaultValue;await button('switch:value:active').dblclick();assert.equal((await snap()).expression.switches.mappings.find(m=>m.parameter).parameter.active,defaultValue);await click('cancel');
  // Same button can move another parameter as well as activate several racks.
  await click('switch:add-control');await click('switch:control-destination:Guitar');
  const volumeId='parameter:'+JSON.stringify(['mix','Guitar','level']);await click('switch:add-target:'+encodeURIComponent(volumeId));await button('switch:value:active').evaluate(el=>{el.value='0.4';el.dispatchEvent(new Event('input',{bubbles:true}));});await click('switch:state:held');await click('save');
  await input(0,true);assert.equal(await parameter(),.65);assert.equal((await snap()).rig.expressionMix.Guitar.level,.4);await input(0,false);assert.equal(await parameter(),.2);assert.equal((await snap()).rig.expressionMix.Guitar.level,1);
  await page.goto(base+'?canvas=actual');assert.equal((await snap()).page,'stage');await page.locator('[data-action="settings"]').click();await page.locator('[data-action="pedal-setup"]').click();await page.locator('[data-action="expression"]').click();
  await click('switch:panel:controls');await click('switch:add-control');await click('switch:control-destination:Guitar');await click('switch:add-target:'+encodeURIComponent(volumeId));await button('switch:value:active').evaluate(el=>{el.value='0.37';el.dispatchEvent(new Event('input',{bubbles:true}));});await click('save');await page.reload();
  assert.equal((await snap()).expression.saved.ports[0].switches[0].mappings.find(m=>m.target===JSON.stringify(['mix','Guitar','level'])).active,.37,'numeric mapping survives reload');
  for(const review of ['external-controls','external-controls-add','external-controls-knob']){
   await page.goto(base+'?review='+review+'&canvas=actual');
   const bad=await page.evaluate(()=>[...document.querySelectorAll('#screen button')].filter(el=>{const r=el.getBoundingClientRect();if(el.closest('.list'))return el.scrollWidth>el.clientWidth+2;return r.x<0||r.y<0||r.right>1921||r.bottom>1081||el.scrollWidth>el.clientWidth+2;}).map(el=>el.textContent));assert.deepEqual(bad,[]);
   if(kind==='chrome'){fs.mkdirSync('docs/design/expression-previews',{recursive:true});await page.locator('#screen').screenshot({path:'docs/design/expression-previews/'+review+'.png'});}
  }
  assert.deepEqual(errors,[]);console.log(kind+': source-side multi-control mappings, conditions, draft isolation, removal, FX ownership, encoder and reload passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
