const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createRig,clone}=require('./audio-state-test-harness.cjs');
const primaryUI=require('./primary-track-study.js');
const near=(a,b)=>assert(Math.abs(a-b)<1e-7,`${a} differs from ${b}`);
const layers=(r,i=0)=>r.state[i].layers.layers;
const duration=(r,i=0)=>r.state[i].length.durationBeats;
const command=(r,a,i=0)=>r.transport.command(a,i);
function rig(mode='sync'){const r=createRig(mode);Object.assign(r.config,{click:'always',primaryTrack:'Track 1'});return r;}
function twoTracks(mode='sync'){const r=rig(mode);r.record(0,8);r.record(1,8);return r;}
const durable=r=>clone({state:r.state,history:r.history(),tempo:r.config.tempo,primary:r.config.primaryTrack});

for(const mode of ['sync','band'])test(mode+' musical cycle keeps advancing after Once primary stops during capture',()=>{
  const r=rig(mode);r.record(0,8);r.overrides[0]={speed:2,reverse:true,once:true,follow:false};
  r.advance(500);command(r,'Record / Play',1);r.advance(2000);
  assert.equal(r.state[0].playing,false);command(r,'Record / Play',1);
  assert.equal(r.transport.snapshot().pending[0].timing,'Primary cycle · 3 beats');
  r.advance(1500);assert.equal(duration(r,1),8);assert.deepEqual(layers(r,1)[0].regions,[{offsetBeats:1,beats:7}]);near(layers(r,1)[0].seconds,3.5);
});

test('elapsed capture seconds survive a session tempo change within an external-clock take',()=>{
  const r=rig();r.config.externalClock=true;command(r,'Record / Play');r.advance(1000);r.config.tempo=60;r.advance(1000);command(r,'Stop');
  assert.equal(duration(r),3);assert.equal(layers(r)[0].seconds,2);assert.equal(r.config.tempo,60);
  command(r,'Undo');command(r,'Redo');assert.equal(layers(r)[0].seconds,2);
});

for(const mode of ['multi','sync','band'])test(mode+' clock loss retains sparse partial take and policy preserves the other playback',()=>{
  const r=rig(mode);r.record(0,16);r.config.externalClock=true;r.advance(3000);command(r,'Record / Play',1);r.advance(2000);
  assert.equal(r.transport.clockLost({keepPlaying:true}),true);assert.equal(r.capture[1],'idle');assert.equal(r.state[1].playing,false);assert.equal(r.state[0].playing,true);
  assert.equal(duration(r,1),16);assert.deepEqual(layers(r,1)[0].regions,[{offsetBeats:6,beats:4}]);assert.equal(layers(r,1)[0].seconds,2);
  const saved=clone(layers(r,1));r.advance(7000);assert.deepEqual(layers(r,1),saved);
  command(r,'Undo',1);assert.equal(layers(r,1).length,0);command(r,'Redo',1);assert.deepEqual(layers(r,1),saved);
});

test('clock loss stops all playback under Stop policy and cancels queued arms',()=>{
  const r=twoTracks('multi');r.config.externalClock=true;command(r,'Arm overdub');r.advance(500);r.config.quantize='bar';command(r,'Record / Play',2);
  assert.equal(r.transport.snapshot().pending.length,1);r.transport.clockLost({keepPlaying:false});
  assert(r.state.every(t=>!t.playing));assert(r.capture.every(c=>c==='idle'));assert.equal(r.transport.snapshot().pending.length,0);assert.equal(layers(r).at(-1).seconds,.5);
});

