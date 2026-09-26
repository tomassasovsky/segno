// Complete-appliance backup proposal: JSON state and declared audio descriptors.
// No filesystem archive, native-byte checksum or crash-safe restore is claimed.
(function(root){
  'use strict';
  const recovery=typeof module!=='undefined'&&module.exports?require('./session-recovery-model.js'):root.SegnoSessionRecovery;
  const recorded=typeof module!=='undefined'&&module.exports?require('./recorded-audio-model.js'):root.SegnoRecordedAudio;
  const performance=typeof module!=='undefined'&&module.exports?require('./performance-recording-model.js'):root.SegnoPerformanceRecording;
  const copy=v=>structuredClone(v),object=v=>!!v&&typeof v==='object'&&!Array.isArray(v);
  function serializable(value){
    if(value===null||typeof value==='string'||typeof value==='boolean')return true;
    if(typeof value==='number')return Number.isFinite(value);
    if(Array.isArray(value))return value.every(serializable);
    return object(value)&&Object.getPrototypeOf(value)!==Date.prototype&&Object.values(value).every(serializable);
  }
  const audioFile=f=>object(f)&&typeof f.id==='string'&&!!f.id&&typeof f.name==='string'&&Number.isFinite(f.seconds)&&f.seconds>0&&['WAV','MP3'].includes(f.format?.toUpperCase())&&!f.unreadable&&!f.damaged&&(!('performance' in f||'parts' in f)||f.format.toUpperCase()==='WAV'&&!performance.manifest(f).error);
  function summary(payload){return {sessions:1+payload.sessions.sessions.length,audio:payload.audio.files.length,recordedAudio:payload.audio.recordedFiles.length,presets:Object.values(payload.presets).reduce((sum,list)=>sum+(Array.isArray(list)?list.length:0),0),settings:Object.keys(payload.settings).length};}
  function validate(payload){
    try{
      if(!object(payload)||!serializable(payload)||!['sessions','audio','presets','settings'].every(k=>object(payload[k])))throw Error('The backup must include sessions, audio, presets and settings.');
      const library=payload.sessions,audio=payload.audio;
      if(!Array.isArray(library.sessions)||!Number.isInteger(library.nextId)||library.nextId<1||!Array.isArray(library.folders)||!Array.isArray(audio.files)||!Array.isArray(audio.recordedFiles))throw Error('The backup catalogue is incomplete.');
      const entries=[library.current,...library.sessions],ids=entries.map(s=>s?.id);
      if(new Set(ids).size!==ids.length||entries.some(s=>!object(s)||typeof s.id!=='string'||!s.id||typeof s.name!=='string'||!object(s.snapshot)||!Array.isArray(s.snapshot.racks)))throw Error('The session catalogue is incomplete or has conflicting identities.');
      const files=[...audio.files,...audio.recordedFiles];
      if(new Set(files.map(f=>f?.id)).size!==files.length||!audio.files.every(audioFile)||!audio.recordedFiles.every(f=>recorded.readable(f)&&f.location==='internal'))throw Error('Audio is missing, damaged or has conflicting identities.');
      for(const session of entries){
        if(!recovery.valid(session.snapshot)||recorded.unmaterialized(session.snapshot)||recovery.inspect(session.snapshot,files).length||recorded.importedIds(session.snapshot).some(id=>!audio.files.some(f=>f.id===id)))throw Error('Resolve the original audio for '+session.name+' before backing up or restoring.');
        for(const [track,parts]of Object.entries(session.snapshot.recordedParts||{})){
          if(!Array.isArray(parts))throw Error('The recorded track list is unreadable.');
          const imported=session.snapshot.audioLibrary.trackImports?.[Number(track.replace('Track ',''))-1];
          if(parts.length&&!imported&&!session.snapshot.trackLayers?.[track]?.layers?.length)throw Error('Recorded audio references are incomplete for '+session.name+' · '+track+'.');
        }
      }
      return {valid:true,summary:summary(payload)};
    }catch(e){return {valid:false,error:e.message||'This backup is unreadable.'};}
  }
  function pack(payload,metadata){
    const checked=validate(payload);if(!checked.valid)return {error:checked.error};
    if(!metadata||typeof metadata.id!=='string'||!metadata.id||typeof metadata.name!=='string'||!metadata.name.trim()||!Number.isFinite(metadata.created))return {error:'A backup identity, name and date are required.'};
    return {archive:{kind:'segno-appliance-prototype',version:1,id:metadata.id,name:metadata.name.trim(),created:metadata.created,contents:copy(payload),manifest:copy(checked.summary)}};
  }
  function inspect(archive){
    if(!object(archive)||archive.kind!=='segno-appliance-prototype'||archive.version!==1||archive.damaged||typeof archive.id!=='string'||!archive.id||typeof archive.name!=='string'||!archive.name||!Number.isFinite(archive.created))return {valid:false,error:'This appliance backup is damaged or unsupported.'};
    const checked=validate(archive.contents);if(!checked.valid)return checked;
    if(!object(archive.manifest)||Object.keys(archive.manifest).length!==Object.keys(checked.summary).length||Object.entries(checked.summary).some(([k,v])=>archive.manifest[k]!==v))return {valid:false,error:'The backup manifest is incomplete.'};
    return checked;
  }
  function restore(archive,current){
    const checked=inspect(archive);if(!checked.valid)return {error:checked.error};
    if(!object(current)||!serializable(current))return {error:'Current appliance state is unreadable.'};
    return {payload:copy(archive.contents),summary:checked.summary,changes:['Replace the complete session Library','Restore recorded and backing audio','Replace saved preset libraries','Restore appliance settings and restart']};
  }
  const api={validate,summary,pack,inspect,restore};root.SegnoApplianceBackupModel=api;
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof window==='undefined'?globalThis:window);
