// Performance recorder UX. Durations and recovery are simulated; no audio bytes.
window.createPerformanceRecordingStudy = function(ctx){
 const {button,header,escape:esc,icon,render}=ctx,clone=v=>structuredClone(v),model=window.SegnoPerformanceRecording;
 const initial=()=>({nextId:1,active:null,last:null,destination:'internal',followOutput:false});const state=()=>ctx.read()||initial();
 let phase=state().active?'recovered':'ready',error='',full=false,failed=false,slow=false,job=null,discard=false;
 let pending=clone(state().active),last=clone(state().last),lastCheckpoint=pending?.seconds||0,warning=false;
 const target=()=>pending?.storage||{location:state().destination==='usb'?'usb':'internal',...(state().destination==='usb'?{mediaId:ctx.usb?.().id,label:ctx.usb?.().label}: {})};
 const mediaReady=()=>target().location!=='usb'||!!(ctx.usb?.().connected&&!ctx.usb?.().ejecting&&ctx.usb?.().id===target().mediaId);
 const capacity=()=>mediaReady()?ctx.capacity(target()):{freeBytes:null,reserveBytes:0};
 const targetName=()=>target().location==='usb'?(target().label||'USB drive'):'Internal';
 function selectSetting(key,value){if(busy())return;const next=clone(state());next[key]=value;if(ctx.write(next,undefined,{settingsOnly:true})===false){error='Could not save recording settings.';}else error='';render();}
 const now=()=>ctx.now?ctx.now():Date.now();
 const seconds=()=>phase==='recording'?Math.max(0,(now()-pending.startedAt)/1000):pending?.seconds||0;
 const time=s=>{s=Math.floor(s);return `${Math.floor(s/3600)?Math.floor(s/3600)+':':''}${String(Math.floor(s/60)%60).padStart(2,'0')}:${String(s%60).padStart(2,'0')}`;};
 const busy=()=>['recording','saving','recovered'].includes(phase);
 function write(value,file,bytesUsed=0,bytesReleased=0){return !full&&!failed&&!slow&&ctx.write(value,file,{bytesUsed,bytesReleased,storage:target()})!==false;}
 function estimate(){
  const take=pending||model.create({id:'estimate',name:'Estimate.wav'},ctx.recordingFormat()).take;if(!take)return null;
  if(phase==='recording'){
   const frames=Math.max(0,Math.floor(seconds()*take.format.sampleRate)-take.frames),result=model.advance(take,frames,capacity());
   return result.error?null:result.remaining;
  }
  return model.remaining(take,capacity());
 }
 function checkpoint(){
  if(!mediaReady()){mediaChanged();return false;}
  const frames=Math.max(0,Math.floor(seconds()*pending.format.sampleRate)-pending.frames),result=model.advance(pending,frames,capacity());
  if(result.error){phase='recovered';error=result.error;render();return false;}
  const next=clone(state());next.active=result.take;
  if(result.bytesUsed&&!write(next,undefined,result.bytesUsed)){phase='recovered';error=slow?'The USB drive could not keep up. The last saved checkpoint is kept; your loops keep playing.':'Recording stopped because storage could not be written. The last saved checkpoint is kept; your loops keep playing.';render();return false;}
  pending=result.take;lastCheckpoint=pending.seconds;
  if(result.stopped){phase='recovered';error=result.reason;render();return false;}
  return true;
 }
 function start(){
  if(phase!=='ready'&&phase!=='saved')return;
  if(ctx.audioReady?.()===false){error='Reconnect audio before recording.';ctx.notice(error);render();return;}
  if(!mediaReady()){error='Connect the selected USB drive before recording.';render();return;}
  ctx.beforeStart?.();error='';const s=clone(state()),session=ctx.session();
  const result=model.create({id:'performance-'+s.nextId,name:session.name+' — Take '+s.nextId+'.wav',sessionId:session.id,sessionName:session.name,startedAt:now(),output:'Main output',storage:clone(target()),captureTap:s.followOutput?'after-final-controls':'before-final-controls'},ctx.recordingFormat()),a=result.take;
  const remaining=a?model.remaining(a,capacity()):null;
  if(result.error||remaining===null||remaining<=0){error=result.error||(remaining===null?'Remaining time is unavailable. Check storage before recording.':'Storage reserve reached. Free space before recording.');ctx.notice(error);render();return;}
  s.nextId++;s.active=a;
  if(!write(s)){error='Recording could not start. Check storage and try again.';ctx.notice(error);render();return;}
  pending=a;lastCheckpoint=0;phase='recording';warning=remaining<=60;render();
 }
 function finalize(recovered=false){
  if(!['recording','recovered'].includes(phase))return;
  if(!mediaReady()){error='Reconnect '+targetName()+' to save this take.';render();return;}
  if(phase==='recording'&&!checkpoint())return;
  if(!model.valid(pending)||pending.frames<=0){error='No recorded audio is available yet.';render();return;}
  error='';phase='saving';render();clearTimeout(job);
  job=setTimeout(()=>{
   job=null;if(!mediaReady()){phase='recovered';error='Reconnect '+targetName()+' to save this take.';render();return;}const asset=model.asset(pending,recovered);
   const next=clone(state());next.active=null;next.last=clone(asset);
   if(!write(next,asset)){phase='recovered';error='Could not save the recording. It is kept here for another try.';render();return;}
   last=asset;pending=null;phase='saved';warning=false;render();ctx.notice('Performance saved to '+(asset.storage?.location==='usb'?'USB':'Internal')+' / Performances.');
  },750);
 }
 function tick(){
  if(phase==='recording'){
   const remaining=estimate();
   if(remaining===null||remaining<=0||seconds()-lastCheckpoint>=5)checkpoint();
   const low=phase==='recording'&&remaining!==null&&remaining<=60;
   if(low!==warning){warning=low;render();}
  }
  for(const el of document.querySelectorAll('[data-performance-time]'))el.textContent=time(seconds());
  for(const el of document.querySelectorAll('[data-performance-remaining]')){const value=estimate();el.textContent=value===null?'Remaining time unavailable':time(value)+' remaining';}
 }
 function toggle(){if(phase==='recording')finalize();else if(phase==='recovered')finalize(true);else if(phase!=='saving')start();}
 function action(id){
  if(!id?.startsWith('recorder:'))return false;
  if(id==='recorder:open'){ctx.open();render();}
  else if(id==='recorder:destination:internal')selectSetting('destination','internal');
  else if(id==='recorder:destination:usb')selectSetting('destination','usb');
  else if(id==='recorder:follow-output')selectSetting('followOutput',!state().followOutput);
  else if(id==='recorder:start')start();
  else if(id==='recorder:stop')finalize();
  else if(id==='recorder:save-recovered')finalize(true);
  else if(id==='recorder:view')ctx.reveal(last.id,last.storage?.location||'internal');
  else if(id==='recorder:again'&&phase==='saved'){phase='ready';error='';render();}
  else if(id==='recorder:discard'&&phase==='recovered'){discard=true;render();ctx.focus('recorder:cancel-discard');}
  else if(id==='recorder:cancel-discard'){discard=false;render();ctx.focus('recorder:discard');}
  else if(id==='recorder:confirm-discard'&&discard){if(!mediaReady()){discard=false;error='Reconnect '+targetName()+' to discard its saved parts.';render();return true;}const next=clone(state());next.active=null;if(!write(next,undefined,0,pending.bytes)){error='Could not discard this recording. Try again.';discard=false;render();return true;}pending=null;phase='ready';discard=false;error='';render();}
  return true;
 }
 function body(){
  const recording=phase==='recording',recovered=phase==='recovered',saving=phase==='saving',saved=phase==='saved',remaining=estimate(),format=pending?.format||model.format(ctx.recordingFormat()),parts=saved?last.parts:pending?.parts;
  return header('Record performance','')+`<section class="performance-recorder"><div class="recorder-display ${recording?'recording':recovered?'recovered':''}"><div class="recorder-status"><span class="recorder-mark"></span><span>${recording?'Recording':recovered?'Recording interrupted':saving?'Saving recording':saved?'Recording saved':'Ready to record'}</span></div><div class="recorder-clock" ${saved?'':'data-performance-time'}>${time(saved?last.seconds:seconds())}</div><div class="recorder-source">${saved?esc(last.name):esc(pending?.sessionName||ctx.session().name)}</div><div class="recorder-capacity"><strong data-performance-remaining>${remaining===null?'Remaining time unavailable':time(remaining)+' remaining'}</strong><span>${format?format.sampleRate/1000+' kHz · '+format.channels+' channels · '+format.bitDepth+'-bit PCM':'Recording format unavailable'}</span></div></div><div class="recorder-details">${settingsBody()}${!busy()?button('sound-example:open','Hear an example','quiet'):''}<div class="recorder-routing"><span>Main output</span><p>Live inputs, loops, effects and backing audio routed here.</p></div>${parts?.length?`<div class="recorder-parts"><strong>${parts.length} ${parts.length===1?'file part':'file parts'} · One take</strong><p>Playback and export use these parts in order.</p><ol>${parts.slice(-3).map(part=>`<li>${part.index}. ${time(part.seconds)}</li>`).join('')}</ol></div>`:''}${warning?'<p class="recorder-low" role="status">Storage is nearly full. Recording stops before reserved space is used.</p>':''}${recovered?'<p class="recorder-note">The saved checkpoint can be recovered. Audio after it may be unavailable.</p>':''}${error?`<p class="recorder-error" role="alert">${esc(error)}</p>`:''}<div class="recorder-actions">${recording?button('recorder:stop','Stop recording','recorder-stop'):recovered?button('recorder:save-recovered','Save recovered audio','primary',pending.seconds>0?'':'disabled')+button('recorder:discard','Discard recording'):saved?button('recorder:view','View recording','primary')+button('recorder:again','Record another'):saving?'<span class="recorder-note" role="status">Finishing the recording…</span>':button('recorder:start','Start recording','recorder-start',remaining===null||remaining<=0?'disabled':'')}</div></div></section>`;
 }
 function settingsBody(){
  const frozen=busy()||phase==='saved',storage=phase==='saved'?last.storage:target(),where=storage?.location||state().destination||'internal',follow=phase==='saved'?last.performance?.captureTap==='after-final-controls':pending?pending.captureTap==='after-final-controls':!!state().followOutput;
  return `<section class="recorder-settings"><div><h2>Save to</h2>${frozen?`<strong>${where==='usb'?esc(storage?.label||'USB drive'):'Internal'}</strong>`:`<div class="audio-locations">${['internal','usb'].map(key=>button('recorder:destination:'+key,key==='usb'?'USB drive':'Internal','quiet '+(where===key?'selected':''),'aria-pressed="'+(where===key)+'"')).join('')}</div>`}</div><div class="recorder-output-choice"><div><h2>Follow output volume</h2><p>${follow?'Output volume and mute affect this recording.':'Listening volume and mute leave this recording unchanged.'}</p></div>${frozen?`<strong>${follow?'On':'Off'}</strong>`:button('recorder:follow-output',follow?'On':'Off','quiet '+(follow?'selected':''),'aria-pressed="'+follow+'"')}</div>${where==='usb'&&!mediaReady()&&phase!=='saved'?'<p class="recorder-error">Reconnect '+esc(storage?.label||'the USB drive')+'. Saved parts stay on that drive.</p>':''}</section>`;
 }
 function mediaChanged(){
  if(target().location!=='usb')return;
  if(phase==='recording'||phase==='saving'){
   clearTimeout(job);job=null;pending=clone(state().active);phase='recovered';warning=false;
   error='USB recording stopped. Reconnect '+targetName()+' to save the recorded parts. Your loops keep playing.';
  }
  render();
 }
 function badge(){return busy()?button('recorder:open',`<span class="recorder-mark"></span><span>${phase==='recording'?'<span data-performance-time>'+time(seconds())+'</span>':phase==='saving'?'Saving recording':'Recording interrupted'}</span>`,'recorder-badge '+phase,'aria-label="'+(phase==='recording'?'Performance recording in progress':phase==='saving'?'Saving performance recording':'Performance recording interrupted')+'"'):'';}
 function overlay(){return discard?`<div class="overlay"><section class="dialog" role="dialog" aria-modal="true"><h2>Discard this recording?</h2><p>The recovered recording will be removed.</p><div class="actions">${button('recorder:cancel-discard','Cancel')}${button('recorder:confirm-discard','Discard recording','primary')}</div></section></div>`:'';}
 function review(name){
  if(name==='performance-recording-ready'||name.endsWith('-unknown'))return;
  start();if(!pending)return;
  pending.startedAt-=name.endsWith('-long')?8*3600*1000:83000;checkpoint();
  if(name.endsWith('-recovered'))phase='recovered';
  else if(name.endsWith('-error')){phase='recovered';error='Could not save the recording. It is kept here for another try.';}
  else if(name.endsWith('-saved')){const asset=model.asset(pending),next=clone(state());next.active=null;next.last=asset;if(write(next,asset)){last=asset;pending=null;phase='saved';}}
  render();
 }
 function interrupt(message){if(phase!=='recording')return;checkpoint();phase='recovered';error=message;render();}
 return {body,badge,overlay,action,toggle,tick,busy,review,interrupt,mediaChanged,
  recording:()=>phase==='recording',phase:()=>phase,
  initialFocus:()=>phase==='recording'?'recorder:stop':phase==='recovered'?'recorder:save-recovered':phase==='saved'?'recorder:view':'recorder:start',
  back:()=>{if(!discard)return false;discard=false;return true;},
  simulate:v=>{if(v.slow!==undefined)slow=v.slow;if(v.full!==undefined)full=v.full;if(v.failed!==undefined)failed=v.failed;if(v.elapsedSeconds!==undefined&&phase==='recording')pending.startedAt=now()-v.elapsedSeconds*1000;if(v.interrupt&&phase==='recording'){pending=clone(state().active);phase='recovered';error='';render();}},
  snapshot:()=>clone({destination:target(),mediaReady:mediaReady(),phase,seconds:seconds(),remainingSeconds:estimate(),pending,last,lastCheckpoint,error,discard,warning,state:state()})};
};
