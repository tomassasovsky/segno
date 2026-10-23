// Connected-interface UX. Devices, health and calibration results are simulated.
window.createAudioDeviceStudy=ctx=>{
 const {button,header,escape:esc,icon}=ctx,clone=v=>JSON.parse(JSON.stringify(v));
 const devices=[{id:'stage',name:'Stage interface',inputs:18,outputs:8,online:true,present:true,rates:[44100,48000,96000],buffers:[64,128,256,512]},{id:'spare',name:'Spare interface',inputs:18,outputs:8,online:false,present:false,rates:[44100,48000,96000],buffers:[64,128,256,512]},{id:'compact',name:'Compact interface',inputs:2,outputs:2,online:false,present:false,rates:[44100,48000],buffers:[128,256,512]}];
 const config=()=>({id:'stage',rate:48000,frames:128,measurement:null,...ctx.read()});
 const current=()=>devices.find(d=>d.id===config().id);
 if(current()){current().online=true;current().present=true;}
 let draft=clone(config()),phase=current()?.online?'ready':'missing',confirm=false,picker=false,error='',failOpen=false,reconnected=false,dropouts=0;
 let calibration=null,calibrationTimer=null,noReturn=false,portChoice=null,automaticAvailable=false;
 const candidate=()=>devices.find(d=>d.id===draft.id);
 const ready=()=>phase==='ready'&&!!current()?.online;
 const busy=()=>ctx.capturing();
 const dirty=()=>['id','rate','frames'].some(k=>draft[k]!==config()[k]);
 const khz=v=>v/1000+' kHz';
 function unavailable(d){if(!d?.online)return 'Not connected';const n=ctx.channels();return d.inputs<n.inputs||d.outputs<n.outputs?`This setup needs ${n.inputs} inputs and ${n.outputs} outputs.`:'';}
 function show(focus){ctx.render();if(focus)ctx.focus(focus);}
 function resetDraft(){draft=clone(config());confirm=false;picker=false;error='';}
 function cancelCalibration(){clearTimeout(calibrationTimer);calibrationTimer=null;calibration=null;portChoice=null;}
 function apply(){
  const d=candidate();if(busy()||unavailable(d)||calibration?.phase==='measuring'){show();return;}
  if(failOpen){failOpen=false;error='Could not apply these settings. Your previous setup is kept.';show();return;}
  const wasReady=ready(),next={...draft,measurement:dirty()?null:config().measurement};
  if(ctx.write(next)===false){error='Could not save the audio settings. Your previous setup is kept.';show();return;}
  ctx.stop();draft=clone(next);phase='ready';confirm=false;error='';reconnected=!wasReady;show('device:rate:'+draft.rate);
 }
 function beginAutomatic(){
  calibration={phase:'automatic',input:1,output:1,automatic:true};show('device:calibrate-cancel');
  calibrationTimer=setTimeout(()=>{
   calibrationTimer=null;if(!calibration||!ready())return;
   if(!automaticAvailable){calibration.phase='setup';calibration.automatic=false;show('device:calibrate-cancel');return;}
   if(busy()){calibration.phase='blocked';show('device:calibrate-cancel');return;}
   if(ctx.playing()){calibration.phase='confirm-auto';show('device:calibrate-cancel');return;}
   startCalibration();
  },1200);
 }
 function startCalibration(){
  if(!calibration||busy()||!ready()||dirty())return;
  ctx.stop();calibration.phase='measuring';error='';show('device:calibrate-cancel');
  calibrationTimer=setTimeout(()=>{
   calibrationTimer=null;if(!calibration||!ready())return;
   if(noReturn){calibration.phase=calibration.automatic?'setup':'failed';calibration.automatic=false;show('device:calibrate-start');return;}
   const c=config(),ms=+(c.frames*2000/c.rate+2.1).toFixed(2),measurement={rate:c.rate,frames:c.frames,milliseconds:ms,input:calibration.input,output:calibration.output};
   // This is a simulation fixture, not a real measurement or latency estimate.
   if(ctx.write({...c,measurement})===false){calibration.phase='failed';error='Could not save the measurement. Try again.';}else{draft=clone(config());calibration.phase='done';}
   show(calibration.phase==='done'?'device:calibrate-close':'device:calibrate-start');
  },1800);
 }
 function action(id){if(!id.startsWith('device:'))return false;const value=id.slice(id.lastIndexOf(':')+1);
  if(id==='device:open'){cancelCalibration();resetDraft();ctx.open();return true;}
  if(id==='device:port-cancel'){portChoice=null;show('device:calibrate-cancel');}
  else if(id==='device:choose'){picker=true;show('device:pick:'+draft.id);}
  else if(id==='device:choose-close'){picker=false;show('device:choose');}
  else if(id.startsWith('device:pick:')&&devices.some(d=>d.id===value&&d.present)){
   draft.id=value;const d=candidate();if(!d.rates.includes(draft.rate))draft.rate=d.rates[0];if(!d.buffers.includes(draft.frames))draft.frames=d.buffers[0];picker=false;confirm=false;error='';show('device:choose');
  }
  else if(id.startsWith('device:rate:')&&candidate().rates.includes(+value)){draft.rate=+value;error='';show(id);}
  else if(id.startsWith('device:buffer:')&&candidate().buffers.includes(+value)){draft.frames=+value;error='';show(id);}
  else if(id==='device:reset'){resetDraft();show('device:rate:'+draft.rate);}
  else if(id==='device:apply'){if(!busy()&&!unavailable(candidate())){if(ready()&&!dirty())return true;if(ctx.playing()){confirm=true;show('device:cancel');}else apply();}}
  else if(id==='device:confirm')apply();
  else if(id==='device:cancel'){confirm=false;error='';show('device:apply');}
  else if(id==='device:calibrate'&&ready()&&!busy()&&!dirty()){beginAutomatic();}
  else if(id==='device:calibrate-start'||id==='device:calibrate-confirm')startCalibration();
  else if(id.startsWith('device:port:')&&calibration&&calibration.phase!=='measuring'){portChoice=value;show('device:test-'+value+':'+calibration[value]);}
  else if(id==='device:calibrate-close'||id==='device:calibrate-cancel'){cancelCalibration();error='';show('device:calibrate');}
  else if(id.startsWith('device:test-input:')&&calibration&&calibration.phase!=='measuring'){calibration.input=+value;portChoice=null;show('device:port:input');}
  else if(id.startsWith('device:test-output:')&&calibration&&calibration.phase!=='measuring'){calibration.output=+value;portChoice=null;show('device:port:output');}
  return true;
 }
 function body(){const d=candidate(),active=config().id===draft.id,blocked=unavailable(d),status=active?(ready()?'Connected':d?.online?'Ready to reconnect':'Disconnected'):'Not applied',m=config().measurement;
  return header('Audio device','')+`<div class="audio-device-workspace"><div class="device-connected"><div><h2>${esc(d?.name||'Saved interface')}</h2><span>${d?.inputs??'—'} inputs · ${d?.outputs??'—'} outputs</span></div><div class="device-status ${ready()&&active?'ready':''}"><span aria-hidden="true"></span>${status}</div>${button('device:choose','Change interface','quiet')}</div>
   <div class="device-controls"><section class="device-engine"><h3>Sample rate</h3><div class="device-rate-options">${d.rates.map(rate=>button('device:rate:'+rate,khz(rate),draft.rate===rate?'selected':'',`aria-pressed="${draft.rate===rate}"`)).join('')}</div>
   <h3 class="device-buffer-title">Buffer size <span>samples</span></h3><div class="device-buffer-options">${d.buffers.map(frames=>button('device:buffer:'+frames,String(frames),draft.frames===frames?'selected':'',`aria-pressed="${draft.frames===frames}"`)).join('')}</div><div class="device-buffer-scale"><span>Lower latency</span><span>More headroom</span></div><div class="device-period"><strong>${(draft.frames*1000/draft.rate).toFixed(2)} <small>ms</small></strong><span>per buffer</span></div>
   </section><section class="device-latency"><div class="device-latency-heading"><h3>Round-trip latency</h3>${button('device:calibrate','Measure','quiet',!ready()||busy()||dirty()?'disabled':'')}</div><div class="device-latency-value">${m?m.milliseconds.toFixed(2)+' <small>ms</small>':'<span>Not measured</span>'}</div><p class="device-latency-note">${dirty()?'Apply audio settings before measuring.':m?'Recording timing compensated.':'Measure to align new recordings.'}</p><div class="device-health"><div><span>Audio dropouts</span><strong>${ready()?dropouts:'—'}</strong></div><div><span>Audio engine</span><strong>${ready()?'Running':'Offline'}</strong></div></div></section></div>
   <div class="device-apply-row"><div class="device-outcome" role="status">${esc(error||blocked||(busy()?'Finish recording before changing audio settings.':!ready()?'Reconnect audio when you are ready. Loops stay stopped.':dirty()?'Changes apply together. Your recordings stay intact.':reconnected?'Audio is ready. Loops remain stopped.':''))}</div><div class="device-apply">${dirty()?button('device:reset','Cancel','quiet'):''}${dirty()||!ready()?button('device:apply',!ready()&&active?'Reconnect audio':'Apply','primary',busy()||blocked?'disabled':''):''}</div></div></div>`;
 }
 function overlay(){
  if(picker)return `<div class="overlay"><section class="dialog device-picker" role="dialog" aria-modal="true" aria-label="Change interface"><h2>Audio interface</h2><div class="audio-device-list">${devices.filter(d=>d.present).map(d=>button('device:pick:'+d.id,`<span><strong>${esc(d.name)}</strong><small>${d.online?d.inputs+' inputs · '+d.outputs+' outputs':'Not connected'}</small></span><span>${draft.id===d.id?icon('check'):''}</span>`,'device-choice '+(draft.id===d.id?'selected':''),`aria-pressed="${draft.id===d.id}"`)).join('')}</div><div class="actions">${button('device:choose-close','Done')}</div></section></div>`;
  if(confirm)return `<div class="overlay"><section class="dialog" role="dialog" aria-modal="true" aria-label="Change audio settings"><h2>Apply audio settings?</h2><p>${esc(error||unavailable(candidate())||(busy()?'Finish recording before changing audio settings.':'Loops and backing audio will stop. Your recordings stay intact.'))}</p><div class="actions">${button('device:cancel','Cancel')}${button('device:confirm','Stop audio and apply','primary',busy()||unavailable(candidate())?'disabled':'')}</div></section></div>`;
  if(!calibration)return '';
  if(portChoice){const count=portChoice==='input'?current().inputs:current().outputs;return `<div class="overlay"><section class="dialog device-calibration" role="dialog" aria-modal="true" aria-label="Choose test ${portChoice}"><h2>${portChoice==='input'?'Input':'Output'} jack</h2><div class="device-port-grid">${Array.from({length:count},(_,i)=>button('device:test-'+portChoice+':'+(i+1),String(i+1),calibration[portChoice]===i+1?'selected':'')).join('')}</div><div class="actions">${button('device:port-cancel','Cancel')}</div></section></div>`;}
  const c=calibration,measuring=c.phase==='measuring',done=c.phase==='done',failed=c.phase==='failed';
  if(c.phase==='automatic'||measuring&&c.automatic)return `<div class="overlay"><section class="dialog device-calibration" role="dialog" aria-modal="true" aria-label="Automatic latency measurement"><h2>Measure latency</h2><p>${measuring?'Measuring automatically…':'Trying automatic measurement…'}</p><div class="device-test-progress"></div><div class="actions">${button('device:calibrate-cancel','Cancel')}</div></section></div>`;
  if(c.phase==='confirm-auto'||c.phase==='blocked')return `<div class="overlay"><section class="dialog" role="dialog" aria-modal="true" aria-label="Automatic latency measurement"><h2>Automatic measurement ready</h2><p>${busy()?'Finish recording before measuring latency.':'Playback will stop for the test.'}</p><div class="actions">${button('device:calibrate-cancel','Cancel')}${button('device:calibrate-confirm','Stop audio and measure','primary',busy()?'disabled':'')}</div></section></div>`;
  return `<div class="overlay"><section class="dialog device-calibration" role="dialog" aria-modal="true" aria-label="Measure latency"><h2>Measure latency</h2>${done?`<div class="device-test-result">${config().measurement.milliseconds.toFixed(2)} <small>ms</small></div><p>Recording timing compensated.</p>`:`<p>${measuring?'Measuring… Live monitoring is muted.':failed?esc(error||'No return signal. Check the cable and selected jacks.'):'Automatic measurement unavailable. Connect a spare output to an input with an audio cable.'}</p><div class="device-test-cable"><label>Output${button('device:port:output',String(c.output),'device-port-number',measuring?'disabled':'')}</label><span aria-hidden="true"></span><label>Input${button('device:port:input',String(c.input),'device-port-number',measuring?'disabled':'')}</label></div>${measuring?'<div class="device-test-progress"></div>':'<p class="device-test-note">The test stops playback and sends a pulse through the selected output.</p>'}`}<div class="actions">${button(done?'device:calibrate-close':'device:calibrate-cancel',done?'Done':'Cancel')}${!done&&!measuring?button('device:calibrate-start',failed?'Try again':'Start test','primary',!ready()||busy()?'disabled':''):''}</div></section></div>`;
 }
 function simulate(change){
  if(change.failOpen!==undefined)failOpen=change.failOpen;
  if(change.noReturn!==undefined)noReturn=change.noReturn;
  if(change.automaticAvailable!==undefined)automaticAvailable=change.automaticAvailable;
  if(change.dropouts!==undefined)dropouts=change.dropouts;
  if(change.showAlternatives){for(const d of devices){d.present=true;d.online=true;}}
  if(change.id&&typeof change.online==='boolean'){
   const d=devices.find(d=>d.id===change.id);if(!d)return;const wasReady=ready();d.online=change.online;d.present=true;
   if(d.id===config().id&&!d.online){phase='missing';reconnected=false;error='';cancelCalibration();if(wasReady)ctx.stop(true);}
  }
  show();
 }
 function badge(){return ready()?'':button('device:open',current()?.online?'Reconnect audio':'Audio disconnected','device-alert','aria-label="'+(current()?.online?'Reconnect audio':'Audio disconnected: open audio interface')+'"');}
 function back(){if(portChoice){portChoice=null;show('device:calibrate-cancel');return true;}if(calibration){cancelCalibration();show('device:calibrate');return true;}if(picker){picker=false;show('device:choose');return true;}if(confirm){confirm=false;error='';show('device:apply');return true;}return false;}
 return {body,overlay,action,simulate,ready,badge,back,testing:()=>calibration?.phase==='measuring',initialFocus:()=>calibration?calibration.phase==='done'?'device:calibrate-close':'device:calibrate-cancel':confirm?'device:cancel':picker?'device:pick:'+draft.id:'device:rate:'+draft.rate,
  leave:()=>{cancelCalibration();resetDraft();},snapshot:()=>clone({config:config(),devices,selected:draft.id,draft,dirty:dirty(),phase,ready:ready(),confirm,picker,error,reconnected,calibration,dropouts})};
};
