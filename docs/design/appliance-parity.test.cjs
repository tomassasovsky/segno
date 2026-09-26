const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {createControllerModel,createUI}=require('./appliance-parity-study.js');
const clone=v=>JSON.parse(JSON.stringify(v));
const context={window:{},performance:{now:()=>0}};
vm.runInNewContext(fs.readFileSync(path.join(__dirname,'midi-sync-study.js'),'utf8'),context);
function sync(){let settings={},stamp=0,bpm=120,playing=false,recording=false,fail=false;const events=[],ports=[{id:'din',name:'MIDI DIN',connection:'DIN',online:true},{id:'usb',name:'USB MIDI',connection:'USB',online:true}];
 const ui=context.window.createMidiSyncStudy({read:()=>settings,write:s=>{if(fail)return false;settings=s;return true;},ports:()=>ports,tempo:()=>bpm,setTempo:v=>bpm=v,capturing:()=>recording,transport:v=>{events.push(v);playing=v!=='stop';},running:()=>playing,clockReady:()=>events.push('ready'),render:()=>{},focus:()=>{},button:()=>'',escape:v=>v,now:()=>stamp});
 return {ui,settings:()=>settings,stamp:v=>stamp=v,playing:v=>playing=v,recording:v=>recording=v,fail:v=>fail=v,events,ports};
}
test('internal sender offsets have the source-backed range and preserve tempo',()=>{
 const f=sync();f.ui.action('sync:output-clock:din');f.ui.action('sync:offset:din');f.ui.turn(30);assert.equal(f.ui.snapshot().editing.value,10);f.ui.finish();
 f.stamp(100);f.ui.tick();let event=f.ui.snapshot().outgoing.find(e=>e.type==='clock');assert.equal(event.offsetMs,10);assert.equal(event.scheduledAt-event.nominalAt,10);assert.equal(f.ui.snapshot().tempo,120);
 f.ui.input('sync:offset:din',-10);f.stamp(200);f.ui.tick();event=f.ui.snapshot().outgoing.at(-1);assert.equal(event.offsetMs,-10);assert.equal(event.scheduledAt-event.nominalAt,-10);
 f.ui.action('sync:offset:din');f.ui.turn(5);f.ui.finish(true);assert.equal(f.settings().outputs.din.offsetMs,-10);f.ui.resetOffset('sync:offset:din');assert.equal(f.settings().outputs.din.offsetMs,0);
});
test('clock offset storage failures preserve the previous value',()=>{const f=sync();f.ui.action('sync:output-clock:din');f.ui.input('sync:offset:din',4);f.fail(true);f.ui.input('sync:offset:din',8);assert.equal(f.settings().outputs.din.offsetMs,4);assert.ok(f.ui.snapshot().notice.includes('Could not save'));});
test('Thru forwards DIN input once and never creates a local feedback/duplicate clock path',()=>{
 const f=sync();f.ui.action('sync:output-clock:din');f.ui.action('sync:output-clock:usb');f.ui.action('sync:thru');
 const note={kind:'note',channel:2,note:60,value:100};assert.equal(f.ui.receiveMessage('din',note,50),true);note.value=1;
 assert.equal(f.ui.receiveMessage('usb',{kind:'note'},50),false);assert.equal(f.ui.receiveMessage('din',{kind:'note'},50,'output'),false);assert.equal(f.ui.receiveMessage('din',{forwarded:true},50),false);
 f.ui.receive('din','clock',60);f.stamp(100);f.ui.tick();const out=f.ui.snapshot().outgoing;
 assert.equal(out.filter(e=>e.port==='din').length,2);assert.equal(out.find(e=>e.message?.kind==='note').message.value,100);assert.ok(out.filter(e=>e.port==='din').every(e=>e.forwarded&&e.offsetMs===0));assert.ok(out.some(e=>e.port==='usb'&&!e.forwarded));
 f.ports[0].online=false;assert.equal(f.ui.receiveMessage('din',{},70),false);
});
test('external clock/loss/transport remain independent of Thru and outgoing offsets',()=>{
 const f=sync();f.ui.action('sync:output-clock:din');f.ui.input('sync:offset:din',-8);f.ui.action('sync:source:usb');f.ui.action('sync:follow:true');f.ui.action('sync:loss:stop');
 f.ui.receive('usb','start',0);for(let i=0;i<9;i++)f.ui.receive('usb','clock',i*60000/(120*24));assert.equal(f.ui.snapshot().state,'synced');assert.ok(f.events.includes('start'));
 assert.ok(f.ui.snapshot().outgoing.filter(e=>e.type==='clock').every(e=>e.offsetMs===0));f.ui.input('sync:offset:din',10);assert.equal(f.settings().outputs.din.offsetMs,-8);
 f.stamp(2000);f.ui.tick();assert.equal(f.ui.snapshot().state,'lost');assert.ok(f.events.includes('stop'));
 f.recording(true);f.ui.action('sync:source:internal');assert.equal(f.settings().source,'usb');
});
function controller(extra={}){let stamp=0,stored=null,block='',fail=false;const model=createControllerModel({read:()=>({connected:true,target:'test-controller',updateSupported:true,installed:'1.0.0',protocol:3,versionSource:'last-flashed',pending:{version:'1.1.0',protocol:4,verified:true,target:'test-controller'},...extra}),write:s=>{if(fail)return false;stored=s;return true;},blocked:()=>block,now:()=>stamp});return {model,stored:()=>stored,stamp:v=>stamp=v,block:v=>block=v,fail:v=>fail=v};}
test('controller programming requires a verified pending package and an idle rig',()=>{
 const f=controller();f.block('Finish recording first.');assert.equal(f.model.start(),false);f.block('');assert.equal(f.model.start(),true);assert.equal(f.model.available(),false);assert.equal(f.model.start(),false);
 for(const extra of [{connected:false},{pending:null},{updateSupported:false},{pending:{version:'1.1.0',verified:false,target:'test-controller'}},{pending:{version:'1.1.0',verified:true,target:'wrong-controller'}}])assert.equal(controller(extra).model.start(),false);
});
test('controller retry campaign never launders an interrupted write into not-started',()=>{
 const f=controller();f.model.start();f.model.progress(70);f.model.simulate({retryReady:true});f.model.fail('interrupted');assert.equal(f.model.snapshot().attempt,2);f.model.progress(10);f.model.simulate({retryReady:true});f.model.fail('not-started');assert.equal(f.model.snapshot().attempt,3);f.model.fail('not-started');assert.equal(f.model.snapshot().phase,'failed');assert.equal(f.model.snapshot().failureClass,'interrupted');assert.equal(f.model.available(),false);assert.equal(f.model.snapshot().installed,'1.0.0');
 const untouched=controller();untouched.model.start();for(let i=0;i<3;i++)untouched.model.fail('not-started');assert.equal(untouched.model.snapshot().failureClass,'not-started');assert.equal(untouched.model.available(),true);
});
test('controller success requires readback, re-enumeration and durable state',()=>{
 const f=controller();f.model.start();f.model.progress(100);assert.equal(f.model.complete({running:false,readbackVerified:true,version:'1.1.0'}),false);assert.equal(f.model.complete({running:true,readbackVerified:true,version:'different'}),false);assert.equal(f.model.complete({running:true,version:'1.1.0'}),false);assert.equal(f.model.snapshot().installed,'1.0.0');
 assert.equal(f.model.complete({running:true,readbackVerified:true,version:'1.1.0',protocol:4}),true);assert.equal(f.stored().installed,'1.1.0');assert.equal(f.stored().protocol,4);assert.equal(f.stored().pending,null);assert.equal(f.stored().versionSource,'last-flashed');
 const failed=controller();failed.model.start();failed.model.progress(95);failed.fail(true);assert.equal(failed.model.complete({running:true,readbackVerified:true,version:'1.1.0'}),false);assert.equal(failed.model.snapshot().phase,'failed');assert.equal(failed.model.snapshot().installed,'1.0.0');
});
test('controller disconnect and stall preserve the failure boundary and cap retries',()=>{
 const f=controller();f.model.start();f.model.progress(55);f.model.simulate({connected:false});assert.equal(f.model.snapshot().failureClass,'interrupted');assert.equal(f.model.snapshot().phase,'failed');
 const stalled=controller();stalled.model.start();stalled.stamp(6*60*1000);stalled.model.tick();assert.equal(stalled.model.snapshot().attempt,2);stalled.stamp(12*60*1000);stalled.model.tick();assert.equal(stalled.model.snapshot().phase,'failed');
});
test('reference notice bytes match their real checkout source files',()=>{
 const c={window:{}};vm.runInNewContext(fs.readFileSync(path.join(__dirname,'appliance-reference-notices.js'),'utf8'),c);
 assert.equal(c.window.SegnoApplianceReferenceNotices.length,3);for(const n of c.window.SegnoApplianceReferenceNotices)assert.equal(n.text,fs.readFileSync(path.join(__dirname,'../..',n.source),'utf8'));
});
test('About hides unknown facts and labels preview/source limitations',()=>{
 const ui=createUI({button:(id,text)=>`<button data-action="${id}">${text}</button>`,header:title=>`<h1>${title}</h1>`,escape:s=>String(s),render:()=>{},focus:()=>{},facts:()=>({appVersion:'Example version'}),licenses:()=>[{name:'Real notice',text:'Actual text'}]});
 assert.ok(ui.body().includes('Example version'));assert.ok(!ui.body().includes('Serial'));assert.ok(ui.body().includes('simulated'));ui.action('appliance:licenses');ui.action('appliance:license:0');assert.ok(ui.body().includes('Actual text'));assert.ok(ui.body().includes('complete license registry'));
});
