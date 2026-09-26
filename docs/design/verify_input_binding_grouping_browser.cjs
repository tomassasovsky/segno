// Normal-storage browser checks for logical grouping of exact physical input ports.
const {chromium,firefox}=require('playwright'),assert=require('node:assert/strict');
const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html',key='segno-fx-factory-design-2026-09-06-channels';
async function verify(kind){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}:{})});
 try{
  const page=await browser.newPage({viewport:{width:1968,height:1124}}),errors=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(6000);
  const click=id=>page.locator('[data-action='+JSON.stringify(id)+']').click(),state=()=>page.evaluate(()=>segnoDemo.snapshot()),stored=()=>page.evaluate(k=>JSON.parse(localStorage.getItem(k)),key);
  await page.goto(base+'?canvas=actual');await page.waitForFunction(()=>window.segnoDemo);
  const initial=await state();
  // A fresh rig can have no explicit inputSetup until its first setting change.
  assert.equal(initial.rig.inputSetup,undefined);await click('settings');await click('route:open');await click('route:tab:setup');await click('input:format:stereo');assert.deepEqual((await state()).rig.inputSetup.stereoPairs,['Guitar']);

  async function seed(incompatible=false){await page.evaluate(({initial,key,incompatible})=>{
   const rig=structuredClone(initial.rig),rows=rig.audioRouting.portBindings.filter(b=>b.direction==='input');
   // Move the first logical pair to physical jacks 3/4 and the second to 1/2.
   // Pairing must preserve this deliberate map, rather than regenerate from UI order.
   const ports=rows.slice(0,4).map(r=>r.portIds[0]);[rows[0].portIds[0],rows[1].portIds[0],rows[2].portIds[0],rows[3].portIds[0]]=[ports[2],ports[3],ports[0],ports[1]];
   if(incompatible)[rows[1].portIds[0],rows[2].portIds[0]]=[rows[2].portIds[0],rows[1].portIds[0]];
   rig.inputSetup={...rig.inputSetup,stereoPairs:[],trimDb:{Guitar:-3,Vocal:2}};rig.recordingInputs=structuredClone(initial.recordingInputs);rig.recordingInputs['Track 1']=['Guitar'];delete rig.sessionLibrary;
   localStorage.setItem(key,JSON.stringify(rig));
  },{initial,key,incompatible});await page.reload();await page.waitForFunction(()=>window.segnoDemo);await click('settings');await click('route:open');await click('route:tab:setup');}
  async function fail(work){await page.evaluate(k=>{window.savedWriter=Storage.prototype.setItem;Storage.prototype.setItem=function(key,value){if(key===k)throw new DOMException('Full','QuotaExceededError');return window.savedWriter.call(this,key,value);};},key);try{await work();}finally{await page.evaluate(()=>{Storage.prototype.setItem=window.savedWriter;delete window.savedWriter;});}}
  await seed();let before=await state(),saved=await stored();const outputs=before.rig.audioRouting.portBindings.filter(b=>b.direction==='output');
  await fail(async()=>{await click('input:format:stereo');const after=await state();assert.deepEqual(after.rig.inputSetup,before.rig.inputSetup);assert.deepEqual(after.rig.audioRouting,before.rig.audioRouting);assert.deepEqual(after.recordingInputs,before.recordingInputs);assert.deepEqual(await stored(),saved);});
  await click('input:format:stereo');let after=await state(),pair=after.rig.audioRouting.portBindings.find(b=>b.id==='input:Guitar');assert.deepEqual(pair.logicalIds,['Guitar','Vocal']);assert.deepEqual(pair.portIds,['stage:input:3','stage:input:4']);assert.deepEqual(after.rig.inputSetup.trimDb,before.rig.inputSetup.trimDb);assert.deepEqual(after.recordingInputs['Track 1'],['Guitar','Vocal']);assert.deepEqual(after.rig.audioRouting.portBindings.filter(b=>b.direction==='output'),outputs);
  await page.reload();assert.deepEqual((await state()).rig.audioRouting.portBindings.find(b=>b.id==='input:Guitar').portIds,pair.portIds);await click('settings');await click('route:open');await click('route:tab:setup');before=await state();saved=await stored();
  await fail(async()=>{await click('input:format:mono');assert.deepEqual((await state()).rig.audioRouting,before.rig.audioRouting);assert.deepEqual((await state()).rig.inputSetup,before.rig.inputSetup);assert.deepEqual(await stored(),saved);});
  await click('input:format:mono');after=await state();assert.deepEqual(after.rig.audioRouting.portBindings.find(b=>b.id==='input:Guitar').portIds,['stage:input:3']);assert.deepEqual(after.rig.audioRouting.portBindings.find(b=>b.id==='input:Vocal').portIds,['stage:input:4']);assert.deepEqual(after.rig.audioRouting.portBindings.filter(b=>b.direction==='output'),outputs);assert.deepEqual(after.recordingInputs['Track 1'],['Guitar','Vocal']);await page.reload();assert.deepEqual((await state()).rig.inputSetup.stereoPairs,[]);
  await seed(true);before=await state();saved=await stored();await click('input:format:stereo');assert.deepEqual((await state()).rig.audioRouting,before.rig.audioRouting);assert.deepEqual((await state()).rig.inputSetup,before.rig.inputSetup);assert.deepEqual(await stored(),saved);assert.match(await page.locator('.input-setup-panel').locator('..').innerText(),/could not be saved/);
  assert.deepEqual(errors,[]);console.log(kind+': pairing/splitting retains remapped physical jacks, output routes and trim; failed publication and invalid physical pair preserve state; reload passed');
 }finally{await browser.close();}
}
(async()=>{for(const kind of ['chrome','firefox'])await verify(kind);})().catch(e=>{console.error(e);process.exitCode=1;});
