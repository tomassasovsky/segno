const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const model=require('./performance-recording-model.js');
const format={sampleRate:10,channels:2,bitDepth:24,partBytes:104},identity={id:'take-1',name:'Evening.wav',sessionId:'one',sessionName:'Evening',startedAt:0,output:'Main output'};
const take=()=>model.create(identity,format).take;
test('frame-aligned parts consume headers and stay within capacity and part boundary',()=>{
 const before=take(),result=model.advance(before,25,{freeBytes:308,reserveBytes:100});
 assert.equal(result.stopped,true);assert.equal(result.bytesUsed,208);assert.equal(result.take.frames,20);assert.equal(result.take.seconds,2);
 assert.deepEqual(result.take.parts.map(p=>[p.index,p.frames,p.bytes]),[[1,10,104],[2,10,104]]);assert.equal(model.valid(result.take),true);assert.deepEqual(before,take());
});
test('successive checkpoints never pay existing bytes or headers twice',()=>{
 const first=model.advance(take(),5,{freeBytes:1000,reserveBytes:100});assert.equal(first.bytesUsed,74);
 const next=model.advance(first.take,15,{freeBytes:926,reserveBytes:100});assert.equal(next.bytesUsed,134);assert.equal(next.take.bytes,208);assert.equal(next.take.parts.length,2);
});
test('remaining time follows sample rate, channels, bits, reserve and unknown capacity',()=>{
 assert.equal(model.remaining(take(),{freeBytes:308,reserveBytes:100}),2);
 const high=model.create(identity,{...format,sampleRate:20}).take;assert.equal(model.remaining(high,{freeBytes:308,reserveBytes:100}),1);
 assert.equal(model.remaining(take(),{freeBytes:null,reserveBytes:100}),null);assert.equal(model.remaining(take(),{freeBytes:100,reserveBytes:100}),0);
 assert(model.advance(take(),4,{freeBytes:NaN,reserveBytes:0}).error);
 for(const f of [{...format,channels:0},{...format,bitDepth:12},{...format,partBytes:44}])assert(model.create(identity,f).error);
});
test('one take exports and plays its complete ordered sequence across an exact boundary',()=>{
 const t=model.advance(take(),25,{freeBytes:1000,reserveBytes:0}).take,file=model.asset(t,true),plan=model.manifest(file);
 assert.equal(file.id,'take-1');assert.equal(file.performance.recovered,true);assert.equal(plan.parts.length,3);assert.deepEqual(plan.parts.map(p=>p.offsetFrames),[0,10,20]);
 assert.deepEqual(model.locate(file,1),{id:'take-1-part-2',index:2,offsetFrames:0,offsetSeconds:0});assert.equal(model.locate(file,2.5).ended,true);
 const exported={...structuredClone(file),id:'usb-export-2'};assert.equal(model.manifest(exported).takeId,'take-1');assert.equal(model.locate(exported,1).id,'take-1-part-2');
 const damaged=structuredClone(file);damaged.parts.reverse();assert(model.manifest(damaged).error);assert.equal(model.manifest(file).parts[0].index,1);
});
test('full-sized parts cannot be reordered and each part index and source identity are checked',()=>{
 const file=model.asset(model.advance(take(),30,{freeBytes:1000,reserveBytes:0}).take);
 assert.deepEqual(file.parts.map(p=>p.frames),[10,10,10]);
 for(const change of [f=>f.parts.reverse(),f=>f.parts[1].index=3,f=>f.parts[1].id='another-take-part-2']){
  const bad=structuredClone(file);change(bad);assert(model.manifest(bad).error);assert(model.locate(bad,1).error);
 }
 assert.equal(model.manifest(file).parts.length,3);
});
function harness(saved){
 let value=saved||{nextId:1,active:null,last:null},freeBytes=10000,reserveBytes=100,clock=0,fail=false,timers=[],files=[],writes=[];
 const world={window:{SegnoPerformanceRecording:model},structuredClone,Date,document:{querySelectorAll:()=>[]},setTimeout:fn=>{timers.push(fn);return timers.length;},clearTimeout:()=>{}};
 vm.runInNewContext(fs.readFileSync(__dirname+'/performance-recording-study.js','utf8'),world);
 const ui=world.window.createPerformanceRecordingStudy({now:()=>clock,capacity:()=>({freeBytes,reserveBytes}),recordingFormat:()=>format,read:()=>value,
  write:(next,file,allocation)=>{if(fail)return false;assert(allocation.bytesUsed>=0);assert(freeBytes-allocation.bytesUsed>=reserveBytes);freeBytes+=allocation.bytesReleased-allocation.bytesUsed;writes.push(allocation.bytesUsed);value=structuredClone(next);if(file)files.push(structuredClone(file));return true;},
  audioReady:()=>true,session:()=>({id:'one',name:'Evening'}),button:(id,label)=>'<button data-action="'+id+'">'+label+'</button>',header:()=>'',escape:String,icon:()=>'',render:()=>{},notice:()=>{},focus:()=>{},open:()=>{},reveal:()=>{}});
 return {ui,get value(){return structuredClone(value);},get free(){return freeBytes;},get files(){return files;},get writes(){return writes;},setFree:v=>freeBytes=v,fail:v=>fail=v,advance:ms=>{clock+=ms;ui.tick();},finish:()=>{for(const fn of timers.splice(0))fn();}};
}
test('study commits format and allocation before finalization; one catalogue take contains ordered parts',()=>{
 const h=harness();h.ui.action('recorder:start');h.advance(5200);assert.equal(h.value.active.frames,52);assert.equal(h.value.active.parts.length,6);
 const used=h.value.active.bytes;assert.equal(h.free,10000-used);h.ui.action('recorder:stop');h.finish();
 assert.equal(h.ui.phase(),'saved');assert.equal(h.files.length,1);assert.equal(h.files[0].parts.length,6);assert.equal(h.free,10000-used);assert.equal(h.writes.at(-1),0);
});
test('failed checkpoint preserves only durable frames and retry cannot invent later audio',()=>{
 const h=harness();h.ui.action('recorder:start');h.advance(5200);const durable=h.value,free=h.free;
 h.fail(true);h.advance(5200);assert.equal(h.ui.phase(),'recovered');assert.equal(h.ui.snapshot().seconds,5.2);assert.deepEqual(h.value,durable);assert.equal(h.free,free);
 h.fail(false);h.ui.action('recorder:save-recovered');h.finish();assert.equal(h.files[0].seconds,5.2);assert.equal(h.files[0].performance.recovered,true);
});
test('reserve automatically stops a long tick at valid parts, preserving a recoverable take',()=>{
 const h=harness();h.setFree(308);h.ui.action('recorder:start');assert.equal(h.ui.snapshot().warning,true);h.advance(3000);
 assert.equal(h.ui.phase(),'recovered');assert.equal(h.free,100);assert.equal(h.ui.snapshot().seconds,2);assert.equal(h.value.active.parts.length,2);
 h.ui.action('recorder:save-recovered');h.finish();assert.equal(h.files[0].seconds,2);assert.equal(h.free,100);
});
test('unknown capacity refuses start and stops ongoing capture at its last checkpoint',()=>{
 const h=harness();h.setFree(null);h.ui.action('recorder:start');assert.equal(h.ui.phase(),'ready');assert.equal(h.value.active,null);assert.match(h.ui.snapshot().error,/unavailable/);
 h.setFree(10000);h.ui.action('recorder:start');h.advance(5100);h.setFree(null);h.advance(300);assert.equal(h.ui.phase(),'recovered');assert.equal(h.ui.snapshot().seconds,5.1);
});
test('failed final publication retains exact parts and Cancel discard preserves them',()=>{
 const h=harness();h.ui.action('recorder:start');h.advance(5100);h.ui.action('recorder:stop');h.fail(true);h.finish();assert.equal(h.ui.phase(),'recovered');assert.equal(h.files.length,0);
 const prior=h.value;h.ui.action('recorder:discard');h.ui.action('recorder:cancel-discard');assert.deepEqual(h.value,prior);
 h.fail(false);h.ui.action('recorder:save-recovered');h.finish();assert.equal(h.files.length,1);assert.equal(h.files[0].frames,51);
});
test('cold recovery uses committed frames and never adds downtime',()=>{
 const first=harness();first.ui.action('recorder:start');first.advance(5100);const next=harness(first.value);next.advance(7200000);
 assert.equal(next.ui.phase(),'recovered');assert.equal(next.ui.snapshot().seconds,5.1);assert.equal(next.ui.snapshot().pending.frames,51);
});

test('discard releases only committed take bytes, once, after successful publication',()=>{
 const h=harness();h.ui.action('recorder:start');h.advance(5100);h.ui.simulate({interrupt:true});const charged=h.free;
 h.ui.action('recorder:discard');h.ui.action('recorder:cancel-discard');assert.equal(h.free,charged);h.fail(true);h.ui.action('recorder:discard');h.ui.action('recorder:confirm-discard');assert.equal(h.free,charged);assert(h.value.active);
 h.fail(false);h.ui.action('recorder:discard');h.ui.action('recorder:confirm-discard');assert.equal(h.free,10000);assert.equal(h.value.active,null);h.ui.action('recorder:confirm-discard');assert.equal(h.free,10000);
});
