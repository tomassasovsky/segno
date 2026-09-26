// Review fixtures exercise the real silent transport commands, not separate histories.
window.applyCaptureRecoveryScene = ({scene,tracks,rig,parts,playing,capturing,inputs,settings,transport,advance,select}) => {
  transport.reset();
  for(const t of tracks){parts[t]=[];playing[t]=false;capturing[t]='idle';inputs[t]=['Guitar'];}
  rig.trackLayers={};rig.trackLength={};rig.mutedTracks=tracks.map(()=>false);rig.soloTracks=tracks.map(()=>false);
  rig.editHistory={serial:0,tracks:tracks.map(()=>({undo:[],redo:[]}))};
  Object.assign(settings(),{mode:'multi',tempo:120,signature:'4/4',countIn:0,start:'press',recDub:false,lengthTiming:{bars:4,quantize:'immediate'},trackLengthTiming:{}});
  transport.command('Record / Play',0);advance(8000);
  settings().lengthTiming.bars=0;
  if(scene.includes('clear')){
    transport.command('Record / Play',1);advance(8000);
    transport.command('Stop');transport.command('Record / Play',0);
    select(2);transport.command('Record / Play',2);advance(2000);
    settings().lengthTiming.quantize='loop';transport.command('Record / Play',3);
    if(scene.endsWith('cleared')||scene.endsWith('restored'))transport.command('Clear all',2);
    if(scene.endsWith('restored'))transport.command('Undo',2);
  }else{
    select(1);transport.command('Record / Play',1);advance(2000);transport.command('Undo',1);
    if(scene.endsWith('restored'))transport.command('Redo',1);
  }
};
