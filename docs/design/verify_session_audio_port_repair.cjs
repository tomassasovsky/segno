const {test}=require('node:test'),assert=require('node:assert/strict'),api=require('./session-audio-port-repair.js');
const profile={interfaceId:'stage',inputs:[{logicalIds:['Guitar'],portIds:['stage:input:1']}],outputs:[{logicalIds:['Main output'],portIds:['stage:output:1','stage:output:2']}]};
const fixture=()=>({recordingInputs:{'Track 1':['Guitar'],'Track 2':['Guitar']},trackLabels:{'Track 1':'Verse'},liveMonitoring:{Guitar:'auto'},inputSetup:{stereoPairs:[]},audioRouting:{outputs:{Guitar:['Main output']},portBindings:api.fixtureBindings(profile)}});
const inventory=(id='spare')=>api.fixtureInventory({config:{id},devices:[{id,name:'Spare interface',online:true}]});
test('changed interface does not bind equal channel numbers and every affected route is explicit',()=>{
 const s=fixture(),issues=api.inspect(s,inventory());assert.equal(issues.length,2);assert.deepEqual(issues[0].portIds,['stage:input:1']);assert(issues[0].affected.includes('Verse · Recording input'));assert(issues[0].affected.includes('Track 2 · Recording input'));
 assert.equal(api.inspect(s,inventory('stage')).length,0);
});
test('replacement changes one shared physical binding and preserves logical routing and current inventory',()=>{
 const s=fixture(),before=structuredClone(s),i=inventory(),ib=structuredClone(i),choice=api.options(s,i,'input:Guitar').find(c=>c.enabled),r=api.repair(s,i,'input:Guitar',choice.key);
 assert.equal(r.snapshot.audioRouting.portBindings[0].interfaceId,'spare');assert.deepEqual(r.snapshot.recordingInputs,s.recordingInputs);assert.deepEqual(r.snapshot.audioRouting.outputs,s.audioRouting.outputs);assert.deepEqual(s,before);assert.deepEqual(i,ib);assert(!r.change.text.includes('["'));
});
test('stereo only offers declared ordered pairs, not adjacent enumeration positions',()=>{
 const s=fixture(),i=inventory();i.ports=i.ports.filter(p=>p.id!=='spare:output:2');
 const choices=api.options(s,i,'output:Main output');assert(!choices.some(c=>c.portIds.includes('spare:output:1')));assert(choices.some(c=>c.portIds.join(',')==='spare:output:3,spare:output:4'));
});
test('disconnect, removed ports and changed interface invalidate a staged choice',()=>{
 for(const change of [i=>i.online=false,i=>i.ports=[],i=>i.interfaceId='compact']){
  const s=fixture(),i=inventory(),choice=api.options(s,i,'input:Guitar')[0];change(i);const before=structuredClone(s);assert(api.repair(s,i,'input:Guitar',choice.key).error);assert.deepEqual(s,before);
 }
});
test('occupied candidate and duplicate physical bindings are refused',()=>{
 const s=fixture();s.audioRouting.portBindings.push({id:'input:Vocal',direction:'input',logicalIds:['Vocal'],interfaceId:'spare',portIds:['spare:input:1']});
 const choice=api.options(s,inventory(),'input:Guitar').find(c=>c.portIds[0]==='spare:input:1');assert.equal(choice.enabled,false);assert.match(choice.reason,/already belong/);
 const bad=fixture();bad.audioRouting.portBindings.push({...structuredClone(bad.audioRouting.portBindings[0]),id:'duplicate',logicalIds:['Other']});assert.equal(api.valid(bad),false);
});
test('missing, incomplete and malformed manifests stay unverified with no inferred indices',()=>{
 for(const change of [s=>delete s.audioRouting.portBindings,s=>s.audioRouting.portBindings=[],s=>s.audioRouting.portBindings[0].portIds=[],s=>s.audioRouting.portBindings[0].logicalIds=['Other']]){
  const s=fixture();change(s);assert.equal(api.inspect(s,inventory())[0].kind,'audio-port-manifest');assert.deepEqual(api.options(s,inventory(),'input:Guitar'),[]);
 }
});
test('saved stereo input grouping survives and cannot be repaired to a mono jack',()=>{
 const s=fixture();s.inputSetup.stereoPairs=['Guitar'];s.audioRouting.portBindings[0].logicalIds.push('Vocal');s.audioRouting.portBindings[0].portIds.push('stage:input:2');
 const choices=api.options(s,inventory(),'input:Guitar');assert(choices.length);assert(choices.every(c=>c.portIds.length===2));assert.equal(api.repair(s,inventory(),'input:Guitar',choices[0].key).snapshot.audioRouting.portBindings[0].logicalIds.length,2);
 s.audioRouting.portBindings[0].logicalIds.pop();s.audioRouting.portBindings[0].portIds.pop();assert.equal(api.valid(s),false);
});
test('restored exact ports need no replacement, and successful output repair becomes available',()=>{
 const s=fixture();assert(api.options(s,inventory('stage'),'output:Main output').every(c=>!c.enabled));
 const i=inventory(),choice=api.options(s,i,'output:Main output')[0],r=api.repair(s,i,'output:Main output',choice.key);assert(!api.inspect(r.snapshot,i).some(p=>p.id==='output:Main output'));
});
test('pair and split preserve exact physical jack identities and all output bindings',()=>{
 const s=fixture();s.audioRouting.portBindings.push({id:'input:Vocal',direction:'input',logicalIds:['Vocal'],interfaceId:'stage',portIds:['stage:input:2']});const before=structuredClone(s),i=inventory('stage');
 const paired=api.regroup(s,i,['Guitar'],['Guitar','Vocal']);assert(!paired.error);assert.deepEqual(paired.snapshot.audioRouting.portBindings[0].portIds,['stage:input:1','stage:input:2']);
 const split=api.regroup(paired.snapshot,i,[],['Guitar','Vocal']);assert(!split.error);assert.deepEqual(split.snapshot.audioRouting.portBindings.filter(b=>b.direction==='input').map(b=>b.portIds),[['stage:input:1'],['stage:input:2']]);assert.deepEqual(split.snapshot.audioRouting.portBindings.at(-1),s.audioRouting.portBindings[1]);assert.deepEqual(s,before);
});
test('grouping refuses incompatible physical pairs, offline devices and incomplete logical inventories',()=>{
 const s=fixture();s.audioRouting.portBindings.push({id:'input:Vocal',direction:'input',logicalIds:['Vocal'],interfaceId:'stage',portIds:['stage:input:4']});const before=structuredClone(s);
 assert(api.regroup(s,inventory('stage'),['Guitar'],['Guitar','Vocal']).error);assert(api.regroup(s,{...inventory('stage'),online:false},[],['Guitar','Vocal']).error);assert(api.regroup(s,inventory('stage'),[],['Guitar']).error);assert.deepEqual(s,before);
});
test('malformed saved route containers are controlled refusals at every public repair seam',()=>{
 for(const change of [s=>s.inputSetup.stereoPairs={},s=>s.inputSetup.stereoPairs=false,s=>s.recordingInputs={'Track 1':'Guitar'},s=>s.audioRouting.outputs={Guitar:{}},s=>s.liveMonitoring=[],s=>s.recordingInputs='Guitar',s=>s.recordingInputs=0,s=>s.recordingInputs=null]){
  const s=fixture();change(s);assert.equal(api.valid(s),false);assert.equal(api.inspect(s,inventory())[0].kind,'audio-port-manifest');assert.deepEqual(api.options(s,inventory(),'input:Guitar'),[]);assert(api.repair(s,inventory(),'input:Guitar','anything').error);assert(api.regroup(s,inventory(),[],['Guitar']).error);
 }
});
