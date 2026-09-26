// Pending-session physical port identities. No device client or live routing writes.
(function(root){
 'use strict';
 const copy=v=>structuredClone(v),text=v=>typeof v==='string'&&v.length>0;
 const manifest=s=>s?.audioRouting?.portBindings;
 const key=(interfaceId,portIds)=>JSON.stringify([interfaceId,...portIds]);
 function valid(s){
  const rows=manifest(s);if(!Array.isArray(rows))return false;
  const record=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
  if([s.recordingInputs,s.audioRouting.outputs,s.liveMonitoring].some(v=>v!==undefined&&!record(v))||(s.inputSetup?.stereoPairs!==undefined&&!Array.isArray(s.inputSetup.stereoPairs)))return false;
  for(const routes of [s.recordingInputs||{},s.audioRouting.outputs||{}])if(Object.values(routes).some(ids=>!Array.isArray(ids)||ids.some(id=>!text(id))))return false;
  if((s.inputSetup?.stereoPairs||[]).some(id=>!text(id)))return false;
  const ids=new Set(),logical=new Set();
  for(const b of rows){
   if(!b||!text(b.id)||ids.has(b.id)||!['input','output'].includes(b.direction)||!text(b.interfaceId)||
    !Array.isArray(b.logicalIds)||!b.logicalIds.length||b.logicalIds.some(v=>!text(v))||
    !Array.isArray(b.portIds)||![1,2].includes(b.portIds.length)||b.portIds.some(v=>!text(v))||new Set(b.portIds).size!==b.portIds.length||
    (b.direction==='input'?b.logicalIds.length!==b.portIds.length:b.logicalIds.length!==1))return false;
   ids.add(b.id);for(const id of b.logicalIds){const k=b.direction+':'+id;if(logical.has(k))return false;logical.add(k);}
  }
  const inputs=new Set([...Object.values(s.recordingInputs||{}).flat(),...Object.entries(s.liveMonitoring||{}).filter(([,mode])=>mode!=='off').map(([id])=>id)]);
  const outputs=new Set(Object.values(s.audioRouting?.outputs||{}).flat());outputs.add('Main output');
  const instruments=new Set((s.instruments?.instruments||[]).map(i=>i.id));
  if([...inputs].some(id=>!instruments.has(id)&&!logical.has('input:'+id))||[...outputs].some(id=>!logical.has('output:'+id)))return false;
  if((s.inputSetup?.stereoPairs||[]).some(left=>!rows.some(b=>b.direction==='input'&&b.logicalIds[0]===left&&b.logicalIds.length===2)))return false;
  const occupied=new Set();for(const b of rows)for(const port of b.portIds){const k=JSON.stringify([b.interfaceId,b.direction,port]);if(occupied.has(k))return false;occupied.add(k);}
  return true;
 }
 function affected(s,b){
  const rows=[];
  if(b.direction==='input'){
   for(const [track,inputs] of Object.entries(s.recordingInputs||{}))if(inputs.some(id=>b.logicalIds.includes(id)))rows.push((s.trackLabels?.[track]||track)+' · Recording input');
   for(const id of b.logicalIds){if(s.liveMonitoring?.[id]!=='off')rows.push(id+' · Live monitoring');}
  }else{
   for(const [source,outputs] of Object.entries(s.audioRouting?.outputs||{}))if(outputs.some(id=>b.logicalIds.includes(id)))rows.push((s.trackLabels?.[source]||source)+' · Output routing');
   // The established route default is Main output; this describes that contract,
   // not an inferred physical jack binding.
   if(b.logicalIds.includes('Main output'))rows.push('Main output · Sources using the default output route');
  }
  return rows.length?rows:[b.logicalIds.join(' + ')+' · Saved audio connection'];
 }
 function reason(b,inventory){
  if(!inventory?.online)return 'Audio interface is disconnected.';
  if(b.interfaceId!==inventory.interfaceId)return 'Saved interface '+b.interfaceId+' is not the current interface.';
  const ports=b.portIds.map(id=>(Array.isArray(inventory.ports)?inventory.ports:[]).find(p=>p.id===id&&p.direction===b.direction));
  if(ports.some(p=>!p))return 'A saved '+b.direction+' port is unavailable.';
  if(ports.length===2&&(!ports[0].stereoGroup||ports[0].stereoGroup!==ports[1].stereoGroup||ports[0].side!=='left'||ports[1].side!=='right'))return 'The saved stereo connection is no longer a left/right pair.';
  return '';
 }
 function inspect(s,inventory){
  if(!valid(s))return [{kind:'audio-port-manifest',id:'audio-ports',label:'Saved audio connections have no readable exact port identities.'}];
  return manifest(s).flatMap(b=>{const error=reason(b,inventory);return error?[{kind:'audio-port',id:b.id,label:b.label||b.logicalIds.join(' + '),interfaceId:b.interfaceId,portIds:copy(b.portIds),reason:error,affected:affected(s,b)}]:[];});
 }
 function options(s,inventory,id){
  if(!valid(s))return [];
  const b=manifest(s).find(b=>b.id===id);if(!b)return [];
  const ports=(Array.isArray(inventory?.ports)?inventory.ports:[]).filter(p=>p.direction===b.direction),rows=b.portIds.length===1?ports.map(p=>[p]):ports.filter(p=>p.side==='left'&&p.stereoGroup).map(p=>[p,ports.find(r=>r.side==='right'&&r.stereoGroup===p.stereoGroup)]).filter(pair=>pair[1]);
  return rows.map(pair=>{
   const portIds=pair.map(p=>p.id),candidate={...b,interfaceId:inventory.interfaceId,portIds};
   let error=reason(candidate,inventory);
   if(!error&&!reason(b,inventory))error='The saved connection is available. Keep its exact identity.';
   if(!error&&manifest(s).some(other=>other.id!==b.id&&other.direction===b.direction&&other.interfaceId===candidate.interfaceId&&other.portIds.some(p=>portIds.includes(p))))error='These ports already belong to another saved audio connection.';
   return {key:key(candidate.interfaceId,portIds),label:(inventory.name||inventory.interfaceId)+' · '+pair.map(p=>p.label||p.id).join(' + '),interfaceId:candidate.interfaceId,portIds,enabled:!error,reason:error,affected:affected(s,b)};
  });
 }
 function repair(s,inventory,id,replacement){
  if(!valid(s))return {error:'The saved audio connection manifest is unreadable. No ports were guessed.'};
  const choice=options(s,inventory,id).find(c=>c.key===replacement);
  if(!choice)return {error:'The selected audio ports are no longer available.'};
  if(!choice.enabled)return {error:choice.reason};
  const snapshot=copy(s),binding=manifest(snapshot).find(b=>b.id===id);
  binding.interfaceId=choice.interfaceId;binding.portIds=copy(choice.portIds);
  return {snapshot,change:{text:(binding.label||binding.logicalIds.join(' + '))+' → '+choice.label,affected:choice.affected}};
 }
 // Explicit simulated profiles. These jack IDs are fixture identities, not a
 // claim that device counts or native enumeration order identify physical ports.
 function fixtureInventory(deviceState){
  const id=deviceState?.config?.id,device=deviceState?.devices?.find(d=>d.id===id),sizes={stage:[18,8],spare:[18,8],compact:[2,2]},size=sizes[id];
  if(!size)return {interfaceId:id||null,name:'Unknown interface',online:false,ports:[]};
  return {interfaceId:id,name:device?.name||id,online:device?.online===true,ports:['input','output'].flatMap((direction,d)=>Array.from({length:size[d]},(_,i)=>({id:id+':'+direction+':'+(i+1),direction,label:(direction==='input'?'Input ':'Output ')+(i+1),stereoGroup:id+':'+direction+':pair:'+Math.floor(i/2),side:i%2?'right':'left'})))};
 }
 function fixtureBindings(profile){
  // The caller supplies every logical-to-physical association explicitly, only
  // for a fresh known fixture. Incoming sessions never call this initializer.
  return ['input','output'].flatMap(direction=>(profile[direction+'s']||[]).map(row=>({id:direction+':'+row.logicalIds[0],direction,logicalIds:copy(row.logicalIds),label:row.label||row.logicalIds.join(' + '),interfaceId:profile.interfaceId,portIds:copy(row.portIds)})));
 }
 function regroup(s,inventory,stereoPairs,inputIds){
  if(!valid(s)||!Array.isArray(stereoPairs)||!Array.isArray(inputIds)||new Set(inputIds).size!==inputIds.length||new Set(stereoPairs).size!==stereoPairs.length)return {error:'The input connection setup is unreadable.'};
  const members=new Map();
  for(const b of manifest(s).filter(b=>b.direction==='input'))b.logicalIds.forEach((id,i)=>members.set(id,{interfaceId:b.interfaceId,portId:b.portIds[i]}));
  if(inputIds.length!==members.size||inputIds.some(id=>!members.has(id))||stereoPairs.some(id=>inputIds.indexOf(id)<0||inputIds.indexOf(id)%2!==0||inputIds.indexOf(id)+1>=inputIds.length))return {error:'The requested input grouping does not match the saved input identities.'};
  const rows=[];
  for(let i=0;i<inputIds.length;i++){
   const logicalIds=stereoPairs.includes(inputIds[i])?[inputIds[i],inputIds[++i]]:[inputIds[i]],ports=logicalIds.map(id=>members.get(id));
   if(ports.some(p=>p.interfaceId!==ports[0].interfaceId))return {error:'Stereo inputs must belong to the same audio interface.'};
   const row={id:'input:'+logicalIds[0],direction:'input',logicalIds,label:logicalIds.join(' + '),interfaceId:ports[0].interfaceId,portIds:ports.map(p=>p.portId)};
   const error=reason(row,inventory);if(error)return {error};rows.push(row);
  }
  const snapshot=copy(s);snapshot.inputSetup={...snapshot.inputSetup,stereoPairs:copy(stereoPairs)};snapshot.audioRouting.portBindings=[...rows,...manifest(snapshot).filter(b=>b.direction==='output')];
  return valid(snapshot)?{snapshot}:{error:'The input grouping would duplicate or lose a physical connection.'};
 }
 const api={valid,inspect,options,repair,regroup,fixtureInventory,fixtureBindings};root.SegnoSessionAudioPortRepair=api;if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof window==='undefined'?globalThis:window);
