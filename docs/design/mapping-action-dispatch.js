// Source-independent dispatch. Host callbacks own persistence, transport and UI.
window.createMappingActionDispatch=({selected,trackCount,selectTrack,trackPedal,bank,fx,instrument,direct,invoke,transport,tapTempo,backing,session,loopMode,cutSound,available=()=>true,feedback=()=>{}})=>{
  function execute(key,token){
    if(!available())return;
    const action=window.SegnoAssignableActions.find(a=>a.key===key);
    if(!action){feedback('Unavailable action');return;}
    const run=(callback,...args)=>{if(typeof callback!=='function'){feedback('Control unavailable');return false;}const result=callback(...args);if(result?.reason)feedback(result.reason);return result;};
    if(action.group==='functions')return run(invoke,action.label);
    const op=action.operation;
    if(op==='instrument')return run(instrument,action,token);
    if(op==='fx')return run(fx,action.slot,token);
    if(op==='track-pedal')return run(trackPedal,action.scope);
    if(op==='select-track')return run(selectTrack,action.scope);
    if(op==='bank')return run(bank);
    if(op==='backing')return run(backing,action.value);
    if(op==='session')return run(session,action.value);
    if(op==='loop-mode')return run(loopMode,action.value,token);
    if(op==='tap-tempo')return run(tapTempo);
    if(op==='cut-sound')return run(cutSound);
    if(op==='start-stop-all'||op==='clear-all')return run(transport,op==='clear-all'?'Clear all':'Start / Stop all');
    const tracks=action.scope==='all'?Array.from({length:trackCount()},(_,i)=>i):[action.scope==='selected'?selected():action.scope];
    return run(direct,{operation:op,tracks,value:action.value});
  }
  return {dispatch:(key,token)=>{const result=execute(key,token);return typeof result==='function'?result:undefined;}};
};
