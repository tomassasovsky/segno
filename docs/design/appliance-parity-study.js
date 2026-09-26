// Prototype only: no device reads, firmware writes, USB gadgets or MIDI IO.
(function(root){
 'use strict';
 const copy=v=>JSON.parse(JSON.stringify(v));
 function createControllerModel({read=()=>null,write=()=>true,blocked=()=>'',now=()=>performance.now()}={}){
  let state={connected:false,retryReady:false,target:null,updateSupported:false,installed:null,protocol:null,versionSource:'not-reported',pending:null,phase:'idle',progress:0,attempt:0,failureClass:null,error:'',...copy(read()||{})};
  let started=0,lastEvent=0,highWater=0,interrupted=state.failureClass==='interrupted';
  const busy=()=>state.phase==='flashing';
  function commit(next){if(write(copy(next))===false)return false;state=next;return true;}
  function reason(){return blocked()||(!state.connected?'Reconnect the controller.':state.failureClass==='interrupted'&&!state.retryReady?'Reconnect the controller and confirm its update connection before retrying.':!state.updateSupported?'Controller update support has not been established for this hardware.':!state.pending?'No controller update is pending.':!state.target||state.pending.target!==state.target?'This update does not match the connected controller.':!state.pending.verified?'The bundled controller update could not be verified.':'');}
  function attempt(){state={...state,phase:'flashing',progress:0,attempt:state.attempt+1,error:'',retryReady:false};highWater=0;lastEvent=now();}
  function start(){if(busy()||reason())return false;started=now();state.attempt=0;attempt();return true;}
  function fail(failureClass,message='Controller update could not finish.'){
   if(!busy())return false;
   interrupted ||= highWater>=50||failureClass!=='not-started';
   const classification=interrupted?'interrupted':'not-started';
   if(state.connected&&(classification==='not-started'||state.retryReady)&&state.attempt<3&&now()-started<8*60*1000){state.failureClass=classification;attempt();return true;}
   state={...state,phase:'failed',failureClass:classification,error:message};commit(state);return true;
  }
  function progress(value){if(!busy()||!Number.isFinite(value))return false;state.progress=Math.max(0,Math.min(100,value));highWater=Math.max(highWater,state.progress);lastEvent=now();return true;}
  function complete({running=false,readbackVerified=false,version,protocol}={}){
   if(!busy()||highWater<90||!readbackVerified||!running||!state.connected||version!==state.pending?.version)return false;
   const next={...state,installed:version,protocol:protocol??state.pending.protocol??null,versionSource:'last-flashed',pending:null,phase:'complete',progress:100,failureClass:null,error:''};
   if(!commit(next)){state={...state,phase:'failed',failureClass:'interrupted',error:'The controller returned, but its installed-version record could not be saved.'};return false;}
   interrupted=false;return true;
  }
  function tick(){if(busy()&&now()-lastEvent>=6*60*1000)fail(highWater>=50?'interrupted':'not-started','The controller update stopped responding.');}
  function simulate(patch){
   for(const key of ['connected','retryReady','target','updateSupported','pending','installed','protocol','versionSource'])if(patch[key]!==undefined)state[key]=copy(patch[key]);
   if(patch.connected===false&&busy())fail(highWater>=50?'interrupted':'not-started','The controller disconnected.');
   if(patch.progress!==undefined)progress(patch.progress);
   if(patch.failure)fail(patch.failure);
   if(patch.complete)complete(patch.complete);
  }
  return {start,progress,fail,complete,tick,simulate,busy,reason,snapshot:()=>copy(state),available:()=>state.connected&&!busy()&&state.failureClass!=='interrupted'};
 }
 function createUI(ctx){
  const {button,header,escape:esc}=ctx;
  const controller=createControllerModel({read:ctx.readController,write:ctx.writeController,blocked:()=>ctx.capturing?.()?'Finish recording first.':ctx.playing?.()?'Stop playback first.':ctx.transferring?.()?'Finish the current transfer first.':'',now:ctx.now});
  let view='about',expanded=null,notice='',operationStart=null,simulation={failure:null,returning:true};
  const now=ctx.now||(()=>performance.now());
  function show(id){ctx.render();if(id)ctx.focus(id);}
  const row=(label,value,detail='')=>`<div class="appliance-fact"><span>${esc(label)}${detail?`<small>${esc(detail)}</small>`:''}</span><strong>${esc(value)}</strong></div>`;
  const hint='<p class="appliance-preview">Appliance preview · device facts and controller update results are simulated.</p>';
  function factsBody(){const facts=ctx.facts?.()||{},s=controller.snapshot();return header('About Segno','')+hint+`<div class="appliance-grid"><section class="appliance-panel"><h2>This console</h2>${[['Name',facts.name],['Segno',facts.appVersion],['System image',facts.systemImage],['Serial',facts.serial],['Audio interface',facts.audioInterface]].filter(([,v])=>typeof v==='string'&&v).map(([k,v])=>row(k,v)).join('')||'<p>No appliance identity is attached to this preview.</p>'}</section><section class="appliance-panel"><h2>Controller</h2>${row('Connection',controller.busy()?'Updating':s.connected?'Connected':'Disconnected')}${row('Firmware',s.installed||'Not reported',s.versionSource==='last-flashed'?'Last flashed by this console':'No device version was read')}${s.protocol?row('Wire protocol',String(s.protocol)):''}${button('appliance:controller','Controller firmware','quiet')}</section><section class="appliance-panel appliance-legal"><h2>Licenses</h2><p>Read the Segno license and the reference notices included in this preview.</p>${button('appliance:licenses','Open-source notices','quiet')}</section></div>`;}
  function licensesBody(){const notices=ctx.licenses?.()||root.SegnoApplianceReferenceNotices||[];return header('Open-source notices','')+hint+`<p class="appliance-notice-scope">Reference files from this checkout. The production destination uses the installed build’s complete license registry.</p><div class="appliance-notices">${notices.map((n,i)=>`<section class="appliance-license">${button('appliance:license:'+i,`<span>${esc(n.name)}</span><span>${expanded===i?'Close':'Read'}</span>`,'quiet',`aria-expanded="${expanded===i}"`)}${expanded===i?`<p class="appliance-license-source">${esc(n.source||'')}</p><pre>${esc(n.text)}</pre>`:''}</section>`).join('')||'<p>No notice text was supplied to this preview.</p>'}</div>`;}
  function controllerBody(){const s=controller.snapshot(),busy=controller.busy(),failed=s.phase==='failed',reason=controller.reason(),title=busy?s.progress<50?'Preparing controller update':s.progress<90?'Updating controller':'Waiting for controller':failed?'Controller update needs attention':s.phase==='complete'?'Controller updated':s.pending?'Controller update pending':'Controller firmware';
   const failedText=s.failureClass==='not-started'?'The write did not start. The controller remains on its previous firmware.':'The write may have been interrupted. The controller may be unavailable; reconnect it and restart, or use service recovery.';
   return header('Controller firmware','')+hint+`<div class="appliance-controller"><section class="appliance-panel"><h2>Installed</h2>${row('Firmware',s.installed||'Not reported',s.versionSource==='last-flashed'?'Last flashed by this console':'No device version was read')}${s.protocol?row('Wire protocol',String(s.protocol)):''}${row('Controller',s.connected?'Connected':'Disconnected')}${s.pending?row('Bundled update',s.pending.version,s.pending.verified?'Package verified in this simulation':'Verification required'):''}</section><section class="appliance-panel appliance-update-panel"><h2>${title}</h2>${busy?`<p>Keep power connected. The physical pedals are unavailable during programming.</p><div class="appliance-progress" role="progressbar" aria-label="Controller update progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${s.progress}"><span style="width:${s.progress}%"></span></div><p>Attempt ${s.attempt} of 3</p>`:failed?`<p class="appliance-error" role="alert">${esc(s.error)} ${failedText}</p><div class="appliance-actions">${button('appliance:continue','Continue with touch','quiet')}${s.connected?button('appliance:restart','Restart and retry','primary',reason?'disabled':''):''}</div>`:s.pending?`<p>The controller update belongs to the installed software. Restart to finish it after saving your session.</p>${reason?`<p class="appliance-error">${esc(reason)}</p>`:''}${button('appliance:restart','Restart to finish update','primary',reason?'disabled':'')}`:`<p>${s.phase==='complete'?'The controller returned and its installed-version record was saved in this simulation.':!s.updateSupported?'Controller update support has not been established for this hardware.':'Controller updates are supplied with Segno software updates.'}</p>${button('appliance:updates','Software updates','quiet')}`}</section></div>${notice?`<p class="appliance-error" role="alert">${esc(notice)}</p>`:''}`;
  }
  function begin(){if(!controller.start()){notice=controller.reason();show();return false;}operationStart=now();notice='';view='controller';ctx.open?.('controller');show();return true;}
  function action(id){if(!id.startsWith('appliance:'))return false;const [,key,value]=id.split(':');if(controller.busy())return true;
   if(['about','licenses','controller'].includes(key)){view=key;expanded=null;ctx.open?.(key);show();}
   if(key==='license'){expanded=expanded===Number(value)?null:Number(value);show(id);}
   if(key==='updates')ctx.updates?.();
   if(key==='restart'){if(controller.reason()){notice=controller.reason();show();}else ctx.restart?.({onRestart:begin});}
   if(key==='continue'){notice='';ctx.stage?.();}
   return true;
  }
  function tick(){const before=controller.snapshot();controller.tick();const after=controller.snapshot();if(before.phase!==after.phase||before.attempt!==after.attempt){operationStart=controller.busy()?now():null;show();return;}if(!controller.busy()||operationStart===null)return;const elapsed=now()-operationStart;
   if(simulation.failure&&elapsed>=1600){const failure=simulation.failure;simulation.failure=null;controller.progress(failure==='not-started'?30:60);controller.fail(failure);operationStart=now();show();return;}
   controller.progress(Math.min(95,Math.floor(elapsed/40)));
   if(elapsed>=4200){if(simulation.returning){const s=controller.snapshot();controller.complete({running:s.connected,readbackVerified:true,version:s.pending?.version,protocol:s.pending?.protocol});}else controller.fail('interrupted','The controller did not return after programming.');operationStart=controller.busy()?now():null;}
   if(ctx.active?.())show();
  }
  return {body:()=>view==='about'?factsBody():view==='licenses'?licensesBody():controllerBody(),action,tick,begin,
   enter:next=>{if(['about','licenses','controller'].includes(next))view=next;},
   back:()=>{if(controller.busy())return true;if(view!=='about'){view='about';expanded=null;show();return true;}return false;},
   busy:controller.busy,controllerAvailable:controller.available,
   snapshot:()=>copy({view,controller:controller.snapshot(),notice,expanded,simulation}),
   simulate:patch=>{if(patch.failure!==undefined)simulation.failure=patch.failure;if(patch.returning!==undefined)simulation.returning=patch.returning;controller.simulate(patch.controller||{});show();},
   overlay:()=>'',controller};
 }
 root.createApplianceParityStudy=createUI;root.createControllerUpdateStudyModel=createControllerModel;
 if(typeof module!=='undefined'&&module.exports)module.exports={createUI,createControllerModel};
})(typeof window==='undefined'?globalThis:window);
