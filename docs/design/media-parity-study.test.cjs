// Run with Node. Exercises transaction outcomes through public study APIs.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const copy=v=>JSON.parse(JSON.stringify(v));
function runtime(){
  const timers=new Map();let timer=0;
  const world={window:{},Date,structuredClone,document:{querySelector:()=>null},setTimeout:fn=>{timers.set(++timer,fn);return timer;},clearTimeout:id=>timers.delete(id)};
  vm.createContext(world);
  for(const name of ['audio-library-study.js','session-preview-study.js','performance-recording-model.js','recorded-audio-model.js','session-recovery-model.js','session-recovery-study.js','session-library-study.js','backing-performance-study.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,name),'utf8'),world);
  return {w:world.window,flush:()=>{for(const [id,fn] of [...timers]){timers.delete(id);fn();}}};
}
const base={button:(id,title,cls='',attr='')=>`<button data-action="${id}" ${attr}>${title}</button>`,header:(title,sub,actions)=>`<h1>${title}</h1>${actions||''}`,icon:()=>'',escape:String,render:()=>{},setFocus:()=>{},active:()=>true};
function audio(){
  const r=runtime();let store=null,fail=false,clock={tempo:84,signature:'4/4',hasAudio:false,external:false,clockStatus:'internal'},mix={level:1,pan:.5},returned=false;
  const tracks=Array.from({length:8},(_,id)=>({id,label:'Track '+(id+1),hasAudio:false,capturing:false}));
  const ui=r.w.createAudioLibraryStudy({...base,read:()=>store,write:s=>{if(fail)return false;store=copy(s);return true;},tracks:()=>tracks,timing:()=>clock,mixRead:()=>mix,mixWrite:(key,value)=>{if(fail)return false;mix[key]=value;return true;},returnToTrack:()=>returned=true,commitImport:(s,imported)=>{if(fail)return false;store=copy(s);if(imported.timing.tempoChange)clock.tempo=imported.timing.tempoChange;return true;},recipe:()=>({seconds:12}),usbIdentity:()=>'segno-usb-1',perform:()=>{}});
  return {ui,...r,tracks,clock,mix,fail:v=>fail=v,state:()=>copy(store),returned:()=>returned};
}
function choose(a,id='inside-1',target=0){a.ui.action('audio:file:'+id);a.ui.action('audio:load-track');a.ui.action('audio:import-target:'+target);}
function session(){
  const r=runtime();let store=null,fail=false,playing=false,capturing=false,transferring=false,staged=0,notices=[];
  let snap={racks:[],recordedParts:Object.fromEntries(Array.from({length:8},(_,i)=>['Track '+(i+1),i===0?['Original']:[]])),trackPlayback:{},trackLabels:{},liveMonitoring:{},recordingInputs:{},loopSettings:{tempo:84,signature:'4/4'},audioLibrary:{prepared:['file-1'],trackImports:{}},previewTracks:[{bars:4,layers:1}]};
  const backup={busy:()=>false,beginBrowse:()=>{},overlay:()=>'',back:()=>false};
  const ui=r.w.createSessionLibraryStudy({...base,ownership:()=>[],files:()=>[{id:'file-1',name:'Backing.wav',seconds:24,format:'WAV'}],read:()=>store,capture:()=>copy(snap),fresh:from=>({...copy(from),recordedParts:Object.fromEntries(Array.from({length:8},(_,i)=>['Track '+(i+1),[]]))}),metadata:s=>{if(fail)return false;store=copy(s);return true;},commit:(s,next)=>{if(fail)return false;store=copy(s);snap=copy(next);return true;},stage:()=>staged++,open:()=>{},notice:v=>notices.push(v),capturing:()=>capturing,transferring:()=>transferring,playing:()=>playing,ready:()=>true,live:()=>({tracks:[]}),waveform:()=>'',backup:()=>backup});
  store=copy(ui.initial());
  return {ui,r,mutate:fn=>fn(store),state:()=>copy(store),snap:()=>copy(snap),fail:v=>fail=v,playing:v=>playing=v,capturing:v=>capturing=v,transferring:v=>transferring=v,notices,staged:()=>staged};
}
function name(s,value){s.ui.action('session:key:clear');for(const c of value)s.ui.key({key:c});s.ui.action('session:name-done');}

test('duplicate keeps active identity and produces independent snapshot; cancel and storage failure preserve state',()=>{
 const s=session(),before=s.state();s.ui.action('session:duplicate');s.ui.action('session:cancel');assert.deepEqual(s.state(),before);
 s.ui.action('session:duplicate');s.fail(true);name(s,'Show copy');assert.deepEqual(s.state(),before);assert.match(s.ui.snapshot().error,/could not/);
 s.fail(false);s.ui.action('session:name-done');const saved=s.state();assert.equal(saved.current.id,'session-1');assert.equal(saved.sessions[0].name,'Show copy');assert.deepEqual(saved.sessions[0].snapshot,s.snap());assert.equal(saved.sessions[0].id,'session-2');
});
test('Save As preserves prior session and changes active identity atomically',()=>{
 const s=session();s.ui.action('session:save-as');name(s,'Sunday');assert.equal(s.state().current.name,'Sunday');assert.equal(s.state().current.id,'session-2');assert.equal(s.state().sessions[0].name,'Evening loop');assert.deepEqual(s.state().sessions[0].snapshot,s.snap());
});
test('search, folder creation, duplicate folder error and move survive reopening the Library',()=>{
 const s=session();s.ui.action('session:create-folder');name(s,'Set one');assert.deepEqual(s.state().folders,['Set one']);assert.equal(s.ui.snapshot().visible.length,0);
 s.ui.action('session:create-folder');name(s,'SET ONE');assert.match(s.ui.snapshot().error,/already exists/);s.ui.action('session:cancel');
 s.ui.action('session:folder:*');s.ui.action('session:move');s.ui.action('session:move-to:Set%20one');assert.equal(s.state().current.folder,'Set one');
 s.ui.action('session:search');name(s,'missing');assert.equal(s.ui.snapshot().visible.length,0);s.ui.action('session:clear-search');assert.equal(s.ui.snapshot().visible.length,1);
 s.ui.action('session:library');assert.match(s.ui.body(),/Set one/);
});
test('active session cannot be deleted; selected delete cancels and rolls back on failure',()=>{
 const s=session();s.ui.action('session:delete');assert.equal(s.ui.snapshot().dialog,null);
 s.ui.action('session:duplicate');name(s,'Remove me');const before=s.state();s.ui.action('session:delete');s.ui.action('session:cancel');assert.deepEqual(s.state(),before);
 s.ui.action('session:delete');s.fail(true);s.ui.action('session:confirm-delete');assert.deepEqual(s.state(),before);assert.match(s.ui.snapshot().error,/could not be deleted/);
 s.fail(false);s.ui.action('session:confirm-delete');assert.equal(s.state().sessions.length,0);assert.deepEqual(s.snap().audioLibrary.prepared,['file-1']);
});
test('session direct controls respect capture and playback gates',()=>{
 const s=session();s.ui.action('session:duplicate');name(s,'Next');s.capturing(true);assert.equal(s.ui.command('next'),false);assert.equal(s.state().current.id,'session-1');s.capturing(false);s.playing(true);assert.equal(s.ui.command('next'),false);assert.equal(s.ui.snapshot().dialog.type,'load');s.ui.action('session:cancel');assert.equal(s.state().current.id,'session-1');s.playing(false);assert.equal(s.ui.command('next'),true);assert.equal(s.state().current.id,'session-2');assert.equal(s.ui.command('save'),true);
});
test('recovery refuses a changed or removed saved source without replacing the live session',()=>{
 for(const remove of [false,true]){
  const s=session();s.ui.action('session:duplicate');name(s,'Repair me');
  s.mutate(store=>{store.sessions[0].snapshot.audioLibrary.prepared=['missing'];});
  const live=s.snap();s.ui.action('session:load');s.ui.action('recover:choose:missing');s.ui.action('recover:file:file-1');
  s.mutate(store=>{if(remove)store.sessions=[];else store.sessions[0].name='Changed meanwhile';});
  const latest=s.state();s.ui.action('recover:open');assert.match(s.ui.snapshot().recovery.error,/saved session changed/);assert.deepEqual(s.state(),latest);assert.deepEqual(s.snap(),live);assert.equal(s.staged(),0);
 }
});
test('New Loop or leaving recovery discards the draft; an Audio setup excursion retains it',()=>{
 const s=session();s.ui.action('session:duplicate');name(s,'Repair me');s.mutate(store=>store.sessions[0].snapshot.audioLibrary.prepared=['missing']);s.ui.action('session:load');
 s.ui.leave('audio-device');assert(s.ui.snapshot().recovery.draft);s.ui.leave();assert.equal(s.ui.snapshot().recovery.draft,null);
 s.ui.action('session:load');assert(s.ui.snapshot().recovery.draft);assert.equal(s.ui.newLoop(true),true);assert.equal(s.ui.snapshot().recovery.draft,null);assert.equal(s.state().current.id,'session-3');
});
test('unreadable saved media containers show a controlled error and preserve the current loop',()=>{
 for(const audioLibrary of [{prepared:{broken:'descriptor'}},{prepared:['okay'],trackImports:[]},{backing:{id:'bad'}},{trackImports:{0:{file:null}}}]){
  const s=session();s.ui.action('session:duplicate');name(s,'Unreadable');s.mutate(store=>store.sessions[0].snapshot.audioLibrary=audioLibrary);const live=s.snap();
  assert.doesNotThrow(()=>s.ui.action('session:load'));assert.match(s.ui.snapshot().error,/unreadable audio references/);assert.deepEqual(s.snap(),live);assert.equal(s.staged(),0);
 }
});
test('empty-track entry carries destination, cancel returns and occupied entry is rejected',()=>{
 const a=audio();assert.equal(a.ui.openForTrack(6),true);a.ui.action('audio:load-track');assert.equal(a.ui.snapshot().trackImport.target,6);a.ui.action('audio:cancel-track-import');a.ui.action('audio:cancel-entry');assert.equal(a.returned(),true);assert.equal(a.state(),null);a.tracks[6].hasAudio=true;assert.equal(a.ui.openForTrack(6),false);
});
test('unchanged import stores source duration and can be canceled during copy',()=>{
 const a=audio();choose(a);a.ui.action('audio:commit-track-import');a.ui.action('audio:cancel-job');a.flush();assert.equal(a.state(),null);
 a.ui.action('audio:commit-track-import');a.flush();const imp=a.state().trackImports[0];assert.equal(imp.timing.policy,'unchanged');assert.equal(imp.timing.seconds,222);assert.equal(imp.timing.sourceTempo,null);assert.equal(imp.timing.processing,'simulated');assert.equal(imp.state,'stopped');
});
test('import rechecks occupation, timing, changed source and failed publication',()=>{
 const a=audio();choose(a);a.ui.action('audio:commit-track-import');a.tracks[0].hasAudio=true;a.flush();assert.equal(a.state(),null);assert.match(a.ui.snapshot().error,/no longer empty/);
 a.tracks[0].hasAudio=false;a.ui.action('audio:commit-track-import');a.clock.tempo=90;a.flush();assert.equal(a.state(),null);assert.match(a.ui.snapshot().error,/timing changed/);
 a.fail(true);a.ui.action('audio:commit-track-import');a.flush();assert.equal(a.state(),null);assert.match(a.ui.snapshot().error,/unchanged/);
});
test('file-tempo import changes empty loop only; existing incompatible audio remains untouched',()=>{
 const a=audio();choose(a,'inside-9');a.ui.action('audio:timing:file');a.clock.hasAudio=true;assert.match(a.ui.snapshot().importPlan.reason,/Existing tracks/);a.ui.action('audio:commit-track-import');assert.equal(a.ui.snapshot().job,null);
 a.clock.hasAudio=false;a.ui.action('audio:commit-track-import');a.flush();assert.equal(a.clock.tempo,120);assert.equal(a.state().trackImports[0].timing.seconds,24);assert.equal(a.state().trackImports[0].timing.sourceTempoOrigin,'fixture');
});
test('adapt timing retains original file, derives duration and requires unknown tempo bar confirmation',()=>{
 const a=audio();choose(a,'inside-9');a.ui.action('audio:timing:adapt');assert.equal(a.ui.snapshot().importPlan.seconds,24*120/84);a.ui.action('audio:commit-track-import');a.flush();assert.equal(a.state().trackImports[0].file.seconds,24);assert.equal(a.clock.tempo,84);
 const b=audio();choose(b);b.ui.action('audio:timing:adapt');assert.match(b.ui.snapshot().importPlan.reason,/Confirm/);for(let i=0;i<16;i++)b.ui.action('audio:bars:up');b.ui.action('audio:confirm-bars');assert.equal(b.ui.snapshot().importPlan.sourceTempoOrigin,'user-bar-count');assert.equal(b.ui.snapshot().importPlan.reason,'');b.ui.action('audio:bars:up');assert.match(b.ui.snapshot().importPlan.reason,/Confirm/);
});
test('external clock forces adapt, blocks missing clock and rechecks clock loss during import',()=>{
 const a=audio();a.clock.external=true;a.clock.clockStatus='waiting';choose(a,'inside-9');a.ui.action('audio:timing:unchanged');assert.equal(a.ui.snapshot().importPlan.policy,'adapt');assert.match(a.ui.snapshot().importPlan.reason,/stable MIDI/);a.clock.clockStatus='synced';a.ui.action('audio:commit-track-import');a.clock.clockStatus='lost';a.flush();assert.equal(a.state(),null);assert.match(a.ui.snapshot().error,/stable MIDI/);
});
test('USB import publishes managed internal copy; disconnect and full storage retain original loop',()=>{
 const a=audio();a.ui.action('audio:location:usb');choose(a,'usb-1');a.ui.action('audio:commit-track-import');a.ui.simulate({usbConnected:false});a.flush();assert.equal(a.state(),null);assert.match(a.ui.snapshot().error,/disconnected/);a.ui.simulate({usbConnected:true,full:true});a.ui.action('audio:commit-track-import');a.flush();assert.equal(a.state(),null);a.ui.simulate({full:false});a.ui.action('audio:commit-track-import');a.flush();const imp=a.state().trackImports[0];assert.equal(imp.sourceLocation,'internal');assert.equal(imp.originalSourceLocation,'usb');assert.ok(a.state().files.some(f=>f.id===imp.file.id));assert.equal(a.state().usbFiles.find(f=>f.id==='usb-1').seconds,228);
});
test('backing level and pan share normalized state, preserve failed values and undo encoder cancel',()=>{
 const a=audio();a.ui.performanceCommand('level',.5);a.ui.performanceCommand('pan',.75);assert.deepEqual(a.mix,{level:.5,pan:.75});a.ui.action('audio:mix:pan');a.ui.turn(10);assert.equal(a.mix.pan,.85);a.ui.finish(true);assert.equal(a.mix.pan,.75);a.fail(true);a.ui.performanceCommand('level',.2);assert.equal(a.mix.level,.5);assert.match(a.ui.snapshot().error,/could not be saved/);
});
test('backing clear keeps preparation, cancel keeps playback; previous/next follow prepared order',()=>{
 const a=audio();a.ui.action('audio:prepare');a.ui.action('audio:file:inside-2');a.ui.action('audio:prepare');a.ui.action('audio:load');a.ui.performanceCommand('previous');assert.equal(a.ui.performanceSnapshot().loaded.id,'inside-1');a.ui.performanceCommand('play');a.ui.action('audio:clear');a.ui.action('audio:dialog-cancel');assert.equal(a.ui.performanceSnapshot().playing,true);a.ui.action('audio:clear');a.ui.action('audio:confirm-clear');assert.equal(a.ui.performanceSnapshot().loaded,null);assert.equal(a.ui.performanceSnapshot().files.length,2);a.ui.performanceCommand('next');assert.equal(a.ui.performanceSnapshot().loaded.id,'inside-1');
});
test('performance touch and encoder mix use same commands and cancel draft values',()=>{
 const a=audio();a.ui.action('audio:prepare');a.ui.action('audio:load');const ui=a.w.createBackingPerformanceStudy({state:{get:a.ui.performanceSnapshot,command:a.ui.performanceCommand},changed:()=>{}});ui.controls.action('backing:mix:level');ui.controls.turn(-20);ui.controls.finish(true);assert.equal(a.mix.level,1);ui.controls.action('backing:mix:pan');ui.controls.turn(20);ui.controls.finish();assert.equal(a.mix.pan,.7);ui.controls.action('backing:less:level');assert.equal(a.mix.level,.99);ui.controls.action('backing:clear');ui.controls.action('backing:cancel-clear');assert.ok(a.ui.performanceSnapshot().loaded);ui.controls.action('backing:clear');ui.controls.action('backing:confirm-clear');assert.equal(a.ui.performanceSnapshot().loaded,null);
});
test('audio search uses fixed keyboard, cancels cleanly, filters folder and clears',()=>{
 const a=audio();a.ui.action('audio:search');for(const key of 'Finale')a.ui.key({key});a.ui.action('audio:dialog-cancel');assert.equal(a.ui.snapshot().audioQuery,'');
 a.ui.action('audio:search');for(const key of 'Finale')a.ui.key({key});a.ui.action('audio:name-done');assert.equal(a.ui.snapshot().selected,'inside-8');assert.doesNotMatch(a.ui.body(),/data-action="audio:file:inside-1"/);a.ui.action('audio:clear-search');assert.match(a.ui.body(),/data-action="audio:file:inside-1"/);
});
test('bar-count encoder cancel restores confirmed timing',()=>{
 const a=audio();choose(a,'inside-9');a.ui.action('audio:timing:adapt');a.ui.action('audio:confirm-bars');a.ui.action('audio:bars-value');a.ui.turn(4);assert.equal(a.ui.snapshot().trackImport.barsDraft,16);a.ui.finish(true);assert.equal(a.ui.snapshot().trackImport.barsDraft,12);assert.equal(a.ui.snapshot().trackImport.confirmedBars,12);
});
test('session audition stops on management, and imported duration is represented without invented waveform samples',()=>{
 const s=session();s.ui.action('session:listen');assert.equal(s.ui.snapshot().preview.audition,true);s.ui.action('session:manage');assert.equal(s.ui.snapshot().preview.audition,false);
 const r=runtime(),preview=r.w.createSessionPreviewStudy({...base,live:()=>({tracks:[]}),capturing:()=>false,playing:()=>false,ready:()=>true,waveform:()=>{throw Error('Imported audio must not request unrelated PCM');}}),importedSession={id:'test',snapshot:{recordedParts:{},loopSettings:{tempo:84,signature:'4/4'},audioLibrary:{trackImports:{0:{file:{seconds:24},timing:{seconds:34.285714,bars:12}}}}}};
 assert.equal(preview.rows(importedSession)[0].seconds,34.285714);assert.match(preview.body(importedSession),/waveform unavailable/);
});
test('clear confirmation cannot unload a different backing recording selected meanwhile',()=>{
 const a=audio();a.ui.action('audio:prepare');a.ui.action('audio:file:inside-2');a.ui.action('audio:prepare');a.ui.action('audio:load');a.ui.action('audio:clear');a.ui.performanceCommand('previous');a.ui.action('audio:confirm-clear');assert.equal(a.ui.performanceSnapshot().loaded.id,'inside-1');assert.match(a.ui.snapshot().error,/changed/);
});
