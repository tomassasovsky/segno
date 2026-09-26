// Prototype orchestration for the complete-appliance archive. Byte copying and
// crash-safe disk publication belong to the production appliance implementation.
window.createApplianceBackupHost=ctx=>{
  const copy=v=>structuredClone(v),model=window.SegnoApplianceBackupModel;
  const archives=()=>copy(ctx.readArchives()||[]);let restored=null;
  function capture(){
    const rig=copy(ctx.rig()),snapshot=ctx.session(),sessions=copy(rig.sessionLibrary);
    sessions.current={...sessions.current,snapshot};
    const audio=ctx.audio();
    const settings=ctx.settings();
    // Store physical configuration separately; the current session above owns
    // musical fields. project() restores both using the existing ownership rule.
    const physical=copy(rig);
    for(const key of Object.keys(snapshot))if(!['expressionSettings','audioLibrary'].includes(key))delete physical[key];
    delete physical.sessionLibrary;delete physical.recordedAudioFiles;delete physical.saved;
    physical.audioLibrary={nextId:audio.nextId};
    if(physical.expressionSettings)for(const port of physical.expressionSettings.ports){port.mappings=[];for(const button of port.switches||[]){button.mappings=[];button.press='none';button.hold='none';button.change='none';}}
    return {sessions,audio:{files:copy(audio.files),recordedFiles:copy(rig.recordedAudioFiles||[])},presets:{saved:copy(rig.saved||[])},settings:{...settings,appliance:physical}};
  }
  function prepare(payload){
    const checked=model.validate(payload);if(!checked.valid)throw Error(checked.error);
    const s=payload.settings;
    if(!s.appliance||!Array.isArray(s.network?.profiles)||typeof s.network.enabled!=='boolean'||!s.displays?.brightness||!['main','small'].every(id=>Number.isFinite(s.displays.brightness[id]))||typeof s.updates?.current!=='string'||!s.controller||!Array.isArray(s.presetFiles)||!Array.isArray(payload.presets.saved))throw Error('Appliance settings or saved presets are incomplete.');
    const base=copy(s.appliance);
    base.audioLibrary={...base.audioLibrary,files:copy(payload.audio.files),usbFiles:copy(ctx.audio().usbFiles||[])};
    base.recordedAudioFiles=copy(payload.audio.recordedFiles);base.saved=copy(payload.presets.saved);
    const rig=window.SegnoSessionFieldOwnership.project(base,payload.sessions.current.snapshot).rig;
    rig.sessionLibrary=copy(payload.sessions);delete rig.sessionLibrary.current.snapshot;
    rig.performanceRecording={...rig.performanceRecording,nextId:rig.performanceRecording?.nextId||1,active:null};
    return ctx.stores(rig,s);
  }
  const inspectArchive=archive=>{const checked=model.inspect(archive);if(!checked.valid)return checked;try{prepare(archive.contents);return checked;}catch(e){return {valid:false,error:e.message};}};
  const ui=window.createApplianceBackupStudy({...ctx,capture,archives,inspectArchive,
    writeArchives:(next,expected)=>{if(JSON.stringify(archives())!==JSON.stringify(expected))return false;if(ctx.writeArchives(next)!==true)return false;return true;},
    commitRestore:(payload,expected)=>{
      if(JSON.stringify(capture())!==JSON.stringify(expected))return 'Appliance data changed. Review the backup again.';
      let writes;try{writes=prepare(payload);}catch(e){return e.message;}
      const result=ctx.publish(writes,archives());
      if(!result.ok)return result.restored?'Restore could not be saved. Current data is unchanged.':'Restore failed and some settings could not be put back. Keep the backup connected and retry.';
      restored=copy(payload);return true;
    },completed:()=>ctx.restart()});
  return {...ui,capture,prepare,archives,restored:()=>copy(restored)};
};