test('failed clock-loss save freezes measured material and Stop retry publishes it once',()=>{
  const r=rig('multi');r.record(0,16);r.config.externalClock=true;r.advance(3000);command(r,'Record / Play',1);r.advance(2000);
  const before=durable(r);r.failPublish(true);assert.equal(r.transport.clockLost({keepPlaying:true}),false);assert.deepEqual(durable(r),before);
  assert.deepEqual(clone(r.transport.snapshot().frozenRecoveries),[{track:1,seconds:2,beats:4}]);
  r.advance(10000);near(r.transport.info(1).beats,4);command(r,'Record / Play',2);assert.equal(r.capture[2],'idle');
  r.failPublish(false);command(r,'Stop');assert.equal(layers(r,1).length,1);assert.equal(layers(r,1)[0].seconds,2);assert.equal(layers(r,1)[0].beats,4);assert.equal(r.transport.snapshot().frozenRecoveries.length,0);
});

test('Undo of failed clock-loss take retains an exact Redo candidate without resuming capture',()=>{
  const r=rig('multi');r.record(0,16);r.config.externalClock=true;command(r,'Record / Play',1);r.advance(1500);r.failPublish(true);r.transport.clockLost();r.advance(10000);
  r.failPublish(false);command(r,'Undo',1);assert.equal(layers(r,1).length,0);assert.equal(r.capture[1],'idle');command(r,'Redo',1);assert.equal(layers(r,1)[0].seconds,1.5);assert.equal(layers(r,1)[0].beats,3);
});

test('failed automatic fixed boundary freezes instead of repeating publication or extending captured time',()=>{
  const r=rig();r.config.bars=1;command(r,'Record / Play');r.failPublish(true);r.advance(6000);
  assert.equal(r.publishedAttempts().length,1);assert.equal(r.transport.snapshot().frozenRecoveries[0].seconds,2);assert.equal(r.transport.info(0).beats,4);
  r.failPublish(false);command(r,'Stop');assert.equal(layers(r)[0].seconds,2);assert.equal(duration(r),4);
});

test('failed automatic overdub pass retains completed history and retries only the unsaved pass',()=>{
  const r=rig();r.record(0,4);command(r,'Arm overdub');r.advance(2000);const before=durable(r);r.failPublish(true);r.advance(7000);
  assert.deepEqual(durable(r),before);assert.equal(r.transport.snapshot().frozenRecoveries[0].seconds,4);
  r.failPublish(false);command(r,'Stop');assert.equal(layers(r).length,3);assert.equal(layers(r).at(-1).seconds,2);assert.equal(r.transport.nextEdit(0).label,'Overdub');
});

for(const mode of ['sync','band'])test(mode+' Clear timing source waits for an explicit valid successor and publishes stopped state atomically',()=>{
  const r=twoTracks(mode),before=durable(r);command(r,'Clear');assert.deepEqual(durable(r),before);assert.equal(r.transport.snapshot().primaryClear.track,0);
  assert.equal(r.transport.resolvePrimaryClear(2),false);assert.deepEqual(durable(r),before);
  r.failPublish(true);assert.equal(r.transport.resolvePrimaryClear(1),false);assert.deepEqual(durable(r),before);
  r.failPublish(false);assert.equal(r.transport.resolvePrimaryClear(1),true);assert.equal(layers(r).length,0);assert.equal(r.config.primaryTrack,'Track 2');assert(r.state.every(t=>!t.playing));
  assert.equal(duration(r,1),8);command(r,'Undo');assert.equal(r.config.primaryTrack,'Track 1');assert.deepEqual(r.state,before.state);
  command(r,'Redo');assert.equal(r.config.primaryTrack,'Track 2');assert.equal(layers(r).length,0);
});

test('Cancel clear leaves all state intact; stale source material cannot be cleared',()=>{
  const r=twoTracks(),before=durable(r);command(r,'Clear');r.transport.cancelPrimaryClear();assert.deepEqual(durable(r),before);
  command(r,'Clear');r.state[0].layers.layers[0].gain=.5;const changed=durable(r);assert.equal(r.transport.resolvePrimaryClear(1),false);assert.deepEqual(durable(r),changed);
});

