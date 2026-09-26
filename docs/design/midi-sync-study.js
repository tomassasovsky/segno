// UX simulation: MIDI timing messages and output events never reach hardware.
window.createMidiSyncStudy=({read,write,ports,tempo,setTempo,capturing,transport,running,clockReady,clockLost,songPosition,render,focus,button,escape,now=()=>performance.now()})=>{
 const clone=v=>JSON.parse(JSON.stringify(v));
 const settings=()=>({source:'internal',followTransport:false,loss:'keep',outputs:{},thru:false,...read()});
 let state='internal',lastPulse=null,intervals=[],seen=false,intentionalStop=false,notice='',lastTick=now(),sendFraction=0,lastRunning=running(),beat=0,outgoing=[];
 let editing=null;
 const external=()=>settings().source!=='internal';
 const offset=value=>Math.max(-10,Math.min(10,Math.round(Number(value)||0)));
 const offsetValue=id=>editing?.port===id?editing.value:offset(settings().outputs[id]?.offsetMs);
 const offsetLabel=value=>(value>0?'+':'')+value+' ms';
 const sourcePort=()=>ports().find(p=>p.id===settings().source);
 const waiting=()=>external()&&(!seen||state==='lost'&&settings().loss==='stop');
 const statusLabel=()=>({internal:'Internal',waiting:'Waiting',synced:'Synced',lost:'Clock lost'})[state];
 const selected=(id,label,on,disabled=false)=>button('sync:'+id,label,'sync-choice '+(on?'selected':''),`aria-pressed="${on}" ${disabled?'disabled':''}`);
 function emit(kind,count=1,at=now()){const s=settings();for(const p of ports()){const output=s.outputs[p.id];if(!p.online||s.source===p.id||s.thru&&p.id==='din'||!output?.clock||kind!=='clock'&&!output.transport)continue;const offsetMs=kind==='clock'&&!external()?offsetValue(p.id):0;outgoing.push({port:p.id,type:kind,count,nominalAt:at,scheduledAt:at+offsetMs,offsetMs,simulated:true});}outgoing=outgoing.slice(-80);}
 function reset(){state=external()?'waiting':'internal';lastPulse=null;intervals=[];seen=false;intentionalStop=false;notice='';lastTick=now();sendFraction=0;lastRunning=running();beat=0;outgoing=[];editing=null;}
 function change(patch){const previous=settings(),next={...clone(previous),...patch};if(write(next)===false){notice='Could not save. The previous setting is retained.';render();return false;}notice='';return true;}
 function action(id){if(!id.startsWith('sync:'))return false;const [,key,value]=id.split(':'),s=settings();
  if(editing&&id!=='sync:offset:'+editing.port){if(!finish(false))return true;}
  if(key==='source'){if(capturing()||!['internal',...ports().map(p=>p.id)].includes(value))return true;if(change({source:value})){reset();if(value==='internal')clockReady();}}
  if(key==='follow')change({followTransport:value==='true'});
  if(key==='loss'&&['keep','stop'].includes(value)&&change({loss:value})&&state==='lost'&&value==='stop'){transport('stop');lastRunning=running();}
  if(key==='output-clock'||key==='output-transport'){if(value===s.source||s.thru&&value==='din'||!ports().some(p=>p.id===value))return true;const outputs=clone(s.outputs),o=outputs[value]||{clock:false,transport:false};if(key==='output-clock'){o.clock=!o.clock;if(!o.clock)o.transport=false;}else {if(!o.clock)return true;o.transport=!o.transport;}outputs[value]=o;change({outputs});}
  if(key==='thru'&&ports().some(p=>p.id==='din'))change({thru:!s.thru});
  if(key==='offset'&&!external()&&!(s.thru&&value==='din')&&s.outputs[value]?.clock){if(editing)finish();else editing={port:value,value:offsetValue(value)};}
  if(key==='offset-reset')setOffset(value,0);
  render();focus(id,true);return true;
 }
 function setOffset(port,value){if(external()||settings().thru&&port==='din'||!settings().outputs[port]?.clock||!Number.isFinite(Number(value)))return false;const outputs=clone(settings().outputs);outputs[port]={...outputs[port],offsetMs:offset(value)};return change({outputs});}
 function finish(cancel=false){if(!editing)return false;const draft=editing;editing=null;if(!cancel&&!setOffset(draft.port,draft.value)){editing=draft;return false;}render();return true;}
 function turn(delta){if(!editing)return false;editing.value=offset(editing.value+delta);render();focus('sync:offset:'+editing.port,true);return true;}
 function input(id,value,root){const [,kind,port]=id.split(':');if(kind!=='offset')return false;editing=null;if(setOffset(port,value)){const node=root?.querySelector('[data-action="'+id+'"]'),out=root?.querySelector('[data-sync-offset="'+port+'"]');if(node){node.value=offsetValue(port);node.setAttribute('aria-valuetext',offsetLabel(offsetValue(port)));node.style.setProperty('--amount',(offsetValue(port)+10)*5+'%');}if(out)out.textContent=offsetLabel(offsetValue(port));}return true;}
 function receiveMessage(port,message,at=now(),origin='input'){
  if(message?.kind==='song-position'&&origin==='input'&&!message.forwarded&&Number.isFinite(at)&&external()&&settings().source===port&&sourcePort()?.online&&settings().followTransport&&Number.isInteger(message.value)&&message.value>=0&&message.value<=16383)songPosition?.(message.value/4);
  if(!settings().thru||port!=='din'||!ports().find(p=>p.id==='din')?.online||origin!=='input'||message?.forwarded||!Number.isFinite(at))return false;
  const value=typeof message==='string'?{type:message}:message;
  if(!value||typeof value!=='object')return false;
  outgoing.push({port:'din',source:'din',type:value.type||value.kind||'message',message:clone(value),count:1,nominalAt:at,scheduledAt:at,offsetMs:0,forwarded:true,simulated:true});outgoing=outgoing.slice(-80);return true;
 }
 function receive(port,type,at=now()){
  if(['clock','start','continue','stop'].includes(type))receiveMessage(port,{type},at);
  if(!external()||settings().source!==port||!sourcePort()?.online||!['clock','start','continue','stop'].includes(type)||!Number.isFinite(at))return;
  if(type==='clock'){
   if(lastPulse!==null&&at<=lastPulse)return;
   const delta=lastPulse===null?null:at-lastPulse;lastPulse=at;
   if(delta!==null){if(delta>=8&&delta<=100)intervals.push(delta);else intervals=[];intervals=intervals.slice(-12);}
   beat+=1/24;
   if(intervals.length>=6){const sorted=[...intervals].sort((a,b)=>a-b),period=sorted[Math.floor(sorted.length/2)],bpm=Math.round(60000/(24*period)*10)/10;
    if(bpm>=30&&bpm<=300){setTempo(bpm);const becameReady=state!=='synced';state='synced';seen=true;if(becameReady){clockReady();render();}}}
   emit('clock',1,at);
  }else{
   intentionalStop=type==='stop';if(type==='start')beat=0;
   if(settings().followTransport){transport(type);lastRunning=running();}
   emit(type,1,at);render();
  }
 }
 function tick(){const stamp=now(),dt=Math.max(0,stamp-lastTick);lastTick=stamp;
  if(!external()){state='internal';beat+=dt*tempo()/60000;sendFraction+=dt*tempo()/60000*24;const count=Math.floor(sendFraction);if(count){sendFraction-=count;emit('clock',count);}}
  else if((!sourcePort()?.online||lastPulse!==null&&stamp-lastPulse>1000)&&state==='synced'){
   state=intentionalStop?'waiting':'lost';intervals=[];lastPulse=null;
   if(state==='lost'){if(clockLost)clockLost({keepPlaying:settings().loss==='keep'});else if(settings().loss==='stop')transport('stop');lastRunning=running();}
   render();
  }
  const isRunning=running();if(isRunning!==lastRunning){emit(isRunning?'start':'stop');lastRunning=isRunning;}
 }
 function body(){const s=settings(),labels=statusLabel(),held=state==='lost'&&s.loss==='keep',hint=state==='waiting'?(sourcePort()?.online?'Start the clock on your other device.':'Reconnect the selected device.'):state==='lost'?(held?(running()?'Continuing at the last tempo.':'Last tempo retained.'):'Loops stopped. Reconnect, then press Play.'):'',value=external()&&!seen?'—':tempo();
 return `<div class="titlebar"><h1>Clock & sync</h1></div><section class="sync-source-row"><h2>Tempo source</h2><div class="sync-sources">${selected('source:internal','Internal',!external(),capturing())}${ports().map(p=>selected('source:'+p.id,escape(p.name)+(p.online?'':'<small>Disconnected</small>'),s.source===p.id,capturing())).join('')}</div>${capturing()?'<p class="sync-note">Finish recording to change source.</p>':''}</section><div class="sync-middle"><section class="sync-readout ${state}"><div class="sync-tempo"><output data-sync-tempo>${value}</output><span>BPM</span></div><div class="sync-pulse" aria-hidden="true"><span data-sync-pulse></span></div><strong data-sync-status>${labels}</strong>${hint?`<p>${hint}</p>`:''}${state==='lost'?button('sync:source:internal','Use internal tempo','quiet',capturing()?'disabled':''):''}</section><section class="sync-behavior">${external()?`<div class="sync-setting"><h2>Follow Play / Stop</h2><div class="sync-segment">${selected('follow:false','Off',!s.followTransport)}${selected('follow:true','On',s.followTransport)}</div><p>${s.followTransport?'Start restarts loops. Continue resumes them.':'Your pedals control playback.'}</p></div><div class="sync-setting"><h2>If clock is lost</h2><div class="sync-segment">${selected('loss:keep','Keep playing',s.loss==='keep')}${selected('loss:stop','Stop loops',s.loss==='stop')}</div></div>`:`<div class="sync-internal"><h2>Segno sets the tempo</h2><p>Other devices can follow it below.</p>${button('loop:page:loop-timing','Tempo & click','quiet')}</div>`}</section></div><section class="sync-outputs"><h2>Send sync</h2><div class="sync-output-list">${ports().map(p=>{const o=s.outputs[p.id]||{},receiving=s.source===p.id,thru=s.thru&&p.id==='din',blocked=receiving||thru;return `<div class="sync-output"><span><strong>${escape(p.id==='din'?'MIDI Out':p.name)}</strong><small>${thru?'MIDI In → MIDI Out':receiving?'Receiving clock':p.online?p.connection:'Disconnected'}</small></span>${selected('output-clock:'+p.id,'Clock',!!o.clock,blocked)}${selected('output-transport:'+p.id,'Play / Stop',!!o.transport,blocked||!o.clock)}<label class="sync-offset inline-control"><span>Clock offset<output data-sync-offset="${p.id}">${offsetLabel(offsetValue(p.id))}</output></span><input type="range" min="-10" max="10" step="1" value="${offsetValue(p.id)}" data-action="sync:offset:${p.id}" aria-label="${escape(p.name)} clock offset" aria-valuetext="${offsetLabel(offsetValue(p.id))}" style="--amount:${(offsetValue(p.id)+10)*5}%" ${blocked||external()||!o.clock?'disabled':''}></label></div>`;}).join('')}</div><p class="sync-note">${external()?'Received sync keeps its incoming timing. Sender offsets apply with Internal tempo.':'−10 ms earlier · +10 ms later. Offset adjusts sent clock, without changing loop tempo.'}</p></section><section class="sync-thru"><div><h2>MIDI Thru</h2><p>MIDI In → MIDI Out. ${s.thru?'Segno sync on MIDI Out is paused while Thru is on.':'Forward incoming messages without changing them.'}</p></div>${selected('thru',s.thru?'On':'Off',s.thru,!ports().some(p=>p.id==='din'))}</section><p class="sync-simulation">Timing simulation · no MIDI messages are sent to hardware.</p>${notice?`<p class="sync-note" role="alert">${notice}</p>`:''}`;
 }
 function refresh(root){const s=root.querySelector('[data-sync-tempo]');if(s)s.textContent=external()&&!seen?'—':tempo();root.querySelectorAll('[data-sync-pulse]').forEach(e=>e.classList.toggle('lit',(state==='internal'||state==='synced')&&beat%1<.5));const l=root.querySelector('[data-loop-tempo]');if(l&&external()){l.textContent=tempo();const slider=root.querySelector('[data-action="loop:tempo"]');slider.value=tempo();slider.style.setProperty('--amount',(tempo()-30)/270*100+'%');}}
 function review(scene){if(scene==='sync-internal'){change({source:'internal',outputs:{din:{clock:true,transport:true}}});reset();return;}change({source:'usb',followTransport:true,loss:scene==='sync-stop'?'stop':'keep',outputs:{din:{clock:true,transport:true}}});reset();if(scene!=='sync-waiting'){for(let i=8;i>=0;i--)receive('usb','clock',now()-i*60000/(120*24));}if(scene==='sync-lost'||scene==='sync-stop'){lastPulse=now()-1100;tick();}render();}
 reset();return {body,action,receive,receiveMessage,tick,refresh,reset,review,external,waiting,input,turn,finish,resetOffset:id=>{editing=null;setOffset(id.split(':')[2],0);render();},get editingAction(){return editing?'sync:offset:'+editing.port:null;},status:()=>({state,label:statusLabel(),external:external()}),snapshot:()=>clone({settings:settings(),state,label:statusLabel(),seen,tempo:tempo(),beat,outgoing,notice,editing})};
};
