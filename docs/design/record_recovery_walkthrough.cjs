// Record real prototype interactions in isolated browser contexts.
// Captions and the pointer are recording-only overlays; product files are unchanged.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {execFileSync}=require('node:child_process');
const dry=process.argv.includes('--dry-run');
const only=process.argv.find(a=>a.startsWith('--only='))?.slice(7);
const output=path.join(__dirname,'recovery-expansion-previews','walkthroughs');
const raw=path.join(output,'raw');
const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,dry?0:ms));
const flows=[
 {id:'01-recorded-audio',title:'Recover recorded audio',run:async c=>{
  await c.goto('loop-audio-missing');await c.tap('recover:cancel',0);
  await c.note('Open a saved session with a damaged loop recording.');
  await c.tap('session:load');
  const before=await c.state();
  await c.note('Track 2 needs its original recording. The current session stays open.');
  await c.tap(c.page.locator('[data-action^="recover:choose:"]').first());
  await c.note('Choose an intact copy of the same recording.');
  await c.tap('recover:file:backup-original');
  assert.equal((await c.state()).sessions.recovery.problems.length,0);
  await c.note('The replacement is ready. Cancel leaves the current setup untouched.');
  await c.tap('recover:cancel');assert.deepEqual((await c.state()).rig,before.rig);
  await c.tap('session:load');await c.tap(c.page.locator('[data-action^="recover:choose:"]').first());
  await c.tap('recover:file:backup-original');await c.tap('recover:open');
  const s=await c.state();assert.equal(s.loopSettings.mode,'multi');assert.equal(s.rig.trackLength['Track 2'].durationBeats,16);assert.equal(s.rig.trackLayers['Track 2'].layers[0].beats,4);
  if(s.page!=='stage')await c.tap('stage');
  await c.tap('stage-view-menu');await c.tap('stage-view:wave');
  await c.note('Recovered: one bar of audio inside the same four-bar loop.',3600);
 }},
 {id:'02-audio-connections',title:'Repair audio connections',run:async c=>{
  await c.goto('audio-ports-missing');await c.tap('session:dependency-cancel',0);
  await c.note('Open a session saved with another audio interface.');
  await c.tap('session:load');const before=await c.state();
  await c.note('The saved guitar port is missing. Choose its replacement.');
  await c.tap('session:connection:0');
  await c.note('Available ports show which recording and monitoring routes will change.');
  const option=c.page.locator('[data-action^="session:replacement:"]:not(:disabled)').first();
  await c.tap(option);assert.equal((await c.state()).sessions.dialog.changes.length,1);
  await c.note('Review the exact change before applying it.');
  await c.tap('session:dependency-cancel');assert.deepEqual((await c.state()).rig.audioRouting,before.rig.audioRouting);
  await c.note('Cancel keeps the existing connections.');
  await c.tap('session:load');await c.tap('session:connection:0');await c.tap(option);await c.tap('session:dependency-retry');
  assert.equal((await c.state()).rig.audioRouting.portBindings[0].interfaceId,'stage');
  await c.note('The session opens with the replacement port. Musical routing stays intact.',3200);
 }},
 {id:'03-appliance-backup',title:'Back up and restore the appliance',run:async c=>{
  await c.goto('appliance-backup');await c.tap('stage',0);
  await c.note('Start in Settings, then Storage.');
  await c.tap('settings');await c.tap('storage:open');await c.tap('appliance-backup:open');
  await c.note('Back up sessions, recordings, presets and settings together.');
  await c.tap('appliance-backup:create');await c.note('Review what the backup contains.');await c.tap('appliance-backup:save');
  assert.equal((await c.page.evaluate(()=>segnoDemo.applianceBackup())).phase,'complete');
  await c.note('The backup is now available on USB.');await c.tap('appliance-backup:review');
  await c.note('Restore replaces the whole setup and restarts Segno. Cancel is still available.',3000);
  await c.tap('appliance-backup:cancel');await c.note('Cancel returns without restoring.');
  await c.tap('appliance-backup:review');
  await c.tap('appliance-backup:restore',0);await c.note('Restoring the reviewed backup, then restarting.',1500);
  await Promise.all([c.page.waitForURL(/review=appliance-restored/),c.clock(1).catch(e=>{if(!/context|navigation/i.test(e.message))throw e;})]);
  await c.page.waitForFunction(()=>window.segnoDemo?.snapshot().page==='stage');
  await c.note('Restored. Segno returns to the normal Tracks view.',3500);
 }},
 {id:'04-timing-track',title:'Choose the timing track',run:async c=>{
  await c.goto('primary-playing');await c.tap('primary:cancel',0);await c.tap('stage',0);
  await c.note('In Sync mode, choose which recorded track sets the timing.');
  await c.tap('settings');await c.tap('loop:page:loop-settings');await c.tap('primary:open');
  await c.note('Track 1 is the current timing source. Select Track 2.');
  await c.tap('primary:choose:Track%202');assert.equal((await c.state()).primary.current,'Track 1');
  await c.note('Loops are playing, so switching requires an explicit stop.');
  await c.tap('primary:cancel');assert.equal((await c.state()).trackPlayback['Track 1'],true);
  await c.note('Cancel keeps Track 1 and playback running.');
  await c.tap('primary:choose:Track%202');await c.tap('primary:confirm');
  const s=await c.state();assert.equal(s.primary.current,'Track 2');assert(Object.values(s.trackPlayback).every(v=>!v));
  await c.tap('stage');await c.note('The timing marker moves to Track 2. Recordings keep their lengths.',3500);
 }},
 {id:'05-preset-audition',title:'Try a preset, then Keep or Cancel',run:async c=>{
  await c.goto('preset-audition');await c.tap('audition:cancel',0);const before=await c.state();
  const original=structuredClone(before.rig.racks.find(r=>r.id==='rack-1'));
  await c.note('Open Try preset from the rack editor.');await c.tap('try-preset');
  const options=c.page.locator('[data-action^="audition:choose:"]:not(:disabled)');
  await c.tap(options.nth(1));await c.note('Selecting a sound temporarily changes the rack parameters.');
  await c.tap(options.nth(2));await c.note('Compare another sound without saving it.');
  await c.tap('audition:cancel');assert.deepEqual((await c.state()).rig.racks.find(r=>r.id==='rack-1'),original);
  await c.note('Cancel restores the exact previous sound and assignments.');
  await c.tap('try-preset');await c.tap(options.nth(1));const trial=(await c.state()).rig.racks.find(r=>r.id==='rack-1');
  await c.tap('audition:keep');assert.equal((await c.state()).audition.active,false);assert.deepEqual((await c.state()).rig.racks.find(r=>r.id==='rack-1'),trial);
  await c.note('Keep commits the chosen sound. Rack placement and control identities stay intact.',3500);
 }},
 {id:'06-long-recordings',title:'Long recordings and low storage',run:async c=>{
  await c.goto('performance-recording-ready');await c.tap('stage',0);
  await c.note('Open Library, Audio, then Record performance.');
  await c.tap('session:library');await c.tap('audio-library');await c.tap('recorder:open');
  await c.tap('recorder:start');await c.clock(3200);await c.note('The timer and remaining recording time update together.');
  await c.note('Time is advanced to eight hours for this demonstration.');
  await c.page.evaluate(()=>segnoDemo.simulateRecorder({elapsedSeconds:28800}));await c.clock(120);
  assert((await c.state()).recorder.pending.parts.length>1);
  await c.note('Several file parts still form one continuous take.',3500);
  await c.tap('recorder:stop');await c.clock(850);assert.equal((await c.state()).recorder.phase,'saved');
  await c.tap('recorder:view');await c.note('The complete take appears as one recording in Library.',3200);
  await c.tap('recorder:open');await c.tap('recorder:again');
  await c.page.evaluate(()=>segnoDemo.simulateStorage({freeBytes:1e9+2*48000*6+44}));
  await c.note('Low-storage example: only two seconds remain before the reserve.');
  await c.tap('recorder:start');await c.clock(1100);await pause(900);await c.clock(2000);
  assert.equal((await c.state()).recorder.phase,'recovered');
  await c.note('Recording stops safely. The captured portion stays available to save.',3500);
  await c.tap('recorder:save-recovered');await c.clock(850);assert.equal((await c.state()).recorder.last.seconds,2);
  await c.tap('recorder:view');await c.note('The recovered recording is now in Library.',3200);
  await c.tap('recorder:open');await c.tap('recorder:again');await c.page.evaluate(()=>segnoDemo.simulateStorage({freeBytes:null}));
  assert(await c.button('recorder:start').isDisabled());await c.note('If remaining capacity is unknown, Start recording is unavailable.',3500);
 }}
];
async function record(browser,flow,index){
 const context=await browser.newContext({viewport:{width:1920,height:1200},...(!dry?{recordVideo:{dir:raw,size:{width:1920,height:1200}}}:{})});
 const page=await context.newPage();page.setDefaultTimeout(8000);const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.clock.install({time:new Date('2026-09-09T12:00:00Z')});await page.clock.pauseAt(new Date('2026-09-09T12:00:01Z'));
 await page.addInitScript(({title,index})=>{document.addEventListener('DOMContentLoaded',()=>{
  const style=document.createElement('style');style.textContent='#prototype{position:absolute!important;top:120px!important;left:0!important;width:1920px!important;max-width:none!important;padding:0!important;margin:0!important}.labline,.lab-controls,.labnote{display:none!important}.viewport{height:1080px!important;width:1920px!important}#screen{transform:none!important}body{height:1200px!important;overflow:hidden!important}#walk-caption{position:fixed;inset:0 0 auto;height:120px;background:#18202b;border-bottom:1px solid #53647c;padding:18px 34px;color:#e7edf6;font-family:Arial,sans-serif;z-index:2147483645;pointer-events:none}#walk-title{font-size:22px;color:#aabdd4;margin-bottom:9px}#walk-step{font-size:28px;line-height:1.15}#walk-label{position:absolute;top:18px;right:32px;font-size:18px;color:#9eacc0}#walk-pointer{position:fixed;width:30px;height:30px;border-radius:50%;border:3px solid #fff;background:#18202b88;box-shadow:0 0 0 4px #648ab455;transform:translate(-50%,-50%);pointer-events:none;z-index:2147483647;left:-60px;top:-60px}#walk-pointer.down{background:#fff;box-shadow:0 0 0 14px #b7cbe866}';document.head.append(style);
  const caption=document.createElement('div');caption.id='walk-caption';caption.innerHTML='<div id="walk-title"></div><div id="walk-step"></div><div id="walk-label">Silent prototype · recorded interactions</div>';document.body.append(caption);document.getElementById('walk-title').textContent=(index+1)+' / 6 · '+title;
  const pointer=document.createElement('div');pointer.id='walk-pointer';document.body.append(pointer);document.addEventListener('mousemove',e=>{pointer.style.left=e.clientX+'px';pointer.style.top=e.clientY+'px';},true);document.addEventListener('mousedown',()=>pointer.classList.add('down'),true);document.addEventListener('mouseup',()=>pointer.classList.remove('down'),true);
 });},{title:flow.title,index});
 const button=id=>page.locator('[data-action='+JSON.stringify(id)+']');
 const tap=async(target,wait=950)=>{const locator=typeof target==='string'?button(target):target;await locator.waitFor({state:'visible'});assert(await locator.isEnabled(),'Enabled action '+String(target));await locator.scrollIntoViewIfNeeded();const b=await locator.boundingBox();await page.mouse.move(b.x+b.width/2,b.y+b.height/2,{steps:dry?1:20});await pause(250);await page.mouse.down();await pause(180);await page.mouse.up();await pause(wait);};
 const note=async(text,wait=2200)=>{await page.evaluate(text=>{document.getElementById('walk-step').textContent=text;},text);await pause(wait);};
 const goto=async review=>{await page.goto(base+'?review='+review+'&canvas=actual');await page.waitForFunction(()=>window.segnoDemo);await page.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode().catch(()=>{})));});};
 const state=()=>page.evaluate(()=>segnoDemo.snapshot());const clock=ms=>page.clock.runFor(ms);
 try{await flow.run({page,button,tap,note,goto,state,clock});assert.deepEqual(errors,[]);}
 catch(e){console.error('Walkthrough failed: '+flow.title,e);fs.mkdirSync(output,{recursive:true});await page.screenshot({path:path.join(output,flow.id+'-error.png')}).catch(()=>{});throw e;}
 finally{await context.close();}
 if(dry){console.log('Verified interactions: '+flow.title);return;}
 const video=await page.video().path(),target=path.join(output,flow.id+'.mp4');
 execFileSync('ffmpeg',['-y','-loglevel','error','-i',video,'-an','-c:v','libx264','-preset','fast','-crf','21','-pix_fmt','yuv420p','-r','30','-movflags','+faststart',target]);
 const seconds=Number(execFileSync('ffprobe',['-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',target],{encoding:'utf8'}));
 fs.unlinkSync(video);console.log('Recorded '+flow.title+' ('+Math.round(seconds)+' seconds)');
 return {id:flow.id,title:flow.title,seconds,file:flow.id+'.mp4'};
}
(async()=>{fs.mkdirSync(raw,{recursive:true});const browser=await chromium.launch({headless:true,executablePath:process.env.ATLAS_CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});try{
 const manifest=[];for(const [i,flow] of flows.entries()){if(only&&flow.id!==only)continue;const clip=await record(browser,flow,i);if(clip)manifest.push(clip);}
 if(!dry){const p=path.join(output,'clips.json'),old=fs.existsSync(p)?JSON.parse(fs.readFileSync(p,'utf8')):[];const combined=only?[...old.filter(v=>!manifest.some(n=>n.id===v.id)),...manifest].sort((a,b)=>a.id.localeCompare(b.id)):manifest;fs.writeFileSync(p,JSON.stringify(combined,null,2)+'\n');}
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