test('clear final source empties timing explicitly; grouped Clear All and Undo restore the source',()=>{
  const r=rig();r.record(0,8);command(r,'Clear');assert.equal(r.config.primaryTrack,null);assert.equal(r.transport.snapshot().primaryClear,null);assert.equal(r.transport.snapshot().timingCycle.primary,-1);
  command(r,'Undo');assert.equal(r.config.primaryTrack,'Track 1');command(r,'Clear all');assert.equal(r.config.primaryTrack,null);r.transport.recover([0],'undo',['Clear all']);assert.equal(r.config.primaryTrack,'Track 1');
});

test('first-take half/double correction preserves actual seconds and is independently undoable',()=>{
  const r=rig('multi');r.config.click='off';command(r,'Record / Play');r.advance(3500);command(r,'Record / Play');
  let review=r.transport.snapshot().firstTakeTiming;assert.equal(review.bars,2);assert.equal(review.halfBars,1);assert.equal(review.doubleBars,4);near(review.seconds,3.5);
  const original=durable(r);r.failPublish(true);assert.equal(r.transport.adjustFirstTiming(1),false);assert.deepEqual(durable(r),original);
  r.failPublish(false);assert.equal(r.transport.adjustFirstTiming(1),true);assert.equal(duration(r),4);near(r.config.tempo,240/3.5);assert.equal(layers(r)[0].seconds,3.5);assert.equal(layers(r)[0].beats,4);assert.equal(r.state[0].playing,true);
  command(r,'Undo');near(r.config.tempo,480/3.5);assert.equal(duration(r),8);command(r,'Redo');near(r.config.tempo,240/3.5);assert.equal(duration(r),4);
  r.transport.reset();assert.equal(r.transport.snapshot().firstTakeTiming.bars,1);r.transport.dismissFirstTiming();assert.equal(r.transport.snapshot().firstTakeTiming,null);
});

test('timing corrections refuse invalid bounds and newer audio; Undo preserves later manual tempo',()=>{
  const r=rig('multi');r.config.click='off';r.record(0,4);const before=durable(r);
  for(const bars of [0,3,65,null,NaN])assert.equal(r.transport.adjustFirstTiming(bars),false);assert.deepEqual(durable(r),before);
  assert.equal(r.transport.adjustFirstTiming(2),true);r.config.tempo=99;command(r,'Undo');assert.equal(r.config.tempo,99);
  command(r,'Arm overdub');r.advance(500);command(r,'Record / Play');assert.equal(r.transport.snapshot().firstTakeTiming,null);
});

test('SPP requires stopped external transport, positions Continue and Start resets the musical origin',()=>{
  const r=rig();r.record(0,8);assert.equal(r.transport.songPosition(3),false);r.config.externalClock=true;
  assert.equal(r.transport.songPosition(3),false);assert.match(r.transport.snapshot().notice.action,/Stop playback/);r.transport.syncTransport('stop');
  assert.equal(r.transport.songPosition(3),true);near(r.transport.info(0).position,3/8);near(r.transport.snapshot().timingCycle.position,3/8);
  r.advance(3000);near(r.transport.snapshot().timingCycle.position,3/8);r.transport.syncTransport('continue');r.advance(500);near(r.transport.info(0).position,.5);near(r.transport.snapshot().timingCycle.position,.5);
  r.transport.syncTransport('stop');r.transport.syncTransport('start');near(r.transport.info(0).position,0);near(r.transport.snapshot().timingCycle.position,0);
});

test('SPP never seeks capture or queued clock arms and malformed positions are refused',()=>{
  const r=rig();r.config.externalClock=true;command(r,'Record / Play');r.advance(1000);const before=clone(r.transport.info(0));assert.equal(r.transport.songPosition(1),false);assert.deepEqual(clone(r.transport.info(0)),before);
  command(r,'Stop');r.config.waitingClock=true;command(r,'Record / Play',1);assert.equal(r.transport.songPosition(1),false);
  command(r,'Stop');for(const value of [-1,4096,Infinity,NaN,'4'])assert.equal(r.transport.songPosition(value),false);
});

