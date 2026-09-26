// Author browser verification of timing handoff and reversible same-rack audition.
// Normal storage URL, real commands, simulated clock; no native audio claims.
const {chromium,firefox}=require('playwright'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html',key='segno-fx-factory-design-2026-09-06-channels';
const output=path.join(__dirname,'primary-audition-previews');
async function verify(kind){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}:{})});
 try{
  const page=await browser.newPage({viewport:{width:1968,height:1124}}),errors=[];page.setDefaultTimeout(6000);page.on('pageerror',e=>errors.push(e.message));
  await page.clock.install({time:new Date('2026-09-08T12:00:00Z')});await page.clock.pauseAt(new Date('2026-09-08T12:00:01Z'));
  const state=()=>page.evaluate(()=>segnoDemo.snapshot()),stored=()=>page.evaluate(key=>JSON.parse(localStorage.getItem(key)),key);
  const button=id=>page.locator('[data-action='+JSON.stringify(id)+']'),click=id=>button(id).click(),command=id=>page.evaluate(id=>segnoDemo.dispatchMapping(id),id);
  const advance=ms=>page.clock.runFor(ms),rack=(s,id)=>s.rig.racks.find(r=>r.id===id);
  async function screenshot(name){await page.evaluate(()=>document.fonts.ready);
   const escaped=await page.locator('.primary-track-option,.primary-track-dialog button,.preset-audition-dialog .actions button').evaluateAll(elements=>{const s=document.querySelector('#screen').getBoundingClientRect();return elements.filter(e=>{const b=e.getBoundingClientRect();return b.top<s.top-1||b.bottom>s.bottom+1||b.left<s.left-1||b.right>s.right+1;}).map(e=>e.textContent);});assert.deepEqual(escaped,[],name+' controls remain inside display');
   const overflowing=await page.locator('.preset-audition-option').evaluateAll(elements=>elements.flatMap(e=>{const b=e.getBoundingClientRect();return [...e.querySelectorAll('span,small')].filter(child=>{const r=child.getBoundingClientRect();return r.top<b.top-1||r.bottom>b.bottom+1||r.left<b.left-1||r.right>b.right+1;}).map(child=>child.textContent);}));assert.deepEqual(overflowing,[],'preset labels fit their buttons');fs.mkdirSync(output,{recursive:true});await page.locator('#screen').screenshot({path:path.join(output,kind+'-'+name+'.png')});}
  async function writerFailure(work){await page.evaluate(key=>{window.realWriter=Storage.prototype.setItem;Storage.prototype.setItem=function(k,v){if(k===key)throw new DOMException('Full','QuotaExceededError');return window.realWriter.call(this,k,v);};},key);try{await work();}finally{await page.evaluate(()=>{Storage.prototype.setItem=window.realWriter;delete window.realWriter;});}}
  await page.goto(base+'?canvas=actual');await page.waitForFunction(()=>window.segnoDemo);const initial=await state();
  async function seed(empty=false){const expected=await page.evaluate(({initial,key,empty})=>{
   const rig=structuredClone(initial.rig);Object.assign(rig,{recordedParts:{},trackPlayback:{},trackLayers:{},trackLength:{},trackLabels:structuredClone(initial.trackLabels),liveMonitoring:structuredClone(initial.liveMonitoring),recordingInputs:structuredClone(initial.recordingInputs),inputLabels:structuredClone(initial.inputLabels),outputLabels:structuredClone(initial.outputLabels),expressionSettings:structuredClone(initial.expression.saved),audioLibrary:structuredClone(initial.audioLibrary.state)});
   for(let i=0;i<8;i++){const t='Track '+(i+1),beats=!empty&&i<2?[16,8][i]:0;rig.recordedParts[t]=beats?['Guitar']:[];rig.trackPlayback[t]=false;rig.trackLayers[t]={layers:beats?[{id:'take-'+i,beats:i?2:16,gain:1,regions:[{offsetBeats:i?6:0,beats:i?2:16}]}]:[]};rig.trackLength[t]={audio:[],durationBeats:beats,note:''};}
   rig.editHistory={serial:0,tracks:Array.from({length:8},()=>({undo:[],redo:[]}))};rig.loopSettings={...initial.loopSettings,mode:'sync',tempo:120,signature:'4/4',start:'press',click:'always',countIn:0,recDub:false,primaryTrack:empty?null:'Track 1',lengthTiming:{bars:0,quantize:'immediate'},playback:{once:false,decay:0},audioTempo:{follow:true,keepPitch:true}};
   rig.trackLabels['Track 1']='Beat';rig.trackLabels['Track 2']='Verse';rig.trackLabels['Track 3']='First take';rig.trackFade={};rig.mutedTracks=Array(8).fill(false);rig.soloTracks=Array(8).fill(false);rig.audioLibrary.prepared=[];rig.audioLibrary.backing=null;rig.audioLibrary.trackImports={};
   SegnoFxParameters.targets(rig);const chosen=rig.racks.find(r=>r.family==='Guitar Rack');chosen.name='Unsaved guitar';chosen.bypass=true;chosen.rule={pedal:0,condition:'on'};
   const mod=chosen.modules.find(m=>m.params.some(p=>SegnoFxParameters.describe(m,p).role!=='enable')),param=mod.params.find(p=>SegnoFxParameters.describe(mod,p).role!=='enable');param[1]=.37;
   rig.channels[chosen.id]={input:'left',output:'mono',pan:['Pan',.21,'',.5]};
   const personal={name:'Personal trial',family:chosen.family,modules:structuredClone(chosen.modules),channels:{input:'stereo',output:'stereo',pan:['Pan',.5,'',.5]}};personal.modules.find(m=>m.name===mod.name).params.find(p=>p[0]===param[0])[1]=.91;
   const bad=structuredClone(personal);bad.name='Different layout';bad.modules.pop();rig.saved=[personal,bad];
   const target=JSON.stringify(['fx',chosen.id,mod.expressionId,param[0]]);rig.midiControlSettings={enabled:true};rig.midiMappings=[{id:'trial-midi',device:'usb',enabled:true,behavior:'continuous',source:{kind:'cc',channel:1,number:23},controls:[{kind:'parameter',key:target,low:0,high:1}]}];
   for(const port of rig.expressionSettings.ports){port.mappings=[];port.switches.forEach(s=>s.mappings=[]);}rig.syncSettings={source:'internal',thru:true};delete rig.performanceRecording;delete rig.sessionLibrary;
   localStorage.setItem(key,JSON.stringify(rig));return {rackId:chosen.id,moduleId:mod.expressionId,paramKey:param[0]};
  },{initial,key,empty});await page.goto(base+'?canvas=actual');await page.waitForFunction(()=>window.segnoDemo);return expected;}
  const openPrimary=async()=>{await click('settings');await click('loop:page:loop-settings');await click('primary:open');};
  const openRack=async expected=>{await click('settings');await click('effects');await click('rack:'+expected.rackId);};
  const value=(s,e)=>rack(s,e.rackId).modules.find(m=>m.expressionId===e.moduleId).params.find(p=>p[0]===e.paramKey)[1];

  let expected=await seed();await openPrimary();let before=await state(),saved=await stored();await screenshot('primary-stopped');
  assert.equal(before.primary.current,'Track 1');assert.match(await button('primary:choose:Track%202').innerText(),/Verse/);
  assert(await button('primary:choose:Track%203').isDisabled());
  await writerFailure(async()=>{await click('primary:choose:Track%202');assert.equal((await state()).primary.current,'Track 1');assert.match((await state()).primary.error,/Could not save/);assert.deepEqual(await stored(),saved);});
  await click('primary:choose:Track%202');assert.equal((await state()).primary.current,'Track 2');assert.deepEqual((await state()).rig.trackLayers,before.rig.trackLayers);assert.deepEqual((await state()).rig.trackLength,before.rig.trackLength);
  await page.reload();assert.equal((await state()).primary.current,'Track 2');assert.equal(await page.locator('[data-stage-primary="1"]').count(),1);assert.equal((await page.evaluate(()=>segnoDemo.displayState())).tracks.filter(t=>t.primary).length,1);

  expected=await seed();await command('select-track:0');await command('command:record-play');await advance(500);await openPrimary();before=await state();saved=await stored();
  await click('primary:choose:Track%202');assert.equal((await state()).primary.current,'Track 1');assert.equal((await state()).trackPlayback['Track 1'],true);await screenshot('primary-playing');
  await click('primary:cancel');assert.equal((await state()).trackPlayback['Track 1'],true);await click('primary:choose:Track%202');
  await writerFailure(async()=>{await click('primary:confirm');assert.equal((await state()).primary.current,'Track 1');assert.equal((await state()).trackPlayback['Track 1'],true);assert.deepEqual(await stored(),saved);});
  await click('primary:confirm');assert.equal((await state()).primary.current,'Track 2');assert(Object.values((await state()).trackPlayback).every(v=>!v));assert.deepEqual((await state()).rig.trackLayers,before.rig.trackLayers);await screenshot('primary-switched');
  await page.reload();assert.equal((await state()).primary.current,'Track 2');

  await click('stage-view-menu');await click('stage-view:wave');assert.equal(await page.locator('[data-stage-primary="1"]').count(),1);assert((await page.locator('.stage-wave-label .stage-track-number').nth(1).boundingBox()).height<40,'timing marker stays on the number baseline');await screenshot('primary-stage-wave');
  await click('stage-view-menu');await click('stage-view:mixer');assert.equal(await page.locator('[data-stage-primary="1"]').count(),1);
  // A real first take on Track3 owns timing even when Track1 is recorded later.
  await seed(true);await command('select-track:2');await command('command:record-play');await advance(2000);await command('command:record-play');
  assert.equal((await state()).loopSettings.primaryTrack,'Track 3','first click-on take establishes explicit primary');await command('command:stop');
  await command('select-track:0');await command('command:record-play');await advance(2000);await command('command:record-play');
  assert.equal((await state()).loopSettings.primaryTrack,'Track 3');await command('command:stop');await page.reload();assert.equal((await state()).primary.current,'Track 3');

  expected=await seed();await openRack(expected);before=await state();saved=await stored();const originalRack=structuredClone(rack(before,expected.rackId)),originalChannels=structuredClone(before.rig.channels[expected.rackId]);
  await click('try-preset');assert.equal((await state()).audition.selectedIndex,-1);assert.match(await page.locator('.preset-audition-dialog').innerText(),/Rack bypassed/);
  const first=page.locator('[data-action^="audition:choose:"]:not(:disabled)').first();await first.click();assert((await state()).audition.active);
  const firstName=rack(await state(),expected.rackId).name;await page.evaluate(()=>segnoDemo.turn(1));assert.notEqual(rack(await state(),expected.rackId).name,firstName,'encoder moves to another preset');
  await page.evaluate(()=>{for(const value of [0,127])segnoDemo.midiReceive('usb',{kind:'cc',channel:1,number:23,value});});assert.equal(value(await state(),expected),1);
  const persisted=await stored();assert.deepEqual(persisted.racks.find(r=>r.id===expected.rackId),originalRack);assert.deepEqual(persisted.channels[expected.rackId],originalChannels);
  assert.equal(value(await state(),expected),1,'rendering and saving do not reselect the preset');await screenshot('preset-audition-active');
  await click('audition:cancel');assert.deepEqual(rack(await state(),expected.rackId),originalRack);assert.deepEqual((await state()).rig.channels[expected.rackId],originalChannels);assert.deepEqual((await state()).rig.midiMappings,before.rig.midiMappings);
  await click('try-preset');await first.click();await page.reload();assert.deepEqual(rack(await state(),expected.rackId),originalRack);assert.equal((await state()).audition.active,false);

  await openRack(expected);await click('try-preset');const personal=page.locator('[data-action^="audition:choose:"]').filter({hasText:'Personal trial'});assert(await personal.isEnabled());
  const bad=page.locator('[data-action^="audition:choose:"]').filter({hasText:'Different layout'});assert(await bad.isDisabled());assert.match(await bad.innerText(),/different effect layout/);await personal.click();assert.equal(value(await state(),expected),.91);
  saved=await stored();await writerFailure(async()=>{await click('audition:keep');assert((await state()).audition.active);assert.match((await state()).audition.error,/Could not save/);assert.equal(value(await state(),expected),.91);assert.deepEqual(await stored(),saved);});
  await click('audition:keep');assert.equal((await state()).audition.active,false);assert.equal(value(await state(),expected),.91);await screenshot('preset-audition-kept');await page.reload();assert.equal(value(await state(),expected),.91);
  await openRack(expected);before=await state();await click('try-preset');await first.click();await page.keyboard.press('Escape');assert.equal((await state()).audition.active,false);assert.deepEqual(rack(await state(),expected.rackId),rack(before,expected.rackId));

  // Starting real capture while trying a sound restores the baseline before capture.
  await click('try-preset');await first.click();await command('select-track:2');await command('command:record-play');assert.equal((await state()).audition.active,false);assert.deepEqual(rack(await state(),expected.rackId),rack(before,expected.rackId));
  await command('command:undo');assert.deepEqual(errors,[]);
  console.log(kind+': primary stopped/playing handoff, storage rollback/reload, first-recording ownership; preset touch/encoder trial, MIDI persistence isolation, Cancel/Keep/reload/failure and capture cancellation passed');
 }finally{await browser.close();}
}
(async()=>{for(const kind of ['chrome','firefox'])await verify(kind);})().catch(error=>{console.error(error);process.exitCode=1;});
