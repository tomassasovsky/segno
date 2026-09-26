// Focused integration regressions, using fresh author-only browser contexts.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const base=process.env.FX_PROTOTYPE_URL||'http://localhost:8768/fx-ux-prototype.html';
const cases=[
 ['MIDI editor leaves device mappings available on Stage',async(p,click,snap)=>{
  await p.goto(base+'?review=midi-learn');await p.waitForFunction(()=>window.segnoDemo);assert.equal((await snap()).midiState.learn,true);await click('stage');assert.equal((await snap()).midiState.learn,false);assert.equal((await snap()).midiState.view,'main');
  await p.evaluate(()=>{segnoDemo.midiReceive('usb',{kind:'cc',channel:1,number:21,value:0});segnoDemo.midiReceive('usb',{kind:'cc',channel:1,number:21,value:127});});
  const value=await p.evaluate(()=>{const s=segnoDemo.snapshot(),key=JSON.parse(segnoDemo.midiState().mappings[0].controls[0].key);return s.rig.racks.find(r=>r.id===key[1]).modules.find(m=>m.expressionId===key[2]).params.find(v=>v[0]===key[3])[1];});assert.equal(value,.65,'saved controller mapping dispatches after leaving Learn');
 }],
 ['Removing an active MIDI endpoint returns the encoder to navigation',async(p,click,snap)=>{
  await p.goto(base+'?review=midi-edit');await p.waitForFunction(()=>window.segnoDemo);const initial=(await snap()).midiState.mappings;
  await p.locator('[data-action="midi:range:0:high"]').focus();await p.evaluate(()=>segnoDemo.press());await p.evaluate(()=>segnoDemo.turn(1));await click('midi:remove:0');
  assert.equal((await snap()).midiState.draft.controls.length,0);await p.evaluate(()=>segnoDemo.turn(1));assert.equal((await snap()).midiState.draft.controls.length,0,'encoder navigates without restoring or changing removed controls');await click('midi:cancel');assert.deepEqual((await snap()).midiState.mappings,initial,'cancelling removal preserves the saved mapping');
 }],
 ['Save audio resolves an imported track duration',async(p,click,snap)=>{
  await p.goto(base+'?review=audio-library');await p.waitForFunction(()=>window.segnoDemo);await click('audio:up');await click('audio:folder:Saved%20audio');await click('audio:file:inside-9');await click('audio:load-track');await click('audio:import-target:3');await click('audio:timing:adapt');await click('audio:commit-track-import');await p.waitForFunction(()=>segnoDemo.snapshot().audioLibrary.view==='imported');const expected=(await snap()).audioLibrary.state.trackImports[3].timing.seconds;
  await click('audio:import-more');await click('audio:save');for(const i of [0,1,2])await click('audio:track:'+i);await click('audio:commit-save');await p.waitForFunction(()=>segnoDemo.snapshot().audioLibrary.view==='saved');assert.ok(Math.abs((await snap()).audioLibrary.lastSaved.seconds-expected)<1e-6,'saved audio retains the selected track duration');
 }],
 ['Track FX bypass preserves module and unrelated source state',async(p,click,snap)=>{
  await p.goto(base+'?review=stage-layout-mixer');await p.waitForFunction(()=>window.segnoDemo);const initial=await snap(),track=initial.rig.racks.filter(r=>r.source==='Track 1'||r.source.startsWith('Track 1 / ')),unrelated=initial.rig.racks.filter(r=>!track.some(t=>t.id===r.id));await click('stage-fx-power:0');let s=await snap();assert.ok(track.every(r=>s.effective[r.id]===false));assert.ok(unrelated.every(r=>s.effective[r.id]===initial.effective[r.id]));assert.deepEqual(s.rig.racks,initial.rig.racks,'group bypass does not rewrite per-rack/module controls');await click('stage-fx:0');assert.equal((await snap()).page,'sounds');await click('stage-fx-power:0');s=await snap();assert.ok(track.every(r=>s.effective[r.id]===initial.effective[r.id]));
 }],
];
for(const name of ['constructor','toString','__proto__'])cases.push(['Portable '+name+' effect imports and loads',async(p,click,snap)=>{
 await p.goto(base+'?review=pedal-chain');await p.waitForFunction(()=>window.segnoDemo);await click('back');await click('add');await click('saved');
 const initial=(await snap()).rig.racks.length;
 await p.evaluate(name=>segnoDemo.importFxPresets(JSON.stringify({format:'segno.fx-preset-library',version:1,presets:[{name:'Custom '+name,family:'Single FX',modules:[{name,params:[['Gain',.5,'',.5]],sourceValues:true}]}]})),name);
 assert.equal((await snap()).rig.racks.length,initial,'preview does not load a rack');await click('fxpresets:import-confirm');await click('fxpresets:load:0');
 let s=await snap();assert.equal(s.page,'chain');assert.equal(s.rig.racks.length,initial+1);assert.equal(s.rig.racks.at(-1).modules[0].name,name);assert.equal(await p.locator('input[data-action="inline:0:0"]').count(),1,'unknown module renders an editable source value');
 await p.locator('input[data-action="inline:0:0"]').fill('0.25');s=await snap();assert.equal(s.rig.racks.at(-1).modules[0].params[0][1],.25);assert.equal(s.rig.saved[0].modules[0].params[0][1],.5,'loaded effect remains independent of the portable preset');
}]);
(async()=>{const failures=[];for(const [kind,type] of [['chrome',chromium],['firefox',firefox]]){const browser=await type.launch({headless:true,...(kind==='chrome'&&process.env.ATLAS_CHROME?{executablePath:process.env.ATLAS_CHROME}:{})});try{for(const [name,run] of cases){const ctx=await browser.newContext({viewport:{width:1920,height:1080}}),p=await ctx.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(6000);try{await run(p,id=>p.locator('[data-action='+JSON.stringify(id)+']').click(),()=>p.evaluate(()=>({...segnoDemo.snapshot(),midiState:segnoDemo.midiState()})));assert.deepEqual(errors,[]);console.log(kind+': '+name+' passed');}catch(error){failures.push(kind+': '+name+': '+error.message);console.error(failures.at(-1));}finally{await ctx.close();}}}finally{await browser.close();}}if(failures.length)process.exitCode=1;})().catch(error=>{console.error(error);process.exitCode=1;});