test('clear-source chooser confirms even when only the removed track plays; navigation cancels pending clear',()=>{
  const r=twoTracks();r.state[1].playing=false;
  const ui=primaryUI.createUI({context:()=>({mode:'sync',primaryTrack:r.config.primaryTrack,pending:false,capturing:false,tracks:r.state.map((t,i)=>({id:'Track '+(i+1),hasAudio:!!t.parts.length,loopBeats:duration(r,i),playing:t.playing}))}),
    clear:id=>r.transport.resolvePrimaryClear(Number(id.split(' ')[1])-1),cancelClear:r.transport.cancelPrimaryClear,commit:()=>assert.fail('Clear must use the atomic clear adapter'),
    button:(id,text)=>`<button data-action="${id}">${text}</button>`,header:String,escape:String,go:()=>{},render:()=>{},focus:()=>{}});
  command(r,'Clear');ui.openClear('Track 1');const before=durable(r);
  assert(!ui.body().includes('primary:choose:Track%201'));ui.action('primary:choose:Track%202');assert.match(ui.overlay(),/Stop, clear and switch/);assert.deepEqual(durable(r),before);
  ui.action('primary:cancel');assert.equal(ui.back(),false);assert.equal(r.transport.snapshot().primaryClear,null);assert.deepEqual(durable(r),before);
  command(r,'Clear');ui.openClear('Track 1');ui.action('primary:choose:Track%202');ui.action('primary:confirm');assert.equal(r.config.primaryTrack,'Track 2');assert.equal(layers(r).length,0);
});

for(const fail of [false,true])test('Cut sound always silences players and cancels queues with capture save '+(fail?'failure':'success'),()=>{
  const r=twoTracks('multi');r.advance(1000);command(r,'Arm overdub');r.advance(500);r.config.quantize='bar';command(r,'Record / Play',2);
  const before=durable(r);r.failPublish(fail);assert.equal(r.transport.cutSound(),!fail);assert(r.state.every(t=>!t.playing));assert(r.capture.every(c=>c==='idle'));assert.equal(r.transport.snapshot().pending.length,0);
  if(fail){assert.deepEqual(r.state.map(t=>t.layers),before.state.map(t=>t.layers));assert.deepEqual(r.history(),before.history);r.advance(10000);near(r.transport.snapshot().frozenRecoveries[0].seconds,.5);r.failPublish(false);command(r,'Stop');}
  assert.equal(layers(r).at(-1).seconds,.5);assert.equal(r.transport.snapshot().frozenRecoveries.length,0);
});

test('Cut sound cancels a pending primary-clear request without clearing recorded content',()=>{
  const r=twoTracks(),before=r.state.map(t=>clone(t.layers));command(r,'Clear');assert(r.transport.snapshot().primaryClear);r.transport.cutSound();assert.equal(r.transport.snapshot().primaryClear,null);assert(r.state.every(t=>!t.playing));assert.deepEqual(r.state.map(t=>t.layers),before);
});

test('Undo of Clear All restores the musical cycle phase for a subsequent Sync take',()=>{
  const r=twoTracks();r.advance(1500);const phase=r.transport.snapshot().timingCycle.position;command(r,'Clear all');r.advance(3000);command(r,'Undo');near(r.transport.snapshot().timingCycle.position,phase);
  command(r,'Record / Play',2);r.advance(500);r.transport.clockLost({keepPlaying:true});near(layers(r,2)[0].regions[0].offsetBeats,phase*8);
});

test('independent primary plays its recorded seconds while the musical cycle follows changed session tempo',()=>{
  const r=rig();r.record(0,8);r.overrides[0]={follow:false};r.config.tempo=60;r.advance(1000);
  near(r.transport.info(0).position,.25);near(r.transport.snapshot().timingCycle.position,.125);
  command(r,'Record / Play',1);r.advance(1000);command(r,'Record / Play',1);r.advance(6000);
  assert.equal(duration(r,1),8);assert.deepEqual(layers(r,1)[0].regions,[{offsetBeats:1,beats:7}]);assert.equal(layers(r,1)[0].seconds,7);assert.equal(layers(r)[0].seconds,4);
});
