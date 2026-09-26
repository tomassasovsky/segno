// Wi-Fi UX simulation. No browser networking or real credentials are used.
window.createNetworkStudy=ctx=>{
 const {button,header,escape:esc}=ctx,copy=v=>JSON.parse(JSON.stringify(v));
 const networks=[{id:'studio',name:'The Studio',secure:true,signal:3},{id:'rehearsal',name:'Rehearsal Room',secure:true,signal:3},{id:'guest',name:'Guest Wi-Fi',secure:false,signal:2},{id:'venue',name:'Venue backstage',secure:true,signal:2},{id:'long',name:'Rehearsal building — upstairs control room',secure:true,signal:2},{id:'phone',name:'Phone hotspot',secure:true,signal:1},{id:'lounge',name:'Lounge',secure:true,signal:1}];
 const initial=()=>({enabled:true,preferred:'studio',profiles:[{id:'studio',auto:true}]});
 let config=copy(ctx.read()||initial()),connected=config.enabled?config.preferred:null,phase=connected?'connected':'idle',selected=null,editor=false,password='',visible=false,keys='lower',error='',lost=null,job=null,timer=null,scanning=false,scanTimer=null,scroll=0,outcome='success',online=true,internet=true;
 if(!config.profiles.some(p=>p.id===connected))connected=null;
 const address=()=>connected?'192.168.1.'+(42+networks.findIndex(n=>n.id===connected)):null;
 const network=id=>networks.find(n=>n.id===id),profile=id=>config.profiles.find(p=>p.id===id);
 const wifi=(size=32,signal=3)=>`<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path opacity="${signal>=3?1:.2}" d="M2 8.8a15 15 0 0 1 20 0"/><path opacity="${signal>=2?1:.2}" d="M5.5 12.4a9.8 9.8 0 0 1 13 0"/><path d="M9 16a4.5 4.5 0 0 1 6 0 M12 20h.01"/></svg>`;
 const lock=()=>'<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M7 10V7a5 5 0 0 1 10 0v3 M5 10h14v11H5z M12 14v3"/></svg>';
 function show(focus){if(ctx.active()){ctx.render();if(focus)ctx.focus(focus);}}
 function write(next){if(ctx.write(copy(next))===false){error='Could not save Wi-Fi settings. Try again.';show();return false;}config=next;return true;}
 function close(){selected=null;editor=false;password='';visible=false;error='';}
 function cancelJob(){clearTimeout(timer);timer=null;job=null;phase=connected?'connected':lost?'lost':'idle';}
 function join(id){
  const n=network(id);if(!config.enabled||!n||job||(!profile(id)&&n.secure&&password.length<8))return;
  error='';phase='connecting';job={id};const result=outcome;outcome='success';show('wifi:cancel');
  timer=setTimeout(()=>{
   if(!job||job.id!==id)return;timer=null;job=null;
   if(!online||result==='unavailable'){phase=connected?'connected':lost?'lost':'idle';error='Network unavailable. Move closer or try again.';show('wifi:connect');return;}
   if(result==='password'&&n.secure){phase=connected?'connected':'idle';editor=true;error='Incorrect password. Try again.';show('wifi:password');return;}
   const next=copy(config);if(!profile(id))next.profiles.push({id,auto:true});next.preferred=id;
   if(!write(next)){phase=connected?'connected':'idle';show('wifi:connect');return;}
   connected=id;lost=null;phase='connected';close();show('wifi:network:'+id);
  },1400);
 }
 function scan(){if(!config.enabled||scanning)return;scanning=true;show('wifi:scan');scanTimer=setTimeout(()=>{scanning=false;scanTimer=null;show();},1000);}
 function action(id){if(!id.startsWith('wifi:'))return false;
  if(id==='wifi:open'){close();ctx.open();return true;}
  if(id==='wifi:radio'){
   const next={...copy(config),enabled:!config.enabled};if(write(next)){cancelJob();close();connected=null;lost=null;phase='idle';clearTimeout(scanTimer);scanning=false;if(config.enabled){scan();if(config.preferred&&profile(config.preferred)?.auto){selected=config.preferred;join(selected);}}}show('wifi:radio');
  }else if(id==='wifi:scan')scan();
  else if(id.startsWith('wifi:network:')&&config.enabled&&!job){selected=id.slice(13);if(network(selected)){editor=network(selected).secure&&!profile(selected);password='';visible=false;error='';keys='lower';show(editor?'wifi:key:113':'wifi:connect');}}
  else if(id==='wifi:connect')join(selected);
  else if(id==='wifi:reconnect'){selected=lost;editor=false;join(lost);}
  else if(id==='wifi:cancel'){cancelJob();close();show('wifi:scan');}
  else if(id==='wifi:close'){close();show('wifi:scan');}
  else if(id==='wifi:disconnect'&&selected===connected){connected=null;phase='idle';close();show('wifi:scan');}
  else if(id==='wifi:forget'&&profile(selected)){const next=copy(config);next.profiles=next.profiles.filter(p=>p.id!==selected);if(next.preferred===selected)next.preferred=null;if(write(next)){if(connected===selected){connected=null;phase='idle';}if(lost===selected)lost=null;close();show('wifi:scan');}}
  else if(id==='wifi:auto'&&profile(selected)){const next=copy(config);next.profiles.find(p=>p.id===selected).auto=!profile(selected).auto;if(write(next))show(id);}
  else if(id==='wifi:edit-password'){editor=true;password='';visible=false;error='';show('wifi:key:113');}
  else if(editor&&!job){
   if(id==='wifi:visible')visible=!visible;
   else if(id==='wifi:keys')keys=keys==='symbols'?'lower':'symbols';
   else if(id==='wifi:shift')keys=keys==='upper'?'lower':'upper';
   else if(id==='wifi:delete')password=password.slice(0,-1);
   else if(id.startsWith('wifi:key:')&&password.length<63)password+=String.fromCharCode(+id.slice(9));
   show(id);
  }
  return true;
 }
 function body(){
  const n=network(connected),pending=network(job?.id),title=!config.enabled?'Wi-Fi is off':pending?'Connecting…':n?n.name:lost?'Connection lost':'Choose a network';
  const detail=!config.enabled?'Turn on to find nearby networks.':pending?pending.name:n?internet?'Connected':'Connected · No internet':lost?network(lost).name:'Saved networks reconnect automatically.';
  const sorted=networks.filter(n=>n.id!==connected).sort((a,b)=>(b.id===connected?2:profile(b.id)?1:0)-(a.id===connected?2:profile(a.id)?1:0));
  return header('Wi-Fi','',button('wifi:radio',`<span>Wi-Fi</span><span class="wifi-switch ${config.enabled?'on':''}"><span></span></span>`,'wifi-radio',`aria-label="Wi-Fi ${config.enabled?'on':'off'}" aria-pressed="${config.enabled}"`))+`<div class="wifi-workspace"><section class="wifi-connection ${n?'connected':''}"><div class="wifi-large-icon">${wifi(44,n?.signal||3)}</div><div class="wifi-connection-copy"><h2>${esc(title)}</h2><p>${esc(detail)}${n?`<span class="wifi-ip">IP ${address()}</span>`:''}</p></div>${job?'<div class="wifi-progress"></div>':lost&&config.enabled?button('wifi:reconnect','Reconnect','primary'):n?button('wifi:network:'+n.id,'Manage','quiet'):''}${error&&!selected?`<p class="wifi-error" role="alert">${esc(error)}</p>`:''}</section><section class="wifi-browser"><div class="wifi-list-heading"><h2>Networks</h2>${button('wifi:scan',scanning?'Scanning…':'Scan','quiet',!config.enabled||scanning||job?'disabled':'')}</div><div class="wifi-network-list">${!config.enabled?'<div class="wifi-empty">No networks while Wi-Fi is off.</div>':sorted.map(n=>button('wifi:network:'+n.id,`<span class="wifi-signal">${wifi(36,n.signal)}</span><span class="wifi-row-name">${esc(n.name)}${n.id===connected?'<small>Connected</small>':profile(n.id)?'<small>Saved</small>':''}</span><span class="wifi-row-security">${n.secure?lock():''}</span><span class="wifi-row-arrow">${ctx.icon('forward')}</span>`,'wifi-network '+(n.id===connected?'current':''),`aria-label="${esc(n.name)}${n.id===connected?', connected':profile(n.id)?', saved':''}" ${job?'disabled':''}`)).join('')}</div></section></div>`;
 }
 function overlay(){
  const n=network(selected);if(!n)return '';
  const p=profile(n.id),pending=job?.id===n.id;
  if(pending)return `<div class="overlay"><section class="dialog wifi-dialog" role="dialog" aria-modal="true" aria-label="Connecting"><h2>Connecting to ${esc(n.name)}</h2><div class="wifi-progress"></div><p>${connected?'Your current connection stays available until this one is ready.':'Checking the connection.'}</p><div class="actions">${button('wifi:cancel','Cancel','quiet')}</div></section></div>`;
  if(editor){
   const rows=keys==='symbols'?['1234567890','!@#$%^&*()','-_=+[]{}',';:,.?/\\','\"\'`~<>|']:(keys==='upper'?['QWERTYUIOP','ASDFGHJKL','ZXCVBNM']:['qwertyuiop','asdfghjkl','zxcvbnm']);
   return `<div class="overlay"><section class="dialog wifi-password-dialog" role="dialog" aria-modal="true" aria-label="Wi-Fi password"><h2>${esc(n.name)}</h2><div class="wifi-password-label">Password</div><div class="wifi-password-row">${button('wifi:password',password?esc(visible?password:'•'.repeat(password.length)):'Enter password','wifi-password-value',`aria-label="Password, ${password.length} characters"`)}${button('wifi:visible',visible?'Hide':'Show','quiet')}</div><div class="wifi-password-message ${error?'wifi-error':''}" role="status">${esc(error||'')}</div><div class="wifi-keyboard">${rows.map(row=>`<div>${[...row].map(ch=>button('wifi:key:'+ch.charCodeAt(0),esc(ch),'wifi-key')).join('')}</div>`).join('')}<div>${button('wifi:shift',keys==='upper'?'Lowercase':'Shift','wifi-key wifi-key-wide',keys==='symbols'?'disabled':'')}${button('wifi:keys',keys==='symbols'?'ABC':'123 / #','wifi-key wifi-key-wide')}${button('wifi:key:32','Space','wifi-key wifi-space')}${button('wifi:delete','Delete','wifi-key wifi-key-wide')}</div></div><div class="actions">${button('wifi:close','Cancel','quiet')}${button('wifi:connect','Connect','primary',password.length<8?'disabled':'')}</div></section></div>`;
  }
  return `<div class="overlay"><section class="dialog wifi-dialog wifi-details" role="dialog" aria-modal="true" aria-label="Network details"><div class="wifi-dialog-heading"><div><h2>${esc(n.name)}</h2><p>${n.id===connected?(internet?'Connected':'Connected · No internet'):p?'Saved network':n.secure?'Password required':'Open network'}${n.id===connected?`<span class="wifi-ip">IP ${address()}</span>`:''}</p></div>${button('wifi:close',ctx.icon('close'),'wifi-close','aria-label="Close network details"')}</div>${p?`<div class="wifi-detail-rows"><div class="wifi-detail-row"><span>Connect automatically</span>${button('wifi:auto',`<span class="wifi-switch ${p.auto?'on':''}"><span></span></span>`,'wifi-toggle-control',`aria-label="Connect automatically ${p.auto?'on':'off'}" aria-pressed="${p.auto}"`)}</div>${n.secure?button('wifi:edit-password',`<span>Change password</span>${ctx.icon('right')}`,'wifi-detail-row wifi-detail-link'):''}</div>`:''}${error?`<p class="wifi-error" role="alert">${esc(error)}</p>`:''}<div class="wifi-detail-footer">${p?button('wifi:forget','Forget network','wifi-forget'):''}${button(n.id===connected?'wifi:disconnect':'wifi:connect',n.id===connected?'Disconnect':'Connect',n.id===connected?'quiet':'primary')}</div></section></div>`;
 }
 function key(e){if(!ctx.active()||!editor||job)return false;if(e.key==='Backspace'){password=password.slice(0,-1);show('wifi:password');return true;}if(e.key.length===1&&!e.metaKey&&!e.ctrlKey&&!e.altKey){if(password.length<63)password+=e.key;show('wifi:password');return true;}return false;}
 function simulate(v){
  if(v.outcome)outcome=v.outcome;
  if(v.internet!==undefined)internet=!!v.internet;
  if(v.online!==undefined)online=!!v.online;
  if(v.drop&&connected){lost=connected;connected=null;phase='lost';if(profile(lost)?.auto&&config.enabled){selected=lost;join(lost);}}
  if(v.connected){cancelJob();connected=v.connected;lost=null;phase='connected';}
  show();
 }
 function fixture(scene){
  close();cancelJob();config=initial();connected='studio';lost=null;phase='connected';online=true;internet=true;
  if(scene==='network-password'||scene==='network-error'||scene==='network-joining'){selected='rehearsal';editor=true;if(scene==='network-error')error='Incorrect password. Try again.';if(scene==='network-joining'){password='testonly';join(selected);}}
  if(scene==='network-details')selected='studio';
  if(scene==='network-lost'){connected=null;lost='studio';phase='lost';online=false;}
  if(scene==='network-off'){config.enabled=false;connected=null;phase='idle';}
  if(scene==='network-no-internet')internet=false;
 }
 return {action,body,overlay,key,simulate,fixture,initial,leave:()=>{cancelJob();close();},back:()=>{if(selected||job){cancelJob();close();show('wifi:scan');return true;}return false;},
  initialFocus:()=>editor?'wifi:key:113':'wifi:radio',remember:root=>{const e=root.querySelector('.wifi-network-list');if(e)scroll=e.scrollTop;},restore:root=>{const e=root.querySelector('.wifi-network-list');if(e)e.scrollTop=scroll;},
  snapshot:()=>copy({config,networks,connected,address:address(),phase,selected,editor,passwordLength:password.length,visible,error,lost,job,scanning,internet})};
};
