// Behavioral checks for simulated appliance media and draft-owned mapping repair.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const codec=require('./fx-preset-library.js');
const closure=require('./media-closure-study.js');
const copy=v=>JSON.parse(JSON.stringify(v));
const preset={name:'Warm guitar',family:'Single FX',modules:[{name:'Delay',params:[['Mix',.3,'',.3]]}]};
const packageFile=(id,location='usb',text=codec.encode([preset]))=>({id,location,name:'Warm guitar.segno-fx.json',text});
const base={button:(id,title,cls='',attr='')=>`<button data-action="${id}" class="${cls}" ${attr}>${title}</button>`,escape:String,render:()=>{},focus:()=>{},setFocus:()=>{},header:()=>'',artwork:()=>'',notice:()=>{},icon:()=>''};
function runtime(){
  const timers=new Map();let next=1;
  const world={window:{},TextEncoder,Date,Map,Set,crypto:{randomUUID:()=>String(next++)},performance:{now:()=>0},setTimeout:fn=>{timers.set(next,fn);return next++;},clearTimeout:id=>timers.delete(id)};
  vm.createContext(world);
  for(const filename of ['fx-preset-library.js','media-closure-study.js','external-switch-study.js','expression-ux-study.js','midi-protocol-study.js','midi-controls-study.js','storage-study.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,filename),'utf8'),world);
  world.window.SegnoAssignableActions=[];world.window.SegnoMappingActionGroups=[];
  return {w:world.window,flush:()=>{for(const [id,fn]of[...timers]){timers.delete(id);fn();}}};
}
function transport(){
  const r=runtime(),m={usbConnected:true,job:null,internalFreeBytes:1e9,usbFreeBytes:1e9};let files=[packageFile('usb-1'),packageFile('internal-1','internal')],writesFail=false,received=null,completed=null,focused='',canceled=0;
  const ui=r.w.SegnoMediaClosure.createPresetInterchange({...base,codec,focus:id=>focused=id,media:()=>m,read:()=>files,write:next=>{if(writesFail)return false;files=copy(next);return true;}});
  return {ui,...r,m,files:()=>copy(files),fail:v=>writesFail=v,receive:()=>received,done:()=>completed,focus:()=>focused,canceled:()=>canceled,changeFile:()=>files[0].text=codec.encode([{...preset,name:'Changed'}]),beginImport:()=>ui.chooseFile(text=>received=text,()=>{},()=>canceled++),beginExport:()=>ui.export(codec.encode([preset]),'My presets.segno-fx.json',result=>completed=copy(result),'fxpresets:export:0')};
}
function chooseUSB(t){t.ui.action('mediafx:location:usb');t.ui.action('mediafx:file:usb-1');}

test('recording time uses raw PCM byte cost, reserve and simultaneous recordings; unknown inputs stay unknown',()=>{
  const input={freeBytes:1e9+48000*3*2*3661,reserveBytes:1e9,sampleRate:48000,bytesPerSample:3,channels:2};
  assert.equal(closure.recordingEstimate(input).seconds,3661);
  assert.equal(closure.recordingEstimate(input).label,'1 hr 1 min recording');
  assert.equal(closure.recordingEstimate({...input,streams:2}).seconds,1830);
  assert.equal(closure.recordingEstimate({...input,channels:1}).seconds,7322);
  assert.equal(closure.recordingEstimate({...input,freeBytes:1}).seconds,0);
  assert.equal(closure.recordingEstimate({...input,freeBytes:Infinity}).available,false);
  assert.equal(closure.recordingEstimate({...input,channels:0}).available,false);
  assert.equal(closure.recordingEstimate({...input,reserveBytes:undefined}).available,false);
  assert.match(closure.estimateBody(input),/48 kHz · 24-bit · Stereo/);
});
test('import browses both appliance locations and waits for explicit review before library mutation',()=>{
  const t=transport();let presets=[copy(preset)];const ui=codec.createUI({...base,read:()=>presets,write:next=>{presets=next;return true;},media:t.ui});
  ui.action('fxpresets:import');assert.equal(t.ui.snapshot().state.location,'internal');chooseUSB(t);t.ui.action('mediafx:transfer');assert.equal(presets.length,1);t.flush();assert.equal(ui.snapshot().modal.type,'import');assert.equal(presets.length,1);ui.action('fxpresets:import-confirm');assert.equal(presets.length,2);assert.equal(presets[1].name,'Warm guitar (2)');
});
test('cancel while reading creates no import and restores opener; changed source and USB loss fail without publication',()=>{
  const t=transport();t.beginImport();chooseUSB(t);t.ui.action('mediafx:transfer');t.ui.back();t.flush();assert.equal(t.receive(),null);assert.equal(t.canceled(),1);assert.equal(t.focus(),'fxpresets:import');
  t.beginImport();chooseUSB(t);t.ui.action('mediafx:transfer');t.changeFile();t.flush();assert.equal(t.receive(),null);assert.match(t.ui.snapshot().error,/changed/);
  t.ui.action('mediafx:transfer');t.m.usbConnected=false;t.ui.mediaChanged();t.flush();assert.match(t.ui.snapshot().error,/disconnected/);assert.equal(t.receive(),null);
});
test('USB reconnect does not let an earlier transfer commit on a different drive',()=>{
  const t=transport();t.beginExport();t.ui.action('mediafx:location:usb');t.ui.action('mediafx:transfer');t.ui.mediaChanged();t.flush();assert.equal(t.files().length,2);assert.equal(t.done(),null);assert.match(t.ui.snapshot().error,/changed/);
});
test('invalid import remains in chooser; cancellation preserves packages and library',()=>{
  const t=transport();t.beginImport();t.ui.simulate({files:[packageFile('broken','internal','{')]});t.ui.action('mediafx:file:broken');t.ui.action('mediafx:transfer');t.flush();assert.match(t.ui.snapshot().error,/not valid/);assert.equal(t.receive(),null);t.ui.back();assert.equal(t.files().length,1);
});
test('export respects shared busy state, failed storage, capacity and cancel; successful copy never overwrites',()=>{
  const t=transport(),before=t.files();t.beginExport();t.m.job={kind:'backup'};t.ui.action('mediafx:transfer');assert.equal(t.ui.busy(),false);t.m.job=null;t.ui.action('mediafx:transfer');t.ui.back();t.flush();assert.deepEqual(t.files(),before);assert.equal(t.done(),null);
  t.beginExport();t.fail(true);t.ui.action('mediafx:transfer');t.flush();assert.match(t.ui.snapshot().error,/Could not write/);assert.deepEqual(t.files(),before);
  t.fail(false);t.m.internalFreeBytes=1;t.ui.action('mediafx:transfer');t.flush();assert.match(t.ui.snapshot().error,/enough space/);assert.deepEqual(t.files(),before);
  t.m.internalFreeBytes=1e9;t.ui.action('mediafx:transfer');t.flush();assert.equal(t.done().location,'internal');assert.equal(t.focus(),'fxpresets:export:0');assert.equal(t.files().length,3);
  t.beginExport();t.ui.action('mediafx:transfer');t.flush();assert.equal(t.done().name,'My presets (2).segno-fx.json');assert.equal(t.files()[2].text,t.files()[3].text);
});
test('bottom package keyboard supports physical typing and canceled rename',()=>{
  const t=transport();t.beginExport();t.ui.action('mediafx:name');assert.match(t.ui.overlay(),/keyboard-sheet/);assert.equal(t.ui.key({key:'ArrowDown'}),false);t.ui.key({key:'A'});assert.equal(t.ui.snapshot().state.name,'A');t.ui.key({key:'Escape'});assert.equal(t.ui.snapshot().state.name,'My presets');t.ui.action('mediafx:name');for(const key of 'Set two')t.ui.key({key});t.ui.key({key:'Enter'});assert.equal(t.ui.snapshot().state.name,'Set two');assert.equal(t.focus(),'mediafx:name');
});
const target={key:'replacement',label:'Volume',detail:'Track 7',format:v=>Math.round(v*100)+'%',get:()=>.5,set:()=>{throw Error('A repair must never audition');}};
function repair(){let value={target:'missing',heel:.8,toe:.2},targets=[target],focused='',fail=false;const ui=closure.createTargetRepair({...base,focus:id=>focused=id});const open=()=>ui.open({source:'CTRL 1 · Expression',label:'Guitar · Delay Mix',focus:'expr:replace',read:()=>value,targets:()=>targets,values:[{label:'Heel',value:value.heel},{label:'Toe',value:value.toe}],apply:t=>{if(fail)return false;value={...value,target:t.key};return true;}});return {ui,open,value:()=>value,focus:()=>focused,remove:()=>targets=[],change:()=>value.heel=.7,fail:v=>fail=v};}
test('repair cancel and Back restore exact mapping focus; review preserves inverted range and changes only on apply',()=>{
  const r=repair();r.open();r.ui.action('repair:target:replacement');assert.match(r.ui.overlay(),/80%/);assert.match(r.ui.overlay(),/20%/);assert.equal(r.value().target,'missing');r.ui.back();assert.equal(r.value().target,'missing');assert.equal(r.focus(),'expr:replace');r.open();r.ui.action('repair:target:replacement');r.ui.action('repair:apply');assert.deepEqual(r.value(),{target:'replacement',heel:.8,toe:.2});assert.equal(r.focus(),'expr:replace');
});
test('repair rejects stale mapping, vanished replacement and failed apply without losing the original',()=>{
  const r=repair();r.open();r.ui.action('repair:target:replacement');r.change();r.ui.action('repair:apply');assert.match(r.ui.snapshot().error,/mapping changed/);assert.equal(r.value().target,'missing');r.ui.back();r.open();r.ui.action('repair:target:replacement');r.fail(true);r.ui.action('repair:apply');assert.match(r.ui.snapshot().error,/Could not apply/);assert.equal(r.value().target,'missing');r.remove();r.ui.action('repair:apply');assert.match(r.ui.snapshot().error,/no longer available/);
});
function sourceEditors(){
  const r=runtime();let expressionFail=false,focused='',expressionSaved={nextId:2,ports:[{type:'expression',calibration:{heel:0,toe:1},mappings:[{id:'broken',target:'missing',label:'Mix',detail:'Deleted delay',heel:.8,toe:.2}],switches:[{hardware:'momentary',press:'none',hold:'none',change:'none',mappings:[{target:'missing',label:'Mix',detail:'Deleted delay',condition:'held',active:.65,inactive:.15}]},{hardware:'momentary',mappings:[]}]},{type:'expression',mappings:[],switches:[]}]},midiSaved=[{id:'midi-1',device:'usb',source:{kind:'cc',channel:1,number:21},behavior:'continuous',enabled:true,controls:[{kind:'parameter',key:'missing',label:'Mix',detail:'Deleted delay',low:.7,high:.2},{kind:'action',key:'track:1',trigger:'press'}]}];
  const repair=r.w.SegnoMediaClosure.createTargetRepair({...base,focus:id=>focused=id});
  const expression=r.w.createExpressionStudy({...base,repair:spec=>repair.open(spec),read:()=>expressionSaved,write:v=>{if(expressionFail)return false;expressionSaved=copy(v);return true;},targets:()=>[target],destinations:()=>[],switchBindings:()=>[],dispatchSwitch:()=>{},readLatched:()=>[[false,false],[false,false]],writeLatched:()=>{},controlsChanged:()=>{}});
  const midi=r.w.createMidiControlsStudy({...base,repair:spec=>repair.open(spec),read:()=>midiSaved,write:v=>{midiSaved=copy(v);return true;},readSettings:()=>({enabled:true}),writeSettings:()=>true,targets:()=>[target],destinations:()=>[],dispatch:()=>{},changed:()=>{}});
  return {expression,midi,repair,failExpression:v=>expressionFail=v,focus:()=>focused,expressionSaved:()=>copy(expressionSaved),midiSaved:()=>copy(midiSaved)};
}
test('expression repair belongs to draft; Cancel setup restores it and Save preserves range and calibration',()=>{
  const s=sourceEditors();s.expression.body();s.expression.action('expr:replace');s.repair.action('repair:target:replacement');s.repair.action('repair:apply');assert.equal(s.expression.snapshot().draft.ports[0].mappings[0].target,'replacement');assert.equal(s.expressionSaved().ports[0].mappings[0].target,'missing');assert.equal(s.focus(),'expr:replace');s.expression.action('expr:cancel');assert.equal(s.expression.snapshot().draft.ports[0].mappings[0].target,'missing');s.expression.action('expr:replace');s.repair.action('repair:target:replacement');s.repair.action('repair:apply');s.failExpression(true);s.expression.action('expr:save');assert.equal(s.expressionSaved().ports[0].mappings[0].target,'missing');assert.equal(s.expression.snapshot().draft.ports[0].mappings[0].target,'replacement');assert.match(s.expression.snapshot().notice,/Could not save/);s.failExpression(false);s.expression.action('expr:save');const c=s.expressionSaved().ports[0];assert.equal(c.mappings[0].heel,.8);assert.equal(c.mappings[0].toe,.2);assert.deepEqual(c.calibration,{heel:0,toe:1});
});
test('external switch repair preserves condition and values, returns to selected control and waits for Save',()=>{
  const s=sourceEditors();s.expression.body();s.expression.action('expr:type:single');s.expression.action('expr:switch:panel:controls');s.expression.action('expr:switch:control:parameter%3Amissing');s.expression.action('expr:switch:repair-control');s.repair.action('repair:target:replacement');s.repair.action('repair:apply');assert.equal(s.expression.snapshot().switches.control,'parameter:replacement');assert.equal(s.expressionSaved().ports[0].switches[0].mappings[0].target,'missing');assert.equal(s.focus(),'expr:switch:repair-control');s.expression.action('expr:save');const m=s.expressionSaved().ports[0].switches[0].mappings[0];assert.equal(m.target,'replacement');assert.equal(m.condition,'held');assert.equal(m.active,.65);assert.equal(m.inactive,.15);
});
test('MIDI repair preserves source, action siblings and inverted endpoints; cancel/save stay with mapping owner',()=>{
  const s=sourceEditors(),before=s.midiSaved();s.midi.action('midi:edit:midi-1');assert.match(s.midi.body(),/Repair control/);s.midi.action('midi:repair:0');s.repair.action('repair:target:replacement');s.repair.action('repair:apply');assert.equal(s.focus(),'midi:repair:0');assert.deepEqual(s.midiSaved(),before);s.midi.action('midi:cancel');assert.deepEqual(s.midiSaved(),before);s.midi.action('midi:edit:midi-1');s.midi.action('midi:repair:0');s.repair.action('repair:target:replacement');s.repair.action('repair:apply');s.midi.action('midi:save');const m=s.midiSaved()[0];assert.equal(m.controls[0].key,'replacement');assert.equal(m.controls[0].low,.7);assert.equal(m.controls[0].high,.2);assert.deepEqual(m.source,before[0].source);assert.deepEqual(m.controls[1],before[0].controls[1]);
});
test('storage estimate changes with low-space fixture and never gives USB recording time',()=>{
  const r=runtime(),ui=r.w.createStorageStudy({...base,recordingFormat:()=>({sampleRate:48000,bytesPerSample:3,channels:2,streams:1}),active:()=>true,media:()=>({usbConnected:true}),stopPreview:()=>{},disconnect:()=>{}});assert.equal(ui.snapshot().recordingEstimate.seconds,218750);ui.simulate({low:true});assert.equal(ui.snapshot().recordingEstimate.seconds,0);assert.match(ui.body(),/No recording space/);assert.doesNotMatch(ui.body(),/USB recording/);
});

test('Storage follows current recording format, known free bytes and unavailable capacity without snapshot recursion',()=>{
 const r=runtime();let rate=48000;
 const ui=r.w.createStorageStudy({...base,recordingFormat:()=>({sampleRate:rate,bytesPerSample:3,channels:2,streams:1}),active:()=>true,media:()=>({usbConnected:true}),stopPreview:()=>{},disconnect:()=>{}});
 assert.equal(ui.snapshot().recordingEstimate.seconds,218750);rate=96000;
 assert.equal(ui.snapshot().recordingEstimate.seconds,109375);assert.match(ui.body(),/96 kHz/);
 const free=1e9+96000*3*2*3600;ui.simulate({freeBytes:free});assert.equal(ui.snapshot().recordingEstimate.seconds,3600);assert.match(ui.body(),/3.1 GB free/);assert.equal(ui.capacity().freeBytes,free);
 ui.simulate({freeBytes:null});assert.equal(ui.snapshot().recordingEstimate.available,false);assert.match(ui.body(),/Recording time unavailable/);assert.match(ui.body(),/Free space unavailable/);assert.doesNotMatch(ui.body(),/GB free<\/strong><span>of 128/);
 ui.simulate({freeBytes:64e9});rate=null;assert.equal(ui.snapshot().recordingEstimate.available,false);assert.match(ui.body(),/Recording time unavailable/);
});
