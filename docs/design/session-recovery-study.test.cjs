const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
function setup(){
  const world={window:{},structuredClone};vm.createContext(world);
  for(const file of ['performance-recording-model.js','recorded-audio-model.js','session-recovery-model.js','session-recovery-study.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,file),'utf8'),world);
  const files=[{id:'present',name:'Backing.wav',seconds:24,format:'WAV'}];
  const entry={id:'session-2',name:'Set',snapshot:{audioLibrary:{prepared:['missing'],backing:{id:'missing',name:'Backing.wav',seconds:24,format:'WAV'}}}};
  let commits=0,staged=0,canceled=0,ready=true,result=true;
  const ui=world.window.createSessionRecoveryStudy({button:(id,label)=>'<button data-action="'+id+'">'+label+'</button>',header:()=>'',icon:()=>'',escape:String,render:()=>{},setFocus:()=>{},files:()=>files,ready:()=>ready,playing:()=>false,commit:()=>{commits++;return result;},done:()=>staged++,cancel:()=>canceled++,openDevice:()=>{}});
  ui.begin(entry);
  const repair=()=>{ui.action('recover:choose:missing');ui.action('recover:file:present');};
  return {ui,files,entry,repair,ready:value=>ready=value,result:value=>result=value,counts:()=>({commits,staged,canceled})};
}
test('chosen backing changed after repair requires new confirmation and never commits stale audio',()=>{
  const s=setup();s.repair();s.files[0].seconds=48;s.ui.action('recover:open');
  assert.equal(s.counts().commits,0);assert.match(s.ui.snapshot().error,/Audio changed/);assert.deepEqual(JSON.parse(JSON.stringify(s.ui.snapshot().draft.snapshot)),s.entry.snapshot);
  s.repair();s.ui.action('recover:open');assert.equal(s.counts().commits,1);assert.equal(s.counts().staged,1);
});
test('commit failure retains pending choices; Cancel leaves the source and never stages',()=>{
  const s=setup(),before=structuredClone(s.entry);s.repair();s.result('Saved session changed');s.ui.action('recover:open');
  assert.equal(s.ui.snapshot().draft.snapshot.audioLibrary.prepared[0],'present');assert.match(s.ui.snapshot().error,/Saved session changed/);s.ui.action('recover:cancel');
  assert.deepEqual(s.entry,before);assert.deepEqual(s.counts(),{commits:1,staged:0,canceled:1});assert.equal(s.ui.snapshot().draft,null);
});
test('disconnected device blocks Open without dropping pending media repair; picker Back retains draft',()=>{
  const s=setup();s.ui.action('recover:choose:missing');s.ui.back();assert.equal(s.ui.snapshot().choosing,null);assert(s.ui.active());
  s.repair();s.ready(false);s.ui.action('recover:open');assert.equal(s.counts().commits,0);assert.equal(s.ui.snapshot().draft.snapshot.audioLibrary.prepared[0],'present');
  s.ready(true);s.ui.action('recover:open');assert.equal(s.counts().staged,1);
});
test('a replacement that disappears can itself be replaced without losing the repaired draft',()=>{
 const s=setup();s.repair();s.files.splice(0,1,{id:'second',name:'Second.wav',seconds:24,format:'WAV'});
 assert.match(s.ui.body(),/data-action="recover:choose:present"/);s.ui.action('recover:choose:present');s.ui.action('recover:file:second');assert.equal(s.ui.snapshot().draft.snapshot.audioLibrary.prepared[0],'second');
 s.ui.action('recover:open');assert.deepEqual(s.counts(),{commits:1,staged:1,canceled:0});
});
