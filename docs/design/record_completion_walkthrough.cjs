// Record real prototype interactions in isolated browser contexts.
// Captions and the pointer are recording-only overlays; product files are unchanged.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {execFileSync}=require('node:child_process');
const dry=process.argv.includes('--dry-run');
const only=process.argv.find(a=>a.startsWith('--only='))?.slice(7);
const output=path.join(__dirname,'completion-previews','walkthroughs');
const raw=path.join(output,'raw');
const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,dry?0:ms));
const flows=[
 {id:'01-usb-recording',title:'Record directly to USB',run:async c=>{
  await c.goto('performance-recording-ready');await c.note('Choose where this performance recording will be saved.');
  await c.tap('recorder:destination:usb');await c.note('USB is the recording destination. Internal storage stays available.');
  await c.tap('recorder:start');await c.clock(5300);const take=(await c.state()).recorder.pending;
  await c.note('This take is recording to the connected drive.');await c.shot('usb-recording');
  await c.note('Simulated interruption: the USB drive is disconnected.');await c.page.evaluate(()=>segnoDemo.simulateAudio({usbConnected:false}));
  assert.equal((await c.state()).recorder.phase,'recovered');await c.shot('usb-interrupted');await c.note('The last saved portion is held for recovery.');
  await c.page.evaluate(()=>segnoDemo.simulateRecordingDrive({id:'other-drive',label:'Other USB',connected:true}));await c.tap('recorder:save-recovered');
  await c.note('A different drive cannot finalize this take. Reconnect the original.');
  await c.page.evaluate(()=>segnoDemo.simulateRecordingDrive({id:'segno-usb-1',label:'SEGNO USB',connected:true}));await c.tap('recorder:save-recovered');await c.clock(850);
  assert.deepEqual((await c.state()).recorder.last.parts,take.parts);await c.tap('recorder:view');await c.shot('usb-saved');await c.note('The recovered take appears in the USB Library as one recording.',3200);
 }},
 {id:'02-selected-render',title:'Save and bounce selected tracks',run:async c=>{
  await c.goto('render-common');await c.note('Save audio combines the selected tracks, with their levels and effects.');
  await c.note('The common cycle covers every selected loop from start to finish.');await c.shot('save-common-cycle');
  await c.tap('audio:render:mix');await c.note('Mix FX includes the shared All tracks effects. Output effects stay out.');
  await c.tap('audio:render:longer');await c.tap('audio:render:cut');await c.note('You can choose a fixed length and cut tails at the file boundary.');
  await c.tap('audio:commit-save');await c.clock(1500);assert.equal((await c.state()).audioLibrary.view,'saved');await c.note('Saved as a new audio file. The source tracks are unchanged.');
  await c.goto('performance-bounce');await c.tap('perform:4',350);await c.tap('perform:5',350);await c.tap('perform:9',350);await c.tap('perform:4',350);
  await c.note('Bounce uses the same length rules: 2, 4 and 3-bar tracks repeat over 12 bars.');await c.shot('bounce-common-cycle');
  await c.tap('bounce-render:mix');await c.tap('perform:0');await c.tap('perform:7');await c.note('Track 8 is the destination. Keep sources leaves the originals intact.');
  await c.tap('perform:0');assert.equal((await c.state()).performance.bounce.step,'done');await c.note('The combined sound becomes one new loop. Undo restores the whole operation.');await c.tap('perform:2');
 }},
 {id:'03-sound-tails',title:'Hear Stop, Mute, bypass and Cut',run:async c=>{
  await c.goto('sound-behavior');await c.note('Listen to the same phrase. The marked action happens at 1.2 seconds.',2700);
  const examples=[['stop','Stop ends the loop; delay and reverb finish naturally.'],['clear','Clear removes the recording while already-fed effect tails finish.'],['mute','Mute silences the track; sound already in shared output effects can finish.'],['bypass','Bypass passes new audio dry while the existing effect tail drains.'],['cut','Cut sound silences the entire output immediately.'],['pre','Printed Pre is already part of the recording, so it stops with the loop.']];
  for(const [action,caption] of examples){await c.tap('sound-example:choose:'+action,100);await c.note(caption,1400);await c.tap('sound-example:play',0);await c.playAudio();await c.clock(4100);}
  await c.tap('sound-example:choose:stop',100);await c.tap('sound-example:volume:0',100);await c.note('Muting the listening output normally leaves the performance recording intact.');await c.shot('capture-before-output');
  await c.tap('sound-example:follow');await c.note('With Follow output volume enabled, that mute is included in the recording.');await c.shot('capture-follows-output');
 }},
 {id:'04-timing',title:'Timing, recovery and the primary track',run:async c=>{
  await c.goto('timing-primary-speed');await c.note('Track 1 plays at double speed. Track 2 still records against the musical cycle.');
  await c.shot('timing-cycle');await c.clock(5100);await c.tap('stage-view-menu');await c.tap('stage-view:wave');await c.note('The queued ending completes at the cycle boundary; the unwritten beginning is silent.');
  await c.goto('timing-primary-clear');await c.note('Clearing the timing track first asks which recorded track should replace it.');await c.tap('primary:choose:Track%202');await c.shot('primary-clear-review');
  await c.note('Cancel keeps the original. Confirm stops, clears and switches together.');await c.tap('primary:cancel');await c.tap('primary:choose:Track%202');await c.tap('primary:confirm');assert.equal((await c.state()).loopSettings.primaryTrack,'Track 2');
  await c.goto('timing-first-review');await c.note('After a first take, an optional review corrects half-time or double-time inference.');await c.shot('first-timing-review');await c.tap('timing-review:1');
  assert.equal((await c.state()).rig.trackLayers['Track 1'].layers[0].seconds,3.5);await c.note('Choosing one bar changes the musical interpretation. The 3.5-second recording is preserved.');
  await c.goto('timing-clock-loss');await c.note('If external clock is lost, the partial take is preserved inside its full loop. Reconnection does not start another take.');await c.shot('clock-loss-recovered');
 }},
 {id:'05-touch-and-solo',title:'Touch lock and optional double-press Solo',run:async c=>{
  await c.goto('performance-tracks');await c.note('Lock the touchscreen during a performance. Pedals and encoder continue working.');await c.tap('touch-lock:lock');await c.tap('settings',350);assert.equal((await c.state()).page,'stage');
  await c.note('This simulated physical Track 2 press still selects Track 2.');await c.foot(5);await c.shot('touch-locked');
  await c.note('Turn the encoder to Unlock, then press it.');await c.page.evaluate(()=>{segnoDemo.turn(-100);segnoDemo.press();});assert.equal(await c.page.evaluate(()=>segnoDemo.touchLockState().locked),false);
  await c.tap('settings');await c.tap('pedal-setup');await c.tap('setup:select:4');await c.tap('setup:double-solo');await c.shot('double-solo-setting');await c.note('Double-press Solo is optional and off by default. Save enables it for track pedals.');await c.tap('setup:save');await c.tap('stage');
  await c.note('Two short Track 2 presses toggle Solo. A hold still performs its Hold assignment.');await c.foot(5);await c.clock(100);await c.foot(5);assert.equal((await c.state()).rig.soloTracks[1],true);await c.shot('double-solo-active');await c.note('Solo remains active after release. Double-press again to restore the mix.');
 }},
 {id:'06-midi-formats',title:'Expanded MIDI Learn',run:async c=>{
  await c.goto('performance-tracks');await c.tap('settings');await c.tap('midi:open');
  const learn=async mode=>{await c.tap('midi:add');await c.tap('midi:protocol-picker');await c.tap('midi:protocol:'+mode);};
  const send=(number,value,kind='cc')=>c.page.evaluate(v=>segnoDemo.midiReceive('usb',{kind:v.kind,number:v.number,value:v.value,channel:1}),{number,value,kind});
  const volume=async()=>{await c.tap('midi:choose');await c.tap('midi:destination:Track%201');await c.tap('midi:target:'+encodeURIComponent(JSON.stringify(['mix','Track 1','level'])));};
  await c.note('Choose the format before learning. Segno waits for a complete message.');await learn('cc14');await send(21,64);await send(53,1);await volume();await c.shot('midi-14bit');await c.note('A 14-bit control provides a fine range for Track 1 volume.');await c.tap('midi:save');
  await learn('nrpn');await send(99,2);await send(98,3);await send(6,64);await send(38,7);await volume();await c.shot('midi-nrpn');await c.note('NRPN keeps the parameter identity and its full 14-bit value.');await c.tap('midi:save');
  await learn('bank-program');await send(0,2);await send(32,4);await send(8,127,'program');await c.tap('midi:choose');await c.tap('midi:actions');await c.tap('midi:action-group:transport');await c.tap('midi:target:command%3Acut-sound');await c.shot('midi-bank-program');await c.note('A particular bank and program can trigger an action, such as Cut sound.');await c.tap('midi:save');
  await learn('relative');await send(22,127);await volume();await c.shot('midi-relative');await c.note('Relative knobs move from the current value instead of jumping to an absolute position.');await c.tap('midi:save');
 }},
 {id:'07-source-evidence',title:'What still needs original source material',run:async c=>{
  await c.page.goto(base.replace('fx-ux-prototype.html','fx-reference-inspector.html'));await c.page.locator('#detail h2').waitFor();await c.note('The evidence inspector separates known source values from unverified control behavior.',3300);
  await c.tap(c.page.locator('[data-tab="singles"]'));await c.note('Single-effect schemas still need the native definitions. Preset values cannot establish valid ranges.',3200);
  await c.tap(c.page.locator('[data-tab="audio"]'));await c.page.locator('#search').fill('035 6-8 Brushes 1.wav');await c.note('The supplied firmware contains the factory names, but not the audio files.',3200);
  await c.note('These two source gaps remain open. The other flows in this recording are implemented in the prototype.',4200);
 }}
];
async function record(browser,flow,index){
 const context=await browser.newContext({viewport:{width:1920,height:1200},...(!dry?{recordVideo:{dir:raw,size:{width:1920,height:1200}}}:{})});
 const events=[];await context.exposeFunction('__captureSound',data=>events.push({...data,at:Date.now()}));const page=await context.newPage();let endedAt=0;page.setDefaultTimeout(8000);const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.clock.install({time:new Date('2026-09-09T12:00:00Z')});await page.clock.pauseAt(new Date('2026-09-09T12:00:01Z'));
 await page.addInitScript(({title,index})=>{const start=AudioBufferSourceNode.prototype.start;AudioBufferSourceNode.prototype.start=function(...args){if(this.buffer)window.__captureSound({sampleRate:this.buffer.sampleRate,samples:Array.from(this.buffer.getChannelData(0))});return start.apply(this,args);};document.addEventListener('DOMContentLoaded',()=>{
  const style=document.createElement('style');style.textContent='#prototype{position:absolute!important;top:120px!important;left:0!important;width:1920px!important;max-width:none!important;padding:0!important;margin:0!important}.labline,.lab-controls,.labnote{display:none!important}.viewport{height:1080px!important;width:1920px!important}#screen{transform:none!important}body{height:1200px!important;overflow:hidden!important}body:has(.totals)>main{margin-top:120px!important;padding-top:20px!important}body:has(.totals) .items{max-height:430px!important}#walk-caption{position:fixed;inset:0 0 auto;height:120px;background:#18202b;border-bottom:1px solid #53647c;padding:18px 34px;color:#e7edf6;font-family:Arial,sans-serif;z-index:2147483645;pointer-events:none}#walk-title{font-size:22px;color:#aabdd4;margin-bottom:9px}#walk-step{font-size:28px;line-height:1.15}#walk-label{position:absolute;top:18px;right:32px;font-size:18px;color:#9eacc0}#walk-pointer{position:fixed;width:30px;height:30px;border-radius:50%;border:3px solid #fff;background:#18202b88;box-shadow:0 0 0 4px #648ab455;transform:translate(-50%,-50%);pointer-events:none;z-index:2147483647;left:-60px;top:-60px}#walk-pointer.down{background:#fff;box-shadow:0 0 0 14px #b7cbe866}';document.head.append(style);
  const caption=document.createElement('div');caption.id='walk-caption';caption.innerHTML='<div id="walk-title"></div><div id="walk-step"></div><div id="walk-label">Browser prototype · recorded interactions</div>';document.body.append(caption);document.getElementById('walk-title').textContent=(index+1)+' / 7 · '+title;
  const pointer=document.createElement('div');pointer.id='walk-pointer';document.body.append(pointer);document.addEventListener('mousemove',e=>{pointer.style.left=e.clientX+'px';pointer.style.top=e.clientY+'px';},true);document.addEventListener('mousedown',()=>pointer.classList.add('down'),true);document.addEventListener('mouseup',()=>pointer.classList.remove('down'),true);
 });},{title:flow.title,index});
 const button=id=>page.locator('[data-action='+JSON.stringify(id)+']');
 const tap=async(target,wait=950)=>{const locator=typeof target==='string'?button(target):target;await locator.waitFor({state:'visible'});assert(await locator.isEnabled(),'Enabled action '+String(target));await locator.scrollIntoViewIfNeeded();const b=await locator.boundingBox();await page.mouse.move(b.x+b.width/2,b.y+b.height/2,{steps:dry?1:20});await pause(250);await page.mouse.down();await pause(180);await page.mouse.up();await pause(wait);};
 const note=async(text,wait=2200)=>{await page.evaluate(text=>{document.getElementById('walk-step').textContent=text;},text);await pause(wait);};
 const goto=async review=>{await page.goto(base+'?review='+review+'&canvas=actual');await page.waitForFunction(()=>window.segnoDemo);await page.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode().catch(()=>{})));});};
 const state=()=>page.evaluate(()=>segnoDemo.snapshot());const clock=ms=>page.clock.runFor(ms);
 const shot=async name=>{fs.mkdirSync(output,{recursive:true});await page.locator('#screen').screenshot({path:path.join(output,name+'.png')});fs.writeFileSync('/tmp/segno-pen-completion-'+name+'.json',JSON.stringify(await require('./prototype-geometry.cjs')(page)));};const foot=async id=>{await page.evaluate(id=>segnoDemo.performanceDown(id,'physical-walkthrough'),id);await clock(30);await page.evaluate(()=>segnoDemo.performanceUp('physical-walkthrough'));};const playAudio=async()=>{if(dry){await clock(4100);return;}let previous=Date.now();const end=previous+4200;while(Date.now()<end){await pause(80);const now=Date.now();await clock(now-previous);previous=now;}};try{await flow.run({page,button,tap,note,goto,state,clock,shot,foot,playAudio});assert.deepEqual(errors,[]);}
 catch(e){console.error('Walkthrough failed: '+flow.title,e);fs.mkdirSync(output,{recursive:true});await page.screenshot({path:path.join(output,flow.id+'-error.png')}).catch(()=>{});throw e;}
 finally{endedAt=Date.now();await context.close();}
 if(dry){console.log('Verified interactions: '+flow.title);return;}
 const video=await page.video().path(),target=path.join(output,flow.id+'.mp4');
 const videoSeconds=Number(execFileSync('ffprobe',['-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',video],{encoding:'utf8'}));
 const sampleRate=24000,samples=new Float32Array(Math.ceil(videoSeconds*sampleRate));
 for(const event of events){const start=Math.round(Math.max(0,videoSeconds-(endedAt-event.at)/1000)*sampleRate);for(let i=0;i<event.samples.length;i++){const target=start+Math.round(i*sampleRate/event.sampleRate);if(target<samples.length)samples[target]+=event.samples[i];}}
 const wav=path.join(output,flow.id+'.wav'),bytes=Buffer.alloc(44+samples.length*2);bytes.write('RIFF',0);bytes.writeUInt32LE(bytes.length-8,4);bytes.write('WAVEfmt ',8);bytes.writeUInt32LE(16,16);bytes.writeUInt16LE(1,20);bytes.writeUInt16LE(1,22);bytes.writeUInt32LE(sampleRate,24);bytes.writeUInt32LE(sampleRate*2,28);bytes.writeUInt16LE(2,32);bytes.writeUInt16LE(16,34);bytes.write('data',36);bytes.writeUInt32LE(samples.length*2,40);samples.forEach((v,i)=>bytes.writeInt16LE(Math.round(Math.max(-1,Math.min(1,v))*32767),44+i*2));fs.writeFileSync(wav,bytes);
 execFileSync('ffmpeg',['-y','-loglevel','error','-i',video,'-i',wav,'-c:a','aac','-b:a','96k','-c:v','libx264','-preset','fast','-crf','21','-pix_fmt','yuv420p','-r','30','-movflags','+faststart','-shortest',target]);fs.unlinkSync(wav);
 const seconds=Number(execFileSync('ffprobe',['-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',target],{encoding:'utf8'}));
 fs.unlinkSync(video);console.log('Recorded '+flow.title+' ('+Math.round(seconds)+' seconds)');
 return {id:flow.id,title:flow.title,seconds,file:flow.id+'.mp4'};
}
(async()=>{fs.mkdirSync(raw,{recursive:true});const browser=await chromium.launch({headless:true,executablePath:process.env.ATLAS_CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});try{
 const manifest=[];for(const [i,flow] of flows.entries()){if(only&&flow.id!==only)continue;const clip=await record(browser,flow,i);if(clip)manifest.push(clip);}
 if(!dry){const p=path.join(output,'clips.json'),old=fs.existsSync(p)?JSON.parse(fs.readFileSync(p,'utf8')):[];const combined=only?[...old.filter(v=>!manifest.some(n=>n.id===v.id)),...manifest].sort((a,b)=>a.id.localeCompare(b.id)):manifest;fs.writeFileSync(p,JSON.stringify(combined,null,2)+'\n');}
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
