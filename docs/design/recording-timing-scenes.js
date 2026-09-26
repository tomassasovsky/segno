// These review states use the shared transport and an isolated clock offset.
window.applyRecordingTimingScene = ({scene,tracks,rig,parts,playing,capturing,inputs,settings,transport,advance,select}) => {
  transport.reset();
  for (const t of tracks) {parts[t]=[];playing[t]=false;capturing[t]='idle';inputs[t]=['Guitar'];}
  rig.trackLayers={};rig.trackLength={};rig.mutedTracks=tracks.map(()=>false);rig.soloTracks=tracks.map(()=>false);
  rig.editHistory={serial:0,tracks:tracks.map(()=>({undo:[],redo:[]}))};
  Object.assign(settings(),{mode:'multi',tempo:120,signature:'4/4',click:'off',countIn:0,start:'press',recDub:false,lengthTiming:{bars:0,quantize:'immediate'},trackLengthTiming:{}});
  select(0);
  if(scene==='timing-count-in') {settings().countIn=1;transport.command('Record / Play',0);advance(500);return;}
  if(['timing-first-take','timing-first-review','timing-first-correction'].includes(scene)) {transport.command('Record / Play',0);advance(3500);transport.command(scene==='timing-first-review'?'Stop':'Record / Play',0);if(scene==='timing-first-correction')transport.adjustFirstTiming(1);return;}
  settings().mode='sync';settings().click='always';settings().lengthTiming.bars=4;settings().primaryTrack='Track 1';
  transport.command('Record / Play',0);advance(8000);settings().lengthTiming.bars=0;
  if(scene==='timing-primary-speed')rig.loopSpeed=2;
  if(scene==='timing-primary-reverse')rig.trackReverse={'Track 1':true};
  if(scene==='timing-primary-once')settings().trackPlayback={'Track 1':{once:true}};
  if(scene==='timing-primary-independent'){settings().trackAudioTempo={'Track 1':{follow:false}};settings().tempo=90;}
  advance(1000);
  if(scene==='timing-primary-clear'){select(1);transport.command('Record / Play',1);advance(1000);transport.command('Record / Play',1);advance(6000);select(0);transport.command('Clear',0);return;}
  if(scene==='timing-clock-loss'){select(1);transport.command('Record / Play',1);advance(2000);transport.clockLost({keepPlaying:true});return;}
  select(1);transport.command('Record / Play',1);advance(2000);transport.command('Record / Play',1);
  if(scene==='timing-cycle-complete')advance(5000);
};
