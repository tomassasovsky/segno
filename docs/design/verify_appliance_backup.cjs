const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const model=require('./appliance-backup-model.js'),recorded=require('./recorded-audio-model.js'),copy=v=>structuredClone(v);
const performance=require('./performance-recording-model.js');
function performanceAsset(id='performance-1'){
  const {take}=performance.create({id,name:'Long performance.wav',sessionId:'show',sessionName:'Show',output:'Main',startedAt:1},{sampleRate:100,channels:2,bitDepth:16,partBytes:444});
  return performance.asset(performance.advance(take,250,{freeBytes:2000,reserveBytes:0}).take);
}
function payload(name='Current'){
  const backing={id:'backing-'+name,name:'Backing.wav',seconds:24,format:'WAV'},layer={id:'take-1',label:'Original',beats:4,regions:[{offsetBeats:14,beats:4}],gain:.6};
  const source={racks:[],loopSettings:{tempo:120,mode:'multi'},recordedParts:{'Track 1':['Guitar']},trackLayers:{'Track 1':{layers:[layer]}},trackLength:{'Track 1':{durationBeats:16,audio:[]}},audioLibrary:{prepared:[backing.id],backing,trackImports:{}}};
  const assets=recorded.materializeRecorded(source,[],'session-'+name);
  return {sessions:{current:{id:'session-'+name,name,snapshot:assets.snapshot},sessions:[],nextId:2,folders:['Shows']},audio:{files:[backing],recordedFiles:assets.files},presets:{saved:[{id:'preset-1',name:'Warm'}],packages:[]},settings:{rig:{tempo:120,leds:['Blue']},wifi:{network:'Stage'},display:{brightness:65}}};
}
const archive=(value=payload('Backup'),id='archive-1')=>model.pack(value,{id,name:'Appliance backup',created:1}).archive;
test('complete envelope preserves all four sections, exact recording regions and isolated content copies',()=>{
  const data=payload(),before=copy(data),a=archive(data);assert(model.inspect(a).valid);assert.deepEqual(a.manifest,{sessions:1,audio:1,recordedAudio:1,presets:1,settings:3});
  const restored=model.restore(a,payload('Other'));assert.deepEqual(restored.payload,data);assert.deepEqual(data,before);assert.deepEqual(restored.payload.sessions.current.snapshot.trackLayers['Track 1'].layers[0].regions,[{offsetBeats:14,beats:4}]);
  restored.payload.settings.wifi.network='Modified';assert.equal(a.contents.settings.wifi.network,'Stage');assert.equal(data.settings.wifi.network,'Stage');
});
test('every section, current session identity and unique catalogues are required',()=>{
  for(const field of ['sessions','audio','presets','settings']){const value=payload();delete value[field];assert.equal(model.validate(value).valid,false,field);}
  const duplicate=payload();duplicate.sessions.sessions=[copy(duplicate.sessions.current)];assert.match(model.validate(duplicate).error,/conflicting identities/);
  const missing=payload();delete missing.sessions.current.snapshot;assert.equal(model.validate(missing).valid,false);
  const ids=payload();ids.audio.files.push(copy(ids.audio.files[0]));assert.equal(model.validate(ids).valid,false);
});
test('backup refuses missing or damaged recorded/backing audio, changed exact content, and unmaterialized populated tracks',()=>{
  for(const mutate of [p=>p.audio.recordedFiles=[],p=>p.audio.files=[],p=>p.audio.recordedFiles[0].damaged=true,p=>p.audio.recordedFiles[0].seconds=3,p=>p.audio.recordedFiles[0].integrity='changed',p=>delete p.sessions.current.snapshot.trackLayers,p=>p.sessions.current.snapshot.trackLayers['Track 1'].layers=[]]){
    const p=payload();mutate(p);assert.equal(model.validate(p).valid,false);
  }
  const p=payload();delete p.sessions.current.snapshot.trackLayers['Track 1'].layers[0].recordedAudio;assert.equal(model.validate(p).valid,false);
});
test('verified imports can represent populated tracks without recorded layers, but unresolved imported sources cannot',()=>{
  const p=payload(),s=p.sessions.current.snapshot;delete s.trackLayers;p.audio.recordedFiles=[];s.audioLibrary.trackImports={0:{file:copy(p.audio.files[0]),timing:{seconds:24}}};assert.equal(model.validate(p).valid,true);
  p.audio.files[0].seconds=25;assert.equal(model.validate(p).valid,false);
});
test('history-only original audio is required even when live layers are empty',()=>{
  const p=payload(),s=p.sessions.current.snapshot,layer=copy(s.trackLayers['Track 1'].layers[0]);s.recordedParts['Track 1']=[];s.trackLayers['Track 1'].layers=[];s.editHistory={serial:1,tracks:[{undo:[],redo:[{id:1,label:'Recording',before:{0:{layers:{layers:[]}}},after:{0:{layers:{layers:[layer]}}}}]}]};
  assert.equal(model.validate(p).valid,true);p.audio.recordedFiles=[];assert.equal(model.validate(p).valid,false);
});
test('complete backup and restore retain the ordered performance parts as one recording',()=>{
  const p=payload(),file=performanceAsset();p.audio.files.push(file);p.sessions.current.snapshot.audioLibrary.backing=copy(file);
  const before=copy(p),a=archive(p);assert.equal(model.inspect(a).valid,true);assert.deepEqual(model.restore(a,payload('Other')).payload,p);
  assert.deepEqual(a.contents.audio.files.at(-1).parts.map(part=>part.id),['performance-1-part-1','performance-1-part-2','performance-1-part-3']);assert.deepEqual(p,before);
});
test('backup and restore refuse reversed, missing, unreadable and incomplete multipart audio even when unused',()=>{
  for(const mutate of [f=>f.parts.reverse(),f=>f.parts.splice(1,1),f=>f.parts[1].unreadable=true,f=>delete f.performance,f=>delete f.parts,f=>f.frames++,f=>f.format='MP3']){
    const p=payload();p.audio.files.push(performanceAsset());const a=archive(p);mutate(p.audio.files.at(-1));mutate(a.contents.audio.files.at(-1));const before=copy(p);
    assert.equal(model.validate(p).valid,false);assert(model.pack(p,{id:'bad',name:'Bad',created:1}).error);assert.equal(model.inspect(a).valid,false);assert(model.restore(a,payload()).error);assert.deepEqual(p,before);
  }
});
test('a valid multipart inventory entry must still match the saved backing and imported performance identity',()=>{
  for(const use of ['backing','import']){
    const p=payload(),file=performanceAsset(),s=p.sessions.current.snapshot;p.audio.files.push(file);
    if(use==='backing')s.audioLibrary.backing=copy(file);else s.audioLibrary.trackImports={0:{file:copy(file),timing:{seconds:2.5}}};
    assert.equal(model.validate(p).valid,true);const replacement=performanceAsset('different-original');replacement.id=file.id;p.audio.files[p.audio.files.length-1]=replacement;
    assert.equal(performance.manifest(replacement).error,undefined);assert.equal(model.validate(p).valid,false,use);
  }
});
test('repaired imports update active and Undo/Redo layer sources together, allowing a complete backup',()=>{
  const recovery=require('./session-recovery-model.js'),p=payload(),s=p.sessions.current.snapshot,old=p.audio.files[0],replacement={...old,id:'replacement',name:'Replacement.wav'};
  p.audio.recordedFiles=[];s.trackLayers['Track 1']={layers:[{id:'import-1',sourceFile:old.id,beats:8,gain:.6,regions:[{offsetBeats:4,beats:8}]}]};s.audioLibrary.trackImports={0:{file:copy(old),state:'stopped',speed:1,timing:{seconds:old.seconds,loopBeats:16}}};
  const state={layers:copy(s.trackLayers['Track 1']),length:copy(s.trackLength['Track 1']),imported:copy(s.audioLibrary.trackImports[0]),playing:false};
  s.editHistory={tracks:[{undo:[{id:1,label:'Import',before:{0:copy(state)},after:{0:copy(state)}}],redo:[{id:2,label:'Peel',before:{0:copy(state)},after:{0:copy(state)}}]}]};
  const before=copy(s);p.audio.files=[replacement];assert.equal(model.validate(p).valid,false);p.sessions.current.snapshot=recovery.repair(s,old.id,replacement,p.audio.files);
  const repaired=p.sessions.current.snapshot;assert.equal(repaired.trackLayers['Track 1'].layers[0].sourceFile,replacement.id);assert.deepEqual(recorded.importedIds(repaired),[replacement.id]);assert.deepEqual(recovery.inspect(repaired,p.audio.files),[]);
  assert.equal(model.validate(p).valid,true);assert.equal(model.inspect(archive(p)).valid,true);assert.deepEqual(s,before);assert.deepEqual(repaired.trackLength,before.trackLength);assert.deepEqual(repaired.audioLibrary.trackImports[0].timing,before.audioLibrary.trackImports[0].timing);
});
test('unsupported, marked damaged and incomplete packages cannot be restored',()=>{
  for(const mutate of [a=>a.version=2,a=>a.damaged=true,a=>delete a.contents.settings,a=>a.manifest.recordedAudio=10,a=>delete a.manifest]){
    const a=archive();mutate(a);assert.equal(model.inspect(a).valid,false);assert(model.restore(a,payload()).error);
  }
  const a=archive();a.manifest=Object.fromEntries(Object.entries(a.manifest).reverse());assert.equal(model.inspect(a).valid,true);
});
test('unreadable non-JSON state is refused without changing it',()=>{
  for(const value of [NaN,Infinity,()=>{},undefined]){const p=payload();p.settings.invalid=value;assert.equal(model.validate(p).valid,false);}
  const p=payload();p.settings.loop=p;assert.equal(model.validate(p).valid,false);
});
function study(){
  const world={window:{},structuredClone};vm.createContext(world);for(const name of ['performance-recording-model.js','recorded-audio-model.js','session-recovery-model.js','appliance-backup-model.js','appliance-backup-study.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,name),'utf8'),world);
  let current=payload(),archives=[archive()],reason='',writes=0,commits=0,restarts=0,failWrite=false,failRestore=false,throwCapture=false;
  const ui=world.window.createApplianceBackupStudy({button:(id,label,css='',extra='')=>'<button data-action="'+id+'" '+extra+'>'+label+'</button>',escape:String,render:()=>{},focus:()=>{},open:()=>{},now:()=>20,blocker:()=>reason,capture:()=>{if(throwCapture)throw Error('Unreadable appliance');return copy(current);},archives:()=>archives,writeArchives:(next,expected)=>{writes++;assert.deepEqual(JSON.parse(JSON.stringify(expected)),archives);if(failWrite)return false;archives=copy(next);return true;},commitRestore:(next,expected)=>{commits++;assert.deepEqual(JSON.parse(JSON.stringify(expected)),current);if(failRestore)return false;current=copy(next);return true;},completed:()=>restarts++});
  return {ui,archive:()=>archives[0],current:()=>current,archives:()=>archives,counts:()=>({writes,commits,restarts}),block:v=>reason=v,failWrite:v=>failWrite=v,failRestore:v=>failRestore=v,throwCapture:v=>throwCapture=v};
}
test('creating a backup first reviews every group; Cancel writes nothing and leaves current and USB data unchanged',()=>{
  const s=study(),current=copy(s.current()),before=copy(s.archives());s.ui.action('appliance-backup:create');assert.equal(s.ui.snapshot().phase,'backup-review');assert.match(s.ui.overlay(),/Loop recordings/);assert.match(s.ui.overlay(),/Backing audio/);assert.match(s.ui.overlay(),/Presets/);assert.match(s.ui.overlay(),/Settings/);
  s.ui.action('appliance-backup:cancel');assert.deepEqual(s.current(),current);assert.deepEqual(s.archives(),before);assert.deepEqual(s.counts(),{writes:0,commits:0,restarts:0});
});
test('existing backup name requires an explicit Keep both or Replace choice and failed replacement preserves it',()=>{
  const s=study(),old=copy(s.archives());s.ui.action('appliance-backup:create');s.ui.action('appliance-backup:save');assert.equal(s.ui.snapshot().phase,'conflict');assert.equal(s.counts().writes,0);
  s.failWrite(true);s.ui.action('appliance-backup:replace');assert.deepEqual(s.archives(),old);assert.match(s.ui.snapshot().error,/previous copies are unchanged/);
  s.failWrite(false);s.ui.action('appliance-backup:keep');assert.equal(s.archives().length,2);assert.equal(s.archives()[0].name,'Appliance backup (2)');assert.deepEqual(s.archives()[1],old[0]);
  s.ui.action('appliance-backup:create');s.ui.action('appliance-backup:save');s.ui.action('appliance-backup:replace');assert.equal(s.archives().length,2);assert(s.archives().some(a=>a.name==='Appliance backup (2)'));
});
test('backup refuses stale current data or a changed USB catalogue after review',()=>{
  for(const mutate of [s=>s.current().settings.display.brightness=25,s=>s.archives().push(archive(payload('Other'),'new-id'))]){
    const s=study();s.ui.action('appliance-backup:create');mutate(s);s.ui.action('appliance-backup:save');assert.equal(s.counts().writes,0);assert.match(s.ui.snapshot().error,/changed/);
  }
});
test('restore needs its own confirmation, preserves data on Cancel, and restarts only after successful whole-state publication',()=>{
  const s=study(),before=copy(s.current()),usb=copy(s.archives());s.ui.action('appliance-backup:row:archive-1');s.ui.action('appliance-backup:review');assert.match(s.ui.overlay(),/Restore and restart/);assert.equal(s.counts().commits,0);s.ui.action('appliance-backup:cancel');assert.deepEqual(s.current(),before);
  s.ui.action('appliance-backup:review');s.ui.action('appliance-backup:restore');assert.deepEqual(s.current(),usb[0].contents);assert.deepEqual(s.archives(),usb);assert.deepEqual(s.counts(),{writes:0,commits:1,restarts:1});
});
test('failed restore retains the exact review and old data for explicit retry; Cancel never restarts',()=>{
  const s=study(),before=copy(s.current());s.ui.action('appliance-backup:row:archive-1');s.ui.action('appliance-backup:review');s.failRestore(true);s.ui.action('appliance-backup:restore');assert.deepEqual(s.current(),before);assert.equal(s.counts().restarts,0);assert(s.ui.pending());assert.match(s.ui.snapshot().error,/Current data is unchanged/);
  s.failRestore(false);s.ui.action('appliance-backup:restore');assert.equal(s.counts().restarts,1);
});
test('device/media/capture/preview blockers are rechecked at Save and Restore, preserving the pending review',()=>{
  for(const reason of ['Connect USB','Reconnect audio','Finish recording','Finish preset preview']){
    const s=study(),before=copy(s.current());s.ui.action('appliance-backup:row:archive-1');s.ui.action('appliance-backup:review');s.block(reason);s.ui.action('appliance-backup:restore');assert.equal(s.counts().commits,0);assert.deepEqual(s.current(),before);assert.equal(s.ui.snapshot().error,reason);assert(s.ui.pending());
    s.ui.action('appliance-backup:cancel');s.ui.action('appliance-backup:create');assert.equal(s.ui.pending(),false);assert.equal(s.counts().writes,0);
  }
});
test('restoring refuses a mutated/disappearing package or changed current settings after confirmation opens',()=>{
  for(const mutate of [s=>s.archive().contents.settings.wifi.network='Changed',s=>s.archives().splice(0,1),s=>s.current().settings.wifi.network='Changed']){
    const s=study();s.ui.action('appliance-backup:row:archive-1');s.ui.action('appliance-backup:review');mutate(s);const before=copy(s.current());s.ui.action('appliance-backup:restore');assert.equal(s.counts().commits,0);assert.equal(s.counts().restarts,0);assert.deepEqual(s.current(),before);assert.match(s.ui.snapshot().error,/changed|disappeared/);
  }
});
test('a capture read failure stays a controlled error without a restore or write',()=>{
  const s=study();s.throwCapture(true);s.ui.action('appliance-backup:create');assert.match(s.ui.snapshot().error,/Unreadable appliance/);assert.equal(s.ui.pending(),false);assert.deepEqual(s.counts(),{writes:0,commits:0,restarts:0});
});
test('Back and leave discard pending appliance changes',()=>{
  const s=study();s.ui.action('appliance-backup:create');assert(s.ui.back());assert.equal(s.ui.pending(),false);s.ui.action('appliance-backup:create');s.ui.leave();assert.equal(s.ui.pending(),false);assert.deepEqual(s.counts(),{writes:0,commits:0,restarts:0});
});
