// Recorded-file recovery proposal. Integrity is declared prototype evidence,
// never a claim that native bytes were read, hashed, copied or decoded.
(function(root){
  'use strict';
  const copy=value=>structuredClone(value),object=v=>!!v&&typeof v==='object'&&!Array.isArray(v);
  const descriptor=v=>object(v)&&['id','name','sourceId','integrity'].every(k=>typeof v[k]==='string'&&!!v[k])&&Number.isFinite(v.seconds)&&v.seconds>0&&v.format==='WAV';
  const readable=v=>descriptor(v)&&!v.unreadable&&!v.damaged&&['internal','usb-backup'].includes(v.location);
  const sameContent=(a,b)=>descriptor(a)&&descriptor(b)&&['sourceId','integrity','seconds','format'].every(k=>a[k]===b[k]);
  const reference=file=>Object.fromEntries(['id','name','sourceId','integrity','seconds','format'].map(k=>[k,file[k]]));
  function states(snapshot){
    const result=[];
    if(!object(snapshot)||snapshot.trackLayers!==undefined&&!object(snapshot.trackLayers))throw Error('Unreadable recorded layers.');
    for(const [track,container]of Object.entries(snapshot.trackLayers||{}))result.push({container,track,length:snapshot.trackLength?.[track],imported:snapshot.audioLibrary?.trackImports?.[Number(track.replace('Track ',''))-1],history:''});
    if(snapshot.editHistory!==undefined){
      if(!object(snapshot.editHistory)||!Array.isArray(snapshot.editHistory.tracks))throw Error('Unreadable recording history.');
      for(const journal of snapshot.editHistory.tracks){
        if(!object(journal))throw Error('Unreadable recording history.');
        for(const direction of ['undo','redo']){
          if(!Array.isArray(journal[direction]))throw Error('Unreadable recording history.');
          for(const entry of journal[direction])for(const side of ['before','after']){
            if(entry?.[side]===undefined)continue;
            if(!object(entry?.[side]))throw Error('Unreadable recording history.');
            for(const [index,state]of Object.entries(entry[side]))result.push({container:state.layers,track:'Track '+(Number(index)+1),length:state.length,imported:state.imported,history:(direction==='undo'?'Undo':'Redo')+' · '+(entry.label||'Edit')});
          }
        }
      }
    }
    return result;
  }
  function layers(snapshot){
    const result=[];
    for(const {container,track,length,history}of states(snapshot)){
      if(container===undefined)continue;
      if(!object(container)||!Array.isArray(container.layers))throw Error('Unreadable recorded layers.');
      for(const group of ['layers','removed']){
        if(container[group]!==undefined&&!Array.isArray(container[group]))throw Error('Unreadable recorded layers.');
        for(const layer of container[group]||[]){
          if(!object(layer)||layer.sourceFile!==undefined&&(typeof layer.sourceFile!=='string'||!layer.sourceFile))throw Error('Unreadable recorded layer.');
          result.push({layer,track,length,usage:[snapshot.trackLabels?.[track]||track,history,group==='removed'?'Removed layer':layer.label||'Recorded layer'].filter(Boolean).join(' · ')});
        }
      }
    }
    return result;
  }
  function valid(snapshot){try{return layers(snapshot).every(({layer,length})=>layer.recordedAudio===undefined||descriptor(layer.recordedAudio)&&
    (layer.beats===undefined||Number.isFinite(layer.beats)&&layer.beats>0)&&
    (length?.durationBeats===undefined||Number.isFinite(length.durationBeats)&&length.durationBeats>0)&&
    (layer.regions===undefined||Array.isArray(layer.regions)&&layer.regions.every(r=>object(r)&&Number.isFinite(r.offsetBeats)&&Number.isFinite(r.beats)&&r.beats>=0)));}catch{return false;}}
  function references(snapshot){
    if(!valid(snapshot))throw Error('This session has unreadable recorded audio references.');
    return layers(snapshot).filter(v=>v.layer.recordedAudio).map(v=>({file:copy(v.layer.recordedAudio),usage:v.usage}));
  }
  function inspect(snapshot,files){
    const rows=new Map();
    for(const {file,usage}of references(snapshot)){
      if(!rows.has(file.id))rows.set(file.id,{id:file.id,name:file.name,kind:'recorded',usages:[],trackRequirements:[],recordedRequirements:[]});
      const row=rows.get(file.id);if(!row.usages.includes(usage))row.usages.push(usage);
      if(!row.recordedRequirements.some(v=>JSON.stringify(v)===JSON.stringify(file)))row.recordedRequirements.push(file);
    }
    return [...rows.values()].flatMap(row=>{
      const matches=files.filter(f=>f.id===row.id),current=matches[0];
      const reason=!matches.length?'missing':matches.length!==1?'ambiguous':!readable(current)?'damaged':!row.recordedRequirements.every(r=>sameContent(r,current))?'changed':null;
      return reason?[{...row,reason}]:[];
    });
  }
  function candidates(problem,files){return copy(files.filter(file=>readable(file)&&files.filter(f=>f.id===file.id).length===1&&problem.recordedRequirements.every(r=>sameContent(r,file))));}
  function repair(snapshot,id,selected,files){
    const problem=inspect(snapshot,files).find(p=>p.id===id);
    if(!problem)throw Error('This recorded audio no longer needs repair.');
    const current=files.find(f=>f.id===selected?.id);
    if(!current||JSON.stringify(current)!==JSON.stringify(selected))throw Error('The original audio changed or is unavailable. Choose it again.');
    if(!candidates(problem,files).some(f=>f.id===current.id))throw Error('Choose the exact original recording or an intact backup copy.');
    const next=copy(snapshot);for(const {layer}of layers(next))if(layer.recordedAudio?.id===id)layer.recordedAudio=reference(current);
    return next;
  }
  function materializeRecorded(snapshot,inventory,sessionId){
    if(typeof sessionId!=='string'||!sessionId)throw Error('A stable session identity is required.');
    if(!valid(snapshot))throw Error('Unreadable recorded audio references.');
    const next=copy(snapshot),files=copy(inventory),tempo=next.loopSettings?.tempo,known=new Map();
    const key=v=>sessionId+':'+v.track+':'+v.layer.id;
    for(const v of layers(next))if(v.layer.recordedAudio)known.set(key(v),v.layer.recordedAudio);
    for(const v of layers(next)){
      const layer=v.layer;if(layer.recordedAudio||layer.sourceFile)continue;
      if(typeof layer.id!=='string'||!layer.id)throw Error('A stable recorded layer identity is required.');
      if(known.has(key(v))){layer.recordedAudio=copy(known.get(key(v)));continue;}
      const beats=layer.beats??v.length?.durationBeats??v.length?.audio?.length;
      if(!Number.isFinite(beats)||beats<=0||!Number.isFinite(tempo)||tempo<=0)throw Error('Recorded duration is unavailable.');
      const id='recorded:'+key(v),seconds=Number.isFinite(layer.seconds)&&layer.seconds>0?layer.seconds:beats*60/tempo;
      const file={id,name:(next.trackLabels?.[v.track]||v.track)+' · '+(layer.label||layer.id)+'.wav',sourceId:id,integrity:'symbolic:'+id+':'+seconds,seconds,format:'WAV',location:'internal'};
      const existing=files.find(f=>f.id===id);
      if(existing&&!sameContent(existing,file))throw Error('A recorded asset identity conflicts with existing audio.');
      if(!existing)files.push(file);
      layer.recordedAudio=reference(file);known.set(key(v),layer.recordedAudio);
    }
    return {snapshot:next,files};
  }
  function internalCopies(snapshot,files){
    if(inspect(snapshot,files).length)throw Error('Recorded audio is no longer ready.');
    return [...new Set(references(snapshot).map(r=>r.file.id))].map(id=>({...copy(files.find(f=>f.id===id)),location:'internal'}));
  }
  const unmaterialized=snapshot=>layers(snapshot).some(({layer})=>!layer.recordedAudio&&!layer.sourceFile);
  function importedReferences(snapshot){
    const rows=[];
    for(const state of states(snapshot))if(state.imported){
      rows.push({id:state.imported.file?.id,file:copy(state.imported.file),track:Number(state.track.replace('Track ',''))-1,usage:[snapshot.trackLabels?.[state.track]||state.track,state.history].filter(Boolean).join(' · ')});
    }
    const known=[...rows,...Object.values(snapshot.audioLibrary?.trackImports||{}).map(imported=>({id:imported.file?.id,file:imported.file}))];
    for(const {layer,track,usage}of layers(snapshot))if(layer.sourceFile)rows.push({id:layer.sourceFile,file:copy(known.find(row=>row.id===layer.sourceFile)?.file),track:Number(track.replace('Track ',''))-1,usage});
    return rows;
  }
  function repairImported(snapshot,id,file){
    const next=copy(snapshot);
    for(const {imported}of states(next))if(imported?.file?.id===id)imported.file=copy(file);
    for(const {layer}of layers(next))if(layer.sourceFile===id)layer.sourceFile=file.id;
    return next;
  }
  const importedIds=snapshot=>[...new Set(importedReferences(snapshot).map(row=>row.id))];
  const api={descriptor,readable,sameContent,valid,references,inspect,candidates,repair,materializeRecorded,internalCopies,unmaterialized,importedIds,importedReferences,repairImported};
  root.SegnoRecordedAudio=api;if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof window==='undefined'?globalThis:window);
