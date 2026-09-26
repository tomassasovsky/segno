const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const recorded=require('./recorded-audio-model.js'),recovery=require('./session-recovery-model.js');
const copy=v=>structuredClone(v),json=v=>JSON.parse(JSON.stringify(v));
function fixture(){
  const layer={id:'take-2',label:'Original',gain:.72,beats:4,regions:[{offsetBeats:14,beats:4}]};
  const state={parts:['Guitar'],layers:{layers:[copy(layer)]},length:{durationBeats:16,audio:[],note:'Recording'},playing:false,mix:{level:.42}};
  return {loopSettings:{mode:'multi',tempo:120,signature:'4/4'},recordedParts:{'Track 1':['Guitar']},trackLabels:{'Track 1':'Verse'},trackLength:{'Track 1':copy(state.length)},trackLayers:{'Track 1':copy(state.layers)},expressionMix:{'Track 1':{level:.42}},audioLibrary:{prepared:[],backing:null,trackImports:{}},editHistory:{serial:2,tracks:[{undo:[{id:2,label:'Recording',before:{0:{...copy(state),layers:{layers:[]}}},after:{0:copy(state)}}],redo:[{id:3,label:'Peel',before:{0:copy(state)},after:{0:{...copy(state),layers:{layers:[]}}}}]}]}};
}
function materialized(){return recorded.materializeRecorded(fixture(),[],'session-A');}
function backup(file,overrides={}){return {...copy(file),id:'backup-copy',location:'usb-backup',...overrides};}
test('materialization identifies exact captured duration and shares a stable asset through active, Undo and Redo layers',()=>{
  const original=fixture(),before=copy(original),result=recorded.materializeRecorded(original,[],'session-A');
  assert.deepEqual(original,before);assert.equal(result.files.length,1);assert.equal(result.files[0].seconds,2);
  const refs=recorded.references(result.snapshot);assert.equal(refs.length,3);assert(refs.every(r=>r.file.id===result.files[0].id));assert(refs.some(r=>r.usage.includes('Redo')));assert(refs.some(r=>r.usage.includes('Undo')));
  assert.deepEqual(recorded.materializeRecorded(result.snapshot,result.files,'session-A'),result);assert.equal(result.snapshot.trackLength['Track 1'].durationBeats,16);assert.deepEqual(result.snapshot.trackLayers['Track 1'].layers[0].regions,[{offsetBeats:14,beats:4}]);
});
test('session-scoped materialization cannot alias unrelated takes and never regenerates an already identified missing file',()=>{
  const a=materialized(),b=recorded.materializeRecorded(fixture(),[],'session-B');assert.notEqual(a.files[0].id,b.files[0].id);
  const again=recorded.materializeRecorded(a.snapshot,[],'session-A');assert.deepEqual(again.files,[]);assert.equal(recorded.inspect(again.snapshot,[]).length,1);
  assert.throws(()=>recorded.materializeRecorded(fixture(),[],''),/stable session/);
  const bad=fixture();delete bad.trackLayers['Track 1'].layers[0].id;assert.throws(()=>recorded.materializeRecorded(bad,[],'A'),/stable recorded layer/);
});
test('inspection deduplicates missing recorded assets while retaining active and history use labels',()=>{
  const s=materialized(),rows=recovery.inspect(s.snapshot,[]);assert.equal(rows.length,1);assert.equal(rows[0].kind,'recorded');assert.equal(rows[0].reason,'missing');assert.equal(rows[0].usages.length,3);
  for(const field of ['unreadable','damaged'])assert.equal(recovery.inspect(s.snapshot,[{...s.files[0],[field]:true}])[0].reason,'damaged');
  assert.equal(recovery.inspect(s.snapshot,[{...s.files[0],integrity:'other-content'}])[0].reason,'changed');
});
test('only exact source identity, declared integrity, duration and format are candidates; a name never proves original audio',()=>{
  const s=materialized(),file=s.files[0],good=backup(file),problem=recovery.inspect(s.snapshot,[])[0];
  const candidates=[good,backup(file,{id:'other-source',sourceId:'unrelated'}),backup(file,{id:'corrupt',integrity:'damaged'}),backup(file,{id:'shorter',seconds:1.9}),backup(file,{id:'wrong-format',format:'MP3'}),backup(file,{id:'unreadable',unreadable:true})];
  assert.deepEqual(recovery.candidates(problem,candidates),[good]);assert.deepEqual(recovery.candidates(problem,[{...good},copy(good)]),[]);
});
test('ordinary backing repair excludes recorded originals, USB recovery copies and damaged files from the shared inventory',()=>{
  const s=materialized();s.snapshot.audioLibrary.backing={id:'missing-backing',name:'Backing.wav',seconds:2,format:'WAV'};
  const ordinary={id:'ordinary',name:'Backing.wav',seconds:2,format:'WAV'},files=[...s.files,backup(s.files[0]),{...ordinary,id:'damaged',damaged:true},ordinary];
  const problem=recovery.inspect(s.snapshot,files).find(row=>row.id==='missing-backing');assert.deepEqual(recovery.candidates(problem,files),[ordinary]);
  assert.throws(()=>recovery.repair(s.snapshot,problem.id,files[1],files),/no longer available/);
  const next=recovery.repair(s.snapshot,problem.id,ordinary,files);assert.deepEqual(next.audioLibrary.backing,ordinary);assert.deepEqual(recovery.inspect(next,files),[]);
});
test('ordinary recovery rejects broken performance parts and revalidates a changed original identity before Open',()=>{
  const performance=require('./performance-recording-model.js');
  function asset(id){const {take}=performance.create({id,name:'Show.wav',sessionId:'show',sessionName:'Show',output:'Main',startedAt:1},{sampleRate:100,channels:2,bitDepth:16,partBytes:444});return performance.asset(performance.advance(take,250,{freeBytes:2000,reserveBytes:0}).take);}
  const s=materialized(),original=asset('original');s.snapshot.audioLibrary.backing=copy(original);const changed=asset('different');changed.id=original.id;
  const problem=recovery.inspect(s.snapshot,[...s.files,changed]).find(row=>row.id===original.id);assert.equal(problem.reason,'changed');
  const broken=copy(changed);broken.id='broken';broken.parts.reverse();assert.deepEqual(recovery.candidates(problem,[broken,changed]),[changed]);
  const next=recovery.repair(s.snapshot,original.id,changed,[...s.files,changed]);assert.deepEqual(recovery.inspect(next,[...s.files,changed]),[]);assert.deepEqual(s.snapshot.audioLibrary.backing,original);
});
test('history-only imported audio remains a dependency and repair preserves exact timing, regions and history',()=>{
  const s=materialized(),old={id:'import-old',name:'Old.wav',seconds:4,format:'WAV'},replacement={...old,id:'import-new',name:'New.wav'};
  const state={parts:['Imported'],layers:{layers:[{id:'import-1',sourceFile:old.id,beats:8,gain:.4,regions:[{offsetBeats:4,beats:8}]}]},length:{durationBeats:16,audio:[]},imported:{file:old,state:'stopped',speed:.5,timing:{policy:'adapt',sourceSeconds:4,targetBeats:16}},playing:false};
  s.snapshot.editHistory.tracks[0].redo.push({id:4,label:'Imported recording',before:{0:copy(state)},after:{0:copy(state)}});
  const before=copy(s.snapshot),files=[...s.files,replacement],problem=recovery.inspect(s.snapshot,files).find(row=>row.id===old.id);assert(problem.usages.some(label=>label.includes('Redo')));
  assert.deepEqual(recovery.candidates(problem,[{...replacement,seconds:5},replacement]),[replacement]);
  const next=recovery.repair(s.snapshot,old.id,replacement,files);assert.deepEqual(recovery.inspect(next,files),[]);assert.deepEqual(s.snapshot,before);
  const entry=next.editHistory.tracks[0].redo.at(-1);for(const side of ['before','after']){const expected=copy(state);expected.layers.layers[0].sourceFile=replacement.id;expected.imported.file=copy(replacement);assert.deepEqual(entry[side][0],expected);}
});
test('an imported layer without its original descriptor cannot silently adopt a different duration',()=>{
  const s=materialized();s.snapshot.trackLayers['Track 2']={layers:[{id:'import-orphan',sourceFile:'orphan',beats:8}]};
  const file={id:'orphan',name:'Orphan.wav',seconds:20,format:'WAV'},problem=recovery.inspect(s.snapshot,[...s.files,file]).find(row=>row.id==='orphan');
  assert.equal(problem.unverifiedImport,true);assert.deepEqual(recovery.candidates(problem,[file]),[]);assert.throws(()=>recovery.repair(s.snapshot,'orphan',file,[...s.files,file]),/original duration/);
});
test('repair preserves Multi length, wrapped silence, gains and both history directions; draft cancellation is immutability',()=>{
  const s=materialized(),before=copy(s.snapshot),file=backup(s.files[0]),files=[file];
  const next=recovery.repair(s.snapshot,s.files[0].id,file,files);assert.deepEqual(s.snapshot,before);assert.deepEqual(files,[file]);
  const expected=copy(before);function change(layer){if(layer.recordedAudio)layer.recordedAudio.id=file.id;}
  expected.trackLayers['Track 1'].layers.forEach(change);for(const direction of ['undo','redo'])for(const entry of expected.editHistory.tracks[0][direction])for(const side of ['before','after'])Object.values(entry[side]).forEach(s=>s.layers.layers.forEach(change));
  assert.deepEqual(next,expected);assert.deepEqual(recovery.inspect(next,files),[]);
  const copies=recorded.internalCopies(next,files);assert.equal(copies[0].location,'internal');assert.equal(file.location,'usb-backup');assert.equal(copies[0].sourceId,file.sourceId);
});
test('repair and final internal staging reject removed, changed, ambiguous and already-resolved assets',()=>{
  const s=materialized(),file=backup(s.files[0]);
  assert.throws(()=>recovery.repair(s.snapshot,s.files[0].id,file,[]),/unavailable/);
  assert.throws(()=>recovery.repair(s.snapshot,s.files[0].id,file,[{...file,seconds:5}]),/changed/);
  assert.throws(()=>recovery.repair(s.snapshot,s.files[0].id,file,[file,copy(file)]),/exact original/);
  assert.throws(()=>recovery.repair(s.snapshot,s.files[0].id,file,[s.files[0],file]),/no longer needs/);
  const repaired=recovery.repair(s.snapshot,s.files[0].id,file,[file]);assert.throws(()=>recorded.internalCopies(repaired,[]),/no longer ready/);
});
test('malformed references are refused and previously silent layers retain empty regions',()=>{
  const s=materialized();s.snapshot.trackLayers['Track 1'].layers[0].recordedAudio.seconds=NaN;assert.equal(recovery.valid(s.snapshot),false);
  const original=fixture();original.trackLayers['Track 1'].layers[0].regions=[];const next=recorded.materializeRecorded(original,[],'A');assert.deepEqual(next.snapshot.trackLayers['Track 1'].layers[0].regions,[]);
});
test('history-only assets and removed layers remain dependencies even when the current track is empty',()=>{
  const source=fixture();source.trackLayers['Track 1']={layers:[],removed:[{id:'removed-1',label:'Overdub',beats:2,regions:[{offsetBeats:8,beats:2}]}]};
  const s=recorded.materializeRecorded(source,[],'A');assert.equal(s.files.length,2);assert.equal(recovery.inspect(s.snapshot,[]).length,2);
});
function study(){
  const world={window:{},structuredClone};vm.createContext(world);for(const name of ['performance-recording-model.js','recorded-audio-model.js','session-recovery-model.js','session-recovery-study.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,name),'utf8'),world);
  const s=materialized(),file=backup(s.files[0]),entry={id:'session-A',name:'Verse',snapshot:s.snapshot},files=[file];let ready=true,saved=copy(entry),live={name:'Current'},commits=0,done=0,fail=false;
  const ui=world.window.createSessionRecoveryStudy({button:(id,label)=>'<button data-action="'+id+'">'+label+'</button>',header:(title)=>'<h1>'+title+'</h1>',icon:()=>'',escape:String,render:()=>{},setFocus:()=>{},files:()=>files,ready:()=>ready,playing:()=>false,openDevice:()=>{},cancel:()=>{},done:()=>done++,commit:(candidate,original)=>{commits++;if(JSON.stringify(original)!==JSON.stringify(saved))return 'Saved session changed';if(fail)return 'Could not save';live=copy(candidate);return true;}});ui.begin(entry);
  return {ui,files,entry,file,missing:s.files[0].id,ready:v=>ready=v,fail:v=>fail=v,changeSource:()=>saved.name='Changed',state:()=>({live,commits,done})};
}
test('existing recovery screen explains exact original requirement and stages a backup without writing live data',()=>{
  const s=study();s.ui.action('recover:choose:'+encodeURIComponent(s.missing));assert.match(s.ui.body(),/Find original recording/);assert.match(s.ui.body(),/Loop length stays the same/);assert.match(s.ui.body(),/USB backup/);
  s.ui.action('recover:file:'+s.file.id);assert.equal(s.state().commits,0);assert.equal(json(s.ui.snapshot().draft).snapshot.trackLayers['Track 1'].layers[0].recordedAudio.id,s.file.id);s.ui.action('recover:cancel');assert.deepEqual(s.state(),{live:{name:'Current'},commits:0,done:0});
});
test('device loss and publication failure retain a repair draft for explicit retry, while a changed archive refuses Open',()=>{
  const s=study();s.ui.action('recover:choose:'+encodeURIComponent(s.missing));s.ui.action('recover:file:'+s.file.id);s.ready(false);s.ui.action('recover:open');assert.equal(s.state().commits,0);
  s.ready(true);s.fail(true);s.ui.action('recover:open');assert.equal(s.state().done,0);assert(s.ui.snapshot().draft);s.fail(false);s.ui.action('recover:open');assert.equal(s.state().done,1);
  const stale=study();stale.ui.action('recover:choose:'+encodeURIComponent(stale.missing));stale.ui.action('recover:file:'+stale.file.id);stale.changeSource();stale.ui.action('recover:open');assert.match(stale.ui.snapshot().error,/Saved session changed/);assert.deepEqual(stale.state().live,{name:'Current'});
});
test('a backup disappearing after selection resets draft to its original references and never commits',()=>{
  const s=study();s.ui.action('recover:choose:'+encodeURIComponent(s.missing));s.ui.action('recover:file:'+s.file.id);s.files.length=0;s.ui.action('recover:open');assert.equal(s.state().commits,0);assert.match(s.ui.snapshot().error,/Audio changed/);assert.deepEqual(json(s.ui.snapshot().draft),s.entry);
});
