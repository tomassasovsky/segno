// Silent whole-loop speed UX; no production DSP or physical timing claims.
const {chromium,firefox}=require('playwright'),assert=require('node:assert/strict'),fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const b=await (kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const p=await b.newPage({viewport:{width:1920,height:1080}}),errors=[];
  p.on('pageerror',e=>errors.push(e.message));await p.clock.install({time:new Date('2026-09-07T18:00:00Z')});await p.clock.pauseAt(new Date('2026-09-07T18:00:01Z'));
  const base='http://127.0.0.1:8768/fx-ux-prototype.html',button=id=>p.locator('[data-action='+JSON.stringify(id)+']'),foot=id=>button('perform:'+id),snap=()=>p.evaluate(()=>segnoDemo.snapshot()),speed=async()=>(await snap()).performance.speed;
  const hold=async id=>{await foot(id).focus();await p.keyboard.down(' ');await p.clock.runFor(810);await p.keyboard.up(' ');};
  await p.goto(base+'?review=performance-custom&canvas=actual');await hold(7);assert.equal((await snap()).performance.view,'speed');assert.equal((await speed()).ratio,1,'entry release must not choose 8x');
  await p.evaluate(()=>{segnoDemo.setPlayback('Track 1',true);segnoDemo.setCapture('Track 2','overdubbing');});const before=await snap();
  for(const [id,rate,pitch,duration] of [[4,.5,-12,2],[5,2,12,.5],[6,4,24,.25],[7,8,36,.125]]){
   await foot(id).focus();await p.keyboard.down(' ');assert.equal((await speed()).ratio,rate,'speed changes on pedal down');await p.clock.runFor(900);await p.keyboard.up(' ');assert.equal((await speed()).ratio,rate,'hold/release do not repeat');await foot(id).click();assert.equal((await speed()).ratio,rate,'rate buttons are absolute');assert.equal((await speed()).pitchShift,pitch);assert.equal((await speed()).durationRatio,duration);assert.equal(await foot(id).locator('.pedal-led').getAttribute('data-state'),'active');
  }
  assert.equal(await foot(9).isDisabled(),true,'no bank for whole-loop rates');assert.equal(await foot(8).isDisabled(),true);await foot(2).click();assert.equal((await speed()).ratio,1);assert.equal(await foot(2).locator('.pedal-led').getAttribute('data-state'),'active');
  const after=await snap();for(const key of ['trackPitch','trackReverse','trackFade','expressionMix','mutedTracks','racks','loopSettings'])assert.deepEqual(after.rig[key],before.rig[key],key+' preserved');assert.deepEqual(after.trackPlayback,before.trackPlayback);assert.deepEqual(after.captureState,before.captureState);assert.deepEqual(after.liveMonitoring,before.liveMonitoring);
  await foot(5).focus();await p.keyboard.down(' ');await foot(3).click();await p.keyboard.up(' ');assert.equal((await snap()).performance.view,'tracks');assert.equal((await speed()).ratio,2);assert.match(await p.locator('.speed-stage-state').textContent(),/2×/);
  await hold(3);await hold(7);assert.equal((await speed()).ratio,2);await foot(1).click();assert.equal((await snap()).trackPlayback['Track 1'],false);assert.equal((await speed()).ratio,2);await foot(0).click();assert.equal((await snap()).rig.lastTrackPedalEvent.track,'Track 1');
  await p.goto(base+'?review=performance-speed-empty&canvas=actual');for(const id of [2,4,5,6,7])assert.equal(await foot(id).isDisabled(),true);assert.equal(await foot(3).isEnabled(),true);
  await p.goto(base+'?canvas=actual');await p.evaluate(()=>localStorage.clear());await p.reload();await button('stage').click();await hold(3);await hold(7);await foot(4).click();await p.reload();assert.equal((await speed()).ratio,.5);assert.equal((await snap()).performance.view,'tracks');
  for(const review of ['performance-speed','performance-speed-half','performance-speed-fast','performance-speed-empty','performance-speed-stage']){await p.goto(base+'?review='+review+'&canvas=actual');await p.evaluate(()=>document.fonts.ready);const bad=await p.evaluate(()=>[...document.querySelectorAll('#screen button,.speed-overview')].filter(e=>{const r=e.getBoundingClientRect();return r.x<0||r.y<0||r.right>1921||r.bottom>1081||e.scrollWidth>e.clientWidth+2||e.scrollHeight>e.clientHeight+2}).map(e=>e.textContent));assert.deepEqual(bad,[]);if(kind==='chrome'){fs.mkdirSync('docs/design/speed-previews',{recursive:true});await p.locator('#screen').screenshot({path:'docs/design/speed-previews/'+review+'.png'});}}
  assert.deepEqual(errors,[]);console.log(kind+': Speed entry, absolute rates, pitch/duration feedback, normal reset, LEDs, transport independence, Exit, empty tracks, persistence and layout passed.');
 }finally{await b.close();}
}})().catch(e=>{console.error(e);process.exitCode=1});
