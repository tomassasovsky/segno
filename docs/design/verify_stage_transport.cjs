const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('docs/design/stage-transport-study.js','utf8');
function rig(){const context={window:{},performance:{now:()=>0}};vm.runInNewContext(source,context);let ms=0,chosen=0,changes=0;const tracks=Array.from({length:8},(_,i)=>i),audio=tracks.map(()=>({parts:[],beats:0,layers:[]})),playing=tracks.map(()=>false),capturing=tracks.map(()=>'idle');const config={tempo:120,beatsPerBar:4,signature:'4/4',countIn:0,start:'press',mode:'free',bars:0,quantize:'immediate',recDub:false,decay:0,once:false,inputs:['Guitar'],speed:1};const overrides={};let saved=null;const model=context.window.createStageTransportStudy({tracks,editState:{publish:(values,journal,clock)=>{for(const [i,v]of Object.entries(values)){audio[i]={parts:structuredClone(v.parts),beats:v.length.durationBeats,layers:structuredClone(v.layers.layers)};playing[i]=v.playing;}saved=structuredClone(journal);if(clock)Object.assign(config,clock);return true;},read:i=>({parts:structuredClone(audio[i].parts),length:{audio:[],durationBeats:audio[i].beats,note:''},layers:{layers:structuredClone(audio[i].layers)},playing:playing[i],mix:{level:1,pan:.5},fx:[],recipe:null}),write:values=>{for(const [i,v]of Object.entries(values)){audio[i]={parts:structuredClone(v.parts),beats:v.length.durationBeats,layers:structuredClone(v.layers.layers)};playing[i]=v.playing;}},readHistory:()=>saved,writeHistory:v=>saved=structuredClone(v)},read:i=>structuredClone(audio[i]),write:(i,v)=>audio[i]=structuredClone(v),settings:i=>({...config,...overrides[i]}),capture:(i,v)=>capturing[i]=v,playback:(i,v)=>{if(v!==undefined)playing[i]=v;return playing[i];},select:i=>chosen=i,selected:()=>chosen,changed:()=>changes++,now:()=>ms});return {model,audio,playing,capturing,config,overrides,advance:n=>{ms+=n;model.tick();},changes:()=>changes};}
{
 const r=rig(),m=r.model;m.command('Record / Play');r.advance(2000);m.command('Record / Play');assert.equal(r.audio[0].beats,4);assert.equal(r.audio[0].layers.length,1);assert.equal(r.playing[0],true);
 m.command('Record / Play');r.advance(4500);assert.equal(r.audio[0].layers.length,3,'two completed overdub passes');m.command('Undo');assert.equal(r.audio[0].layers.length,3,'partial third pass removed');assert.equal(r.capturing[0],'idle');m.command('Undo');assert.equal(r.audio[0].layers.length,2);m.command('Redo');assert.equal(r.audio[0].layers.length,3);
 m.command('Stop');m.command('Undo');assert.equal(r.playing[0],false,'undo never restarts a stopped overdub');m.command('Redo');assert.equal(r.playing[0],false);
 m.command('Clear');assert.equal(r.audio[0].layers.length,0);m.command('Undo');assert.equal(r.audio[0].layers.length,3);m.command('Redo');assert.equal(r.audio[0].layers.length,0);
}
{
 const r=rig(),m=r.model;m.command('Record / Play');r.advance(750);m.command('Undo');assert.equal(r.audio[0].layers.length,0);assert.equal(r.capturing[0],'idle');m.command('Redo');assert.equal(r.audio[0].beats,1.5);assert.equal(r.playing[0],true,'recovered first take plays immediately');
 m.command('Undo');m.command('Record / Play');r.advance(500);m.command('Record / Play');m.command('Redo');assert.equal(r.audio[0].beats,1,'new take removes forward redo');
}
{
 const r=rig(),m=r.model;r.config.countIn=1;m.command('Record / Play');assert.equal(r.capturing[0],'armed');r.advance(1500);assert.equal(r.capturing[0],'armed');r.advance(500);assert.equal(r.capturing[0],'recording');assert.equal(m.snapshot().elapsed,0);r.advance(500);r.config.quantize='bar';m.command('Record / Play');assert.equal(m.snapshot().pending[0].action,'Play');r.advance(1499);assert.equal(r.capturing[0],'recording');r.advance(1);assert.equal(r.capturing[0],'idle');assert.equal(r.audio[0].beats,4);assert.equal(m.snapshot().pending.length,0);
 r.advance(250);m.command('Select',1);m.command('Record / Play');assert.equal(m.snapshot().pending[0].track,1);m.command('Select',4);r.advance(1750);assert.equal(r.capturing[1],'recording','queued target stays fixed after selection changes');assert.equal(r.capturing[4],'idle');
 m.command('Stop');assert.equal(m.snapshot().pending.length,0);assert.ok(r.playing.every(v=>!v));
}
{
 const r=rig(),m=r.model;r.config.start='sound';m.command('Record / Play');r.advance(1000);assert.equal(r.capturing[0],'armed');m.signal();assert.equal(r.capturing[0],'recording');r.advance(1000);m.command('Record / Play');assert.equal(r.audio[0].beats,2);
 r.config.bars=1;r.config.recDub=true;r.config.decay=25;m.command('Select',1);m.command('Record / Play');r.advance(2000);assert.equal(r.capturing[1],'overdubbing');r.advance(2000);assert.equal(r.audio[1].layers[0].gain,.75);r.advance(2000);assert.equal(r.audio[1].layers[0].gain,.5625);m.command('Undo');assert.equal(r.audio[1].layers[0].gain,.75,'Undo restores pre-pass decay');assert.equal(r.capturing[1],'idle');
}
{
 const r=rig(),m=r.model;r.config.countIn=1;m.command('Record / Play');m.command('Undo');r.advance(4000);assert.equal(r.capturing[0],'idle');assert.equal(r.audio[0].layers.length,0,'cancel arm does not create history');
 r.config.countIn=0;m.command('Record / Play');m.command('Undo');assert.equal(r.audio[0].layers.length,0,'zero-length take leaves no bogus layer');
}
{
 const r=rig(),m=r.model;m.command('Record / Play');r.advance(2000);m.command('Record / Play');r.advance(500);const forward=m.info(0).position;r.config.reverse=true;r.advance(200);assert.ok(m.info(0).position<forward,'Reverse moves from the existing playhead position');r.config.once=true;r.advance(1000);assert.equal(r.playing[0],false,'Reverse Once ends at the start boundary');r.config.reverse=false;r.config.speed=2;m.command('Record / Play');r.advance(1000);assert.equal(r.playing[0],false,'Once completion respects Speed');
}
{
 const r=rig(),m=r.model;m.command('Record / Play');r.advance(1000);assert.equal(m.modeChanged(true),false,'mode handoff cannot end an active take');m.command('Record / Play');r.advance(200);const before=structuredClone(r.audio),history=m.snapshot().tracks[0].undo;
 r.playing.fill(false);assert.equal(m.modeChanged(true),true);assert.equal(m.info(0).position,0);assert.deepEqual(r.audio,before);assert.equal(m.snapshot().tracks[0].undo,history,'mode changes preserve audio history');m.command('Undo');assert.equal(r.audio[0].layers.length,0);m.command('Redo');assert.equal(r.audio[0].beats,2);
 r.config.quantize='bar';r.advance(200);m.command('Record / Play',1);assert.equal(m.modeChanged(true),false,'queued actions stay attached until completed or cancelled');
}
console.log('Transport model: recording, pass/partial Undo, Redo, decay recovery, fixed length, quantized boundaries, fixed queued target, count-in, sound arm, stop/cancel, mode handoff and redo branching pass.');
{
 const r=rig(),m=r.model;
 for(const i of [0,1]){m.command('Record / Play',i);r.advance(1000);m.command('Record / Play',i);}
 r.playing[1]=false;r.advance(200);const before=structuredClone(r.audio),position=m.info(0).position;
 m.command('Clear all');assert.ok(r.audio.every(v=>!v.layers.length));m.command('Undo',7);assert.deepEqual(r.audio,before);assert.equal(r.playing[0],true);assert.equal(r.playing[1],false);assert.equal(m.info(0).position,position);
 m.command('Redo',1);assert.ok(r.audio.every(v=>!v.layers.length));m.command('Undo',0);m.command('Clear all');m.command('Record / Play',1);r.advance(250);m.command('Record / Play',1);m.command('Undo',0);assert.equal(r.audio[1].beats,.5,'group undo cannot overwrite a newer edit');m.command('Undo',1);m.command('Undo',0);assert.deepEqual(r.audio,before);
 m.command('Start / Stop all');assert.ok(r.playing.every(v=>!v));m.command('Start / Stop all');assert.equal(r.playing[0],true);assert.equal(r.playing[1],true);assert.equal(r.playing[2],false);
 m.command('Record / Play',2);r.advance(100);m.command('Clear all');assert.equal(r.capturing[2],'idle');assert.equal(r.audio[0].layers.length,0);m.command('Undo',2);assert.equal(r.audio[2].beats,.2);assert.equal(r.playing[2],false,'partial take recovers stopped');assert.equal(r.audio[0].layers.length,1);
}
console.log('Grouped Clear all recovery, cross-track edit ordering and Start / Stop all pass.');
