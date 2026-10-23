// Session UX proposal. Saves prototype state, not appliance audio files.
window.createSessionLibraryStudy = function (ctx) {
  const {button, header, icon, escape: esc, render, setFocus} = ctx;
  const clone = v => JSON.parse(JSON.stringify(v));
  let folder = '*', query = '', notice = '', selected = null, dialog = null, error = '', full = false, nameSelected = false, scroll = 0, usbScroll = 0, location = 'internal', pendingSequence = 0;
  const preview = window.createSessionPreviewStudy(ctx);
  const recovery = window.createSessionRecoveryStudy({...ctx,
    cancel:()=>show('session:load'),
    commit:(pending,original)=>{
      const latest=state().sessions.find(s=>s.id===original.id);
      if(!latest||JSON.stringify(latest)!==JSON.stringify(original))return 'The saved session changed. Cancel and open it again.';
      if(busy())return errorText();
      return transition('load',pending.id,pending.snapshot,true) || error;
    },done:()=>ctx.stage()});
  const initial = () => ({nextId: 2, current: {id: 'session-1', name: 'Evening loop', updated: Date.now()}, sessions: [], folders: []});
  const state = () => ctx.read() || initial();
  const current = () => ({...state().current, snapshot: ctx.capture(), current: true});
  const entries = () => [current(), ...state().sessions];
  const visible = () => entries().filter(s => (folder === '*' || (s.folder || '') === folder) && s.name.toLowerCase().includes(query.toLowerCase()));
  const folders = () => [...new Set([...(state().folders || []), ...entries().map(s => s.folder).filter(Boolean)])].sort((a,b)=>a.localeCompare(b));
  const chosen = () => entries().find(s => s.id === selected) || current();
  const busy = () => ctx.capturing() || ctx.transferring();
  const count = s => Object.values(s.snapshot.recordedParts || {}).filter(p => p.length).length + Object.keys(s.snapshot.audioLibrary?.trackImports || {}).filter(i => !s.snapshot.recordedParts?.['Track ' + (Number(i) + 1)]?.length).length;
  function show(focus) {render(); if(focus) setFocus(focus);}
  function errorText() {return error || (ctx.capturing() ? 'Finish recording before changing sessions.' : ctx.transferring() ? 'Finish the audio transfer first.' : '');}
  function transition(kind, id, repaired, fromRecovery = false) {
    const pending=dialog?.type==='dependencies'&&dialog.id===id?dialog:null;
    if (busy()) {error = errorText();if(!pending)dialog = null;show();return false;}
    preview.stop();
    const before = state(), outgoing = current();
    const target = kind === 'load' ? before.sessions.find(s => s.id === id) : null;
    if(kind === 'load' && !target) return false;
    if(target&&!window.SegnoSessionRecovery.valid(repaired||target.snapshot)){error='This session has unreadable audio references. Your current loop is unchanged.';dialog=null;show();return false;}
    if(target && (!target.snapshot || !Array.isArray(target.snapshot.racks) || !['recordedParts','trackPlayback','trackLabels','liveMonitoring','recordingInputs','loopSettings','audioLibrary'].every(k=>target.snapshot[k]&&typeof target.snapshot[k]==='object') || !Array.from({length:8},(_,i)=>'Track '+(i+1)).every(t=>Array.isArray(target.snapshot.recordedParts[t])))) {error = 'This session could not be opened. Your current loop is unchanged.';dialog = null;show();return false;}
    if(target && (window.SegnoSessionRecovery.inspect(repaired||target.snapshot,ctx.files()).length||!ctx.ready())){
      if(pending){error='Audio is no longer ready. Reconnect the audio or Cancel to repair it.';show('session:dependency-cancel');return false;}
      if(fromRecovery){error='Audio is no longer ready. Check the files and connection.';return false;}
      ctx.open();selected=target.id;dialog=null;recovery.begin(target);show(recovery.initialFocus());return false;
    }
    if(target){
      const issues=ctx.ownership(repaired||target.snapshot);
      if(issues.length){ctx.open();selected=target.id;dialog=pending?{...pending,issues,connection:null}:{type:'dependencies',token:++pendingSequence,id:target.id,name:target.name,original:clone(target),base:clone(repaired||target.snapshot),repaired:repaired?clone(repaired):null,changes:[],connection:null,issues};error='';show('session:dependency-cancel');return false;}
    }
    const next = clone(before);
    outgoing.updated = Date.now();delete outgoing.current;
    next.sessions = [outgoing, ...next.sessions.filter(s => s.id !== outgoing.id && s.id !== target?.id)];
    const destination = target || {id: 'session-' + next.nextId++, name: 'New loop ' + (next.nextId - 1), snapshot: ctx.fresh(outgoing.snapshot)};
    next.current = {id: destination.id, name: destination.name, folder: destination.folder || '', updated: Date.now()};
    if(full || !ctx.commit(next, repaired||destination.snapshot,kind)) {error = 'Could not save your current loop. Nothing was changed.';if(!pending)dialog = null;show(pending?'session:dependency-retry':undefined);return false;}
    selected = destination.id;dialog = null;error = '';if(!fromRecovery){recovery.discard();ctx.stage();}return true;
  }
  function newLoop(foot = false) {
    error = '';
    if(foot) {const ok = transition('new');if(!ok)ctx.notice(errorText());return ok;}
    if(busy()) {show();return;}
    dialog = {type: 'new'};show('session:cancel');
  }
  function naming(purpose, entry = chosen()) {
    dialog = {type:'name', purpose, id:entry.id, name:purpose==='search'?query:purpose==='folder'?'':purpose==='duplicate'||purpose==='save-as'?entry.name+' copy':entry.name};
    nameSelected = true;error = '';show('session:key:A');
  }
  function persistMetadata(next, failure) {
    if(full || ctx.metadata(next) === false) {error=failure;show();return false;}
    error='';return true;
  }
  function saveName() {
    const value=dialog.name.trim(), purpose=dialog.purpose || 'rename';
    if(!value && purpose!=='search')return;
    if(purpose==='search'){query=value;selected=visible()[0]?.id||null;dialog=null;show('session:search');return;}
    const s=clone(state()), entry=s.current.id===dialog.id?s.current:s.sessions.find(e=>e.id===dialog.id);
    if(purpose==='folder'){
      if(folders().some(f=>f.toLowerCase()===value.toLowerCase())){error='That folder already exists.';show();return;}
      (s.folders ||= []).push(value);
      if(!persistMetadata(s,'The folder could not be saved. Try again.'))return;
      folder=value;query='';selected=null;notice='Folder created.';
    }else if(purpose==='duplicate'||purpose==='save-as'){
      if(busy()){error=errorText();show();return;}
      const source=entries().find(e=>e.id===dialog.id);
      if(!source){error='This session is no longer available.';show();return;}
      const copy={...clone(source),id:'session-'+s.nextId++,name:value,updated:Date.now()};delete copy.current;
      // Duplicating preserves every original ID reference inside its independent snapshot.
      if(purpose==='save-as'){
        const outgoing=current();delete outgoing.current;
        s.sessions=[outgoing,...s.sessions.filter(e=>e.id!==outgoing.id)];
        s.current={id:copy.id,name:copy.name,folder:copy.folder||'',updated:copy.updated};
        if(!persistMetadata(s,'The copy could not be saved. Your current session is unchanged.'))return;
      }else{
        s.sessions.unshift(copy);
        if(!persistMetadata(s,'The copy could not be saved. Try again.'))return;
      }
      selected=copy.id;folder=copy.folder||'';query='';notice='Independent copy saved.';
    }else{
      if(!entry){error='This session is no longer available.';show();return;}
      entry.name=value;
      if(!persistMetadata(s,'The name could not be saved. Try again.'))return;
    }
    dialog=null;error='';show('session:manage');
  }
  function requestLoad(id) {
    if(id===state().current.id){ctx.stage();return true;}
    const target=state().sessions.find(e=>e.id===id);if(!target)return false;
    if(busy()){error=errorText();ctx.notice(error);return false;}
    if(!window.SegnoSessionRecovery.valid(target.snapshot))return transition('load',id);
    if(target.snapshot && (window.SegnoSessionRecovery.inspect(target.snapshot,ctx.files()).length||!ctx.ready()))return transition('load',id);
    if(ctx.playing()){ctx.open();folder='*';query='';selected=id;dialog={type:'load',token:++pendingSequence,id,name:target.name};show('session:cancel');return false;}
    return transition('load',id);
  }
  function command(kind) {
    if(kind==='save'){
      if(busy()){ctx.notice(errorText());return false;}
      const next=clone(state());next.current.updated=Date.now();
      const ok=persistMetadata(next,'This session could not be saved. Try again.');
      ctx.notice(ok?'Session saved.':error);return ok;
    }
    const list=entries().sort((a,b)=>Number(a.id.replace('session-',''))-Number(b.id.replace('session-',''))),index=list.findIndex(s=>s.id===state().current.id),target=list[index+(kind==='previous'?-1:kind==='next'?1:0)];
    if(!['previous','next'].includes(kind)||!target){ctx.notice('No '+kind+' session.');return false;}
    return requestLoad(target.id);
  }
  function dependencySources() {
    const sources=[];
    for(const issue of dialog.issues){
      const source=issue.port!==undefined?{kind:'control',port:issue.port}:issue.kind==='audio-port'?{kind:'audio-port',id:issue.id,label:issue.label}:issue.kind==='midi-device'?{kind:'midi',id:issue.id}:issue.kind==='control-target'?{kind:'target',id:issue.id}:null;
      if(source&&!sources.some(s=>JSON.stringify(s)===JSON.stringify(source)))sources.push(source);
    }
    return sources;
  }
  function sourceLabel(source){if(source.kind==='audio-port')return source.label;if(source.kind==='target'){const t=ctx.describeTarget(dependencySnapshot(),source.id);return [t.detail,t.label].filter(Boolean).join(' · ');}return source.kind==='control'?'CTRL '+(source.port+1):ctx.connectionOptions(dependencySnapshot(),source).find(c=>c.id===source.id)?.label||'MIDI controller';}
  const dependencySnapshot=()=>dialog.repaired||dialog.base;
  const targetOptions=()=>ctx.targetOptions(dependencySnapshot(),dialog.connection.id);
  const targetDestinations=(choices=targetOptions())=>[...new Set(choices.map(t=>t.destination||t.detail||'Controls'))];
  function repairActions(){
    if(!dialog.connection)return dependencySources().map((_,i)=>'session:connection:'+i);
    if(dialog.connection.kind!=='target')return ctx.connectionOptions(dependencySnapshot(),dialog.connection).filter(c=>c.enabled).map(c=>'session:replacement:'+(typeof c.id==='number'?c.id:encodeURIComponent(c.id)));
    if(dialog.targetChoice)return ctx.previewTarget(dependencySnapshot(),dialog.connection.id,dialog.targetChoice).affected?.length>3?['session:target-page:previous','session:target-page:next']:[];
    if(dialog.targetDestination===null||dialog.targetDestination===undefined)return targetDestinations().map(d=>'session:target-destination:'+encodeURIComponent(d));
    return targetOptions().filter(t=>(t.destination||t.detail||'Controls')===dialog.targetDestination&&t.enabled).map(t=>'session:target-choice:'+encodeURIComponent(t.key));
  }
  function repairBack(){
    if(dialog.targetChoice)dialog.targetChoice=null;
    else if(dialog.connection?.kind==='target'&&dialog.targetDestination!==null&&dialog.targetDestination!==undefined)dialog.targetDestination=null;
    else dialog.connection=null;
    dialog.connectionPage=0;error='';show('session:dependency-cancel');
  }
  function pendingUnchanged(){
    const latest=state().sessions.find(s=>s.id===dialog.id);
    if(latest&&JSON.stringify(latest)===JSON.stringify(dialog.original))return true;
    error='The saved session changed. Cancel and open it again.';show('session:dependency-cancel');return false;
  }
  function footBindings(){
    if(dialog?.type!=='dependencies')return [];
    const items=repairActions();
    const pages=Math.max(1,Math.ceil(items.length/4));dialog.connectionPage=(dialog.connectionPage||0)%pages;
    return [...items.slice(dialog.connectionPage*4,dialog.connectionPage*4+4).map((action,i)=>({id:i+4,label:String(i+1),action})),{id:1,label:'STOP',action:dialog.targetChoice?'session:target-use':dialog.connection?'session:connection-back':'session:dependency-retry'},...(dialog.changes.length&&!dialog.connection?[{id:8,label:'CLEAR',action:'session:connection-reset'}]:[]),...(pages>1?[{id:9,label:'BANK',action:'session:connection-page'}]:[])];
  }
  function action(id) {
    if(recovery.action(id))return true;
    if(!id?.startsWith('session:'))return false;
    if(dialog?.type==='dependencies'&&/^session:(connection|replacement|dependency|target)/.test(id))dialog.revision=(dialog.revision||0)+1;
    if(id==='session:listen'){preview.toggle(chosen());show(id);return true;}
    preview.stop();
    const value = id.split(':').slice(2).join(':');
    if(id === 'session:library') {recovery.discard();ctx.open();location='internal';selected ||= state().current.id;dialog = null;error = '';show('session:row:' + selected);}
    else if(id.startsWith('session:location:')){location=value;ctx.backup().beginBrowse();show(id);}
    else if(id.startsWith('session:row:')) {selected = value;error = '';notice='';show(id);}
    else if(id.startsWith('session:folder:')){folder=decodeURIComponent(value);selected=visible()[0]?.id||null;scroll=0;show(id);}
    else if(id==='session:search')naming('search');
    else if(id==='session:clear-search'){query='';selected=visible()[0]?.id||null;show('session:search');}
    else if(id==='session:create-folder')naming('folder');
    else if(id === 'session:new')newLoop();
    else if(id === 'session:confirm-new')transition('new');
    else if(id === 'session:load')requestLoad(chosen().id);
    else if(id === 'session:confirm-load')transition('load',dialog.id);
    else if(id==='session:dependency-cancel'){recovery.discard();dialog=null;error='';show('session:load');}
    else if(id.startsWith('session:connection:')&&dialog?.type==='dependencies'){
      if(!pendingUnchanged())return true;
      const source=dependencySources()[Number(value)];
      if(source){dialog.connection=source;dialog.targetDestination=null;dialog.targetChoice=null;dialog.connectionPage=0;error='';show('session:connection-back');}
    }
    else if(id==='session:connection-back'&&dialog?.type==='dependencies')repairBack();
    else if(id==='session:connection-page'&&dialog?.type==='dependencies'){dialog.connectionPage=(dialog.connectionPage||0)+1;show(footBindings()[0]?.action||'session:dependency-cancel');}
    else if(id==='session:connection-reset'&&dialog?.type==='dependencies'){
      dialog.repaired=clone(dialog.base);dialog.changes=[];dialog.connection=null;dialog.targetDestination=null;dialog.targetChoice=null;dialog.issues=ctx.ownership(dependencySnapshot());error='';show('session:dependency-cancel');
    }
    else if(id.startsWith('session:target-destination:')&&dialog?.connection?.kind==='target'){
      if(!pendingUnchanged())return true;
      const destination=decodeURIComponent(value);if(targetDestinations().includes(destination)){dialog.targetDestination=destination;dialog.targetChoice=null;dialog.connectionPage=0;error='';show('session:connection-back');}
    }
    else if(id.startsWith('session:target-choice:')&&dialog?.connection?.kind==='target'){
      if(!pendingUnchanged())return true;
      const key=decodeURIComponent(value),preview=ctx.previewTarget(dependencySnapshot(),dialog.connection.id,key);
      if(preview.error){error=preview.error;show('session:connection-back');return true;}
      dialog.targetChoice=key;dialog.targetPage=0;dialog.connectionPage=0;error='';show('session:target-use');
    }
    else if(id.startsWith('session:target-page:')&&dialog?.connection?.kind==='target'&&dialog.targetChoice){
      const count=ctx.previewTarget(dependencySnapshot(),dialog.connection.id,dialog.targetChoice).affected?.length||0;
      const last=Math.max(0,Math.ceil(count/3)-1);dialog.targetPage=Math.max(0,Math.min(last,(dialog.targetPage||0)+(value==='next'?1:-1)));
      error='';show(dialog.targetPage===last?'session:target-page:previous':'session:target-page:next');
    }
    else if(id==='session:target-use'&&dialog?.connection?.kind==='target'&&dialog.targetChoice){
      if(!pendingUnchanged())return true;
      const result=ctx.repairTarget(dependencySnapshot(),dialog.connection.id,dialog.targetChoice);
      if(result.error){error=result.error;show('session:connection-back');return true;}
      dialog.repaired=result.snapshot;dialog.changes.push({...result.change,kind:'target'});dialog.connection=null;dialog.targetChoice=null;dialog.targetDestination=null;dialog.connectionPage=0;
      dialog.issues=ctx.ownership(dependencySnapshot());error='';show('session:dependency-retry');
    }
    else if(id.startsWith('session:replacement:')&&dialog?.type==='dependencies'&&dialog.connection){
      if(!pendingUnchanged())return true;
      const replacement=dialog.connection.kind==='control'?Number(value):decodeURIComponent(value);
      const connection=dialog.connection.kind==='audio-port'?{label:sourceLabel(dialog.connection),replacement:ctx.connectionOptions(dependencySnapshot(),dialog.connection).find(c=>c.id===replacement)?.label}:null;
      const result=ctx.repairConnection(dependencySnapshot(),dialog.connection,replacement);
      if(result.error){error=result.error;show('session:connection-back');return true;}
      dialog.repaired=result.snapshot;dialog.changes.push({text:result.changes[0],affected:result.changes.slice(1),connection});dialog.connection=null;dialog.connectionPage=0;
      dialog.issues=ctx.ownership(dependencySnapshot());error='';show('session:dependency-retry');
    }
    else if(id==='session:dependency-retry'&&dialog?.type==='dependencies'){
      if(pendingUnchanged())transition('load',dialog.id,dialog.repaired||undefined);
    }
    else if(id === 'session:cancel'){const prior=dialog;dialog=null;error='';show(prior?.purpose==='search'?'session:search':prior?.purpose==='folder'?'session:create-folder':prior?.type==='new'?'session:new':visible().length?'session:manage':'session:search');}
    else if(id==='session:manage'){dialog={type:'manage',id:chosen().id};show('session:rename');}
    else if(id === 'session:rename')naming('rename');
    else if(id === 'session:duplicate')naming('duplicate');
    else if(id === 'session:save-as')naming('save-as',current());
    else if(id === 'session:move'){dialog={type:'move',id:chosen().id};show('session:move-to:');}
    else if(id.startsWith('session:move-to:')){
      const to=decodeURIComponent(value),s=clone(state()),entry=s.current.id===dialog.id?s.current:s.sessions.find(e=>e.id===dialog.id);
      if(entry && (!to || folders().includes(to))){entry.folder=to;if(persistMetadata(s,'The session could not be moved. Try again.')){folder=to;query='';dialog=null;notice='Session moved.';show('session:manage');}}
    }
    else if(id === 'session:delete'){if(!chosen().current){dialog={type:'delete',id:chosen().id,name:chosen().name};show('session:cancel');}}
    else if(id === 'session:confirm-delete'){
      if(dialog?.type!=='delete'||dialog.id===state().current.id)return true;
      if(busy()){error=errorText();show();return true;}
      const s=clone(state());s.sessions=s.sessions.filter(e=>e.id!==dialog.id);
      if(persistMetadata(s,'The session could not be deleted. Try again.')){dialog=null;selected=visible()[0]?.id||null;notice='Session deleted.';show('session:search');}
    }
    else if(id.startsWith('session:key:'))editName(value);
    else if(id === 'session:name-done')saveName();
    return true;
  }
  function editName(key) {
    if(key==='delete')dialog.name=nameSelected?'':dialog.name.slice(0,-1);
    else if(key==='clear')dialog.name='';
    else dialog.name=((nameSelected?'':dialog.name)+(key==='space'?' ':key)).slice(0,48);
    nameSelected = false;show();
  }
  function tracks(s, small = false) {
    if(!small)return preview.body(s);
    return `<div class="session-tracks mini">${Array.from({length:8},(_,i)=>`<span class="${s.snapshot.recordedParts?.['Track '+(i+1)]?.length||s.snapshot.audioLibrary?.trackImports?.[i]?'filled':''}"></span>`).join('')}</div>`;
  }
  function body() {
    if(recovery.active())return recovery.body();
    const s=chosen(), settings=s.snapshot.loopSettings||{}, n=count(s), list=visible();
    const locations=`<nav class="session-locations" aria-label="Session location">${['internal','usb'].map(v=>button('session:location:'+v,v==='internal'?'Internal':'USB','quiet '+(location===v?'selected':''),`aria-pressed="${location===v}"`)).join('')}</nav>`;
    const title=header('Library','',`<div class="session-library-actions">${locations}${button('session:new','New loop','primary',busy()?'disabled':'')}</div>`);
    if(location==='usb')return title+ctx.backup().usbList();
    return title+
      `<div class="session-library-layout"><section class="session-list"><div class="session-search">${button('session:search',esc(query)||'Search sessions','quiet')}${query?button('session:clear-search','Clear','quiet'):''}${button('session:create-folder','New folder','quiet')}</div><nav class="session-folders" aria-label="Session folders">${[['*','All'],['','Unfiled'],...folders().map(f=>[f,f])].map(([key,label])=>button('session:folder:'+encodeURIComponent(key),esc(label),'quiet '+(folder===key?'selected':''),`aria-pressed="${folder===key}"`)).join('')}</nav><div class="session-scroll">${list.map(e=>button('session:row:'+e.id,`<span class="session-row-title">${esc(e.name)}</span><span class="session-row-meta">${e.current?'Current session':new Date(e.updated).toLocaleDateString('en-GB',{day:'numeric',month:'short'})+' · '+count(e)+' tracks'}</span>${tracks(e,true)}`,'session-row '+(e.id===s.id?'selected':''),`aria-pressed="${e.id===s.id}"`)).join('')}${!list.length?'<p class="session-list-empty">'+(query?'No matching sessions.':'This folder is empty.')+'</p>':''}</div></section>
      <section class="session-preview">${!list.length?'<h2>'+esc(query?'No matching sessions':folder||'Unfiled')+'</h2><p class="session-list-empty">Choose another folder or search.</p>':`<div class="session-preview-heading"><h2>${esc(s.name)}</h2>${button('session:manage','Manage')}</div><div class="session-preview-info"><div class="session-musical-meta"><span>${settings.tempo||84} BPM</span><span>${esc(settings.signature||'4/4')}</span><span>${n?n+' tracks':'Empty loop'}</span></div>${preview.controls(s)}</div>${tracks(s)}${s.current?'':'<p class="session-notice">Sound, routing and assignments return. Current hardware setup and input names stay.</p>'}<div class="session-recall">${ctx.backup().busy()?ctx.backup().notice():`<span>${s.snapshot.racks.length} FX · ${(s.snapshot.audioLibrary?.prepared||[]).length} backing tracks</span>${button('backup:export','Back up to USB','quiet',busy()?'disabled':'')}${button('session:load',s.current?'Return to tracks':'Open session','primary',busy()?'disabled':'')}`}</div>`}</section></div>${notice?`<p class="session-notice" role="status">${esc(notice)}</p>`:''}${!ctx.backup().busy()&&errorText()?`<p class="session-error" role="alert">${esc(errorText())}</p>`:''}`; 
  }
  function overlay() {
    if(recovery.active()&&dialog?.type!=='dependencies')return '';
    if(!dialog)return ctx.backup().overlay();
    let content;
    if(dialog.type==='dependencies') {
      const label=issue=>issue.kind==='audio-port'?issue.label+' · '+issue.reason:issue.kind==='audio-port-manifest'?issue.label:issue.kind==='control-type'?`${issue.source} needs ${issue.expected||'a defined pedal type'}; current setup is ${issue.actual||'unavailable'}.`:issue.kind==='control-connection'?`${issue.source} is not connected.`:issue.kind==='control-calibration'?`${issue.source} needs current pedal calibration.`:issue.kind==='switch-hardware'?`${issue.source}, switch ${issue.index+1} needs ${issue.expected||'defined'} hardware; current setup is ${issue.actual||'unavailable'}.`:issue.kind==='midi-device'?`MIDI controller “${issue.id}” is unavailable.`:issue.kind==='control-target'?`${sourceLabel({kind:'target',id:issue.id})} is unavailable.`:'Referenced audio needs repair.';
      if(dialog.connection?.kind==='target'){
        const choices=targetOptions(),preview=dialog.targetChoice?ctx.previewTarget(dependencySnapshot(),dialog.connection.id,dialog.targetChoice):null;
        const picked=choices.find(t=>t.key===dialog.targetChoice);
        content=`<h2>${preview?'Use this control?':'Replace control'}</h2><p>${esc(sourceLabel(dialog.connection))}</p>`;
        if(preview){
          const affected=preview.affected||[],last=Math.max(0,Math.ceil(affected.length/3)-1),index=Math.min(dialog.targetPage||0,last),start=index*3;
          content+=`<div class="session-target-summary"><strong>${esc([preview.detail,preview.label].filter(Boolean).join(' · '))}</strong>${picked?.note?`<small>${esc(picked.note)}</small>`:''}</div><div class="session-target-ranges">${affected.slice(start,start+3).map(a=>`<article><h3>${esc(a.source)}</h3><div>${a.values.map(v=>`<span>${esc(v.label)}<output>${esc(v.formatted)}</output></span>`).join('')}</div></article>`).join('')}</div>${last?`<div class="session-target-pages"><span>${start+1}–${Math.min(start+3,affected.length)} / ${affected.length} assignments</span>${button('session:target-page:previous','Previous','quiet',index?'':'disabled')}${button('session:target-page:next','Next','quiet',index<last?'':'disabled')}</div>`:''}<p>Range positions are kept. These are the replacement values.</p>`;
        }else{
          const atDestination=dialog.targetDestination!==null&&dialog.targetDestination!==undefined;
          content+=`<div class="session-connection-options session-target-options">${atDestination?choices.filter(t=>(t.destination||t.detail||'Controls')===dialog.targetDestination).map(t=>button('session:target-choice:'+encodeURIComponent(t.key),`<span>${esc(t.label)}<small>${esc(t.detail||'')}</small></span>${t.reason?`<small>${esc(t.reason)}</small>`:''}`,'quiet session-connection-option',t.enabled?'':'disabled')).join(''):targetDestinations(choices).map(d=>button('session:target-destination:'+encodeURIComponent(d),esc(choices.find(t=>(t.destination||t.detail||'Controls')===d)?.destinationLabel||d),'quiet session-connection-option')).join('')}${!choices.length?'<p>No replacement controls are available in this session.</p>':''}</div>`;
        }
        content+=`${error||preview?.error?`<p class="session-error" role="alert">${esc(error||preview.error)}</p>`:''}<div class="actions">${button('session:dependency-cancel','Cancel')}${button('session:connection-back','Back')}${preview?button('session:target-use','Use control','primary',preview.error?'disabled':''):''}</div>`;
      }else if(dialog.connection){
        const choices=ctx.connectionOptions(dependencySnapshot(),dialog.connection),affected=[...new Set(choices.flatMap(c=>c.affected))];
        content=`<h2>Replace ${esc(sourceLabel(dialog.connection))}</h2><p>Choose the connection to use for this session.</p><div class="session-connection-options">${choices.map(c=>button('session:replacement:'+(typeof c.id==='number'?c.id:encodeURIComponent(c.id)),`<span>${esc(c.label)}</span>${c.reason?`<small>${esc(c.reason)}</small>`:''}`,'quiet session-connection-option',c.enabled?'':'disabled')).join('')||'<p>No replacement connections are available.</p>'}</div>${affected.length?`<div class="session-repair-affected"><h3>${dialog.connection.kind==='audio-port'?'Routes':'Assignments'}</h3>${affected.map(a=>`<span>${esc(a)}</span>`).join('')}</div>`:''}${error?`<p class="session-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${button('session:dependency-cancel','Cancel')}${button('session:connection-back','Back')}</div>`;
      }else{
        const sources=dependencySources();
        const targetRepair=dialog.changes.some(c=>c.kind==='target')||sources.some(s=>s.kind==='target');
        const matches=(s,i)=>s.kind==='control'?s.port===i.port:s.id===i.id&&i.kind===(s.kind==='audio-port'?'audio-port':s.kind==='target'?'control-target':'midi-device');
        content=`<h2>${dialog.changes.length?(targetRepair?'Review changes':'Review connections'):'Check '+esc(dialog.name)+(targetRepair?' controls':' connections')}</h2><div class="session-connection-review">${dialog.changes.map(change=>change.kind==='target'?`<div class="session-control-change"><div class="session-control-comparison">${[['From',change.from],['To',change.to]].map(([label,control])=>`<div><small>${label}</small><strong>${esc(control.label)}</strong><span>${esc(control.detail)}</span></div>`).join('')}</div><span class="session-control-count">${change.affected.length} ${change.affected.length===1?'assignment':'assignments'} updated</span></div>`:change.connection?`<div class="session-port-change"><div class="session-port-comparison"><div><small>For</small><strong>${esc(change.connection.label)}</strong></div><div><small>Use connection</small><strong>${esc(change.connection.replacement)}</strong></div></div><span class="session-control-count">${change.affected.length} ${change.affected.length===1?'route':'routes'} updated</span></div>`:`<div class="session-connection-change"><strong>${esc(change.text)}</strong><span>${change.affected.map(esc).join(' · ')}</span></div>`).join('')}${dialog.issues.map(issue=>{const index=sources.findIndex(s=>matches(s,issue));const first=index>=0&&dialog.issues.find(i=>matches(sources[index],i))===issue;return `<div class="session-connection-issue"><span>${esc(label(issue))}</span>${first?button('session:connection:'+index,'Replace','quiet'):''}</div>`;}).join('')}</div><p>${dialog.changes.length?(targetRepair?'Opening '+esc(dialog.name)+' stops playback.':'Opening '+esc(dialog.name)+' stops playback.'):'Reconnect the required device or choose a replacement.'}</p>${error?`<p class="session-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${button('session:dependency-cancel','Cancel')}${dialog.changes.length?button('session:connection-reset','Reset choices'):''}${button('session:dependency-retry',dialog.changes.length?'Apply and open':'Retry open','primary')}</div>`;
      }
    } else if(dialog.type==='name') {
      content=`<h2>${({search:'Search sessions',folder:'New folder',duplicate:'Duplicate session','save-as':'Save current as'})[dialog.purpose]||'Session name'}</h2><div class="name-value"><span class="${nameSelected?'selected-name':''}">${esc(dialog.name)||' '}</span></div><div class="name-keyboard">${['1234567890','QWERTYUIOP','ASDFGHJKL','ZXCVBNM'].map(row=>`<div class="key-row">${[...row].map(c=>button('session:key:'+c,c,'key')).join('')}</div>`).join('')}<div class="key-row">${button('session:key:clear','Clear','key wide')}${button('session:key:space','Space','key wide')}${button('session:key:delete',icon('delete'),'key wide','aria-label="Delete character"')}</div></div>${error?`<p class="session-error">${esc(error)}</p>`:''}<div class="actions">${button('session:cancel','Cancel')}${button('session:name-done','Done','primary',dialog.name.trim()||dialog.purpose==='search'?'':'disabled')}</div>`;
    } else if(dialog.type==='manage') {
      const s=chosen();content=`<h2>${esc(s.name)}</h2><div class="session-manage-grid">${button('session:rename','Rename')}${button('session:duplicate','Duplicate','quiet',busy()?'disabled':'')}${button('session:move','Move to folder')}${button('session:save-as','Save current as…','quiet',busy()?'disabled':'')}${button('session:delete','Delete','danger',s.current||busy()?'disabled':'')}</div>${s.current?'<p>Open another session before deleting this one.</p>':''}<div class="actions">${button('session:cancel','Close')}</div>`;
    } else if(dialog.type==='move') {
      content=`<h2>Move to folder</h2><div class="session-folder-picker">${['',...folders()].map(f=>button('session:move-to:'+encodeURIComponent(f),esc(f||'Unfiled'),'quiet')).join('')}</div>${error?`<p class="session-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${button('session:cancel','Cancel')}</div>`;
    } else if(dialog.type==='delete') {
      content=`<h2>Delete ${esc(dialog.name)}?</h2><p>This removes the saved session and its loop recordings. Shared audio and USB backups are kept.</p>${error?`<p class="session-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${button('session:cancel','Cancel')}${button('session:confirm-delete','Delete session','danger',busy()?'disabled':'')}</div>`;
    } else if(dialog.type==='new') {
      content=`<h2>New loop</h2><p><strong>${esc(state().current.name)}</strong> stays in your Library.</p><div class="session-new-preview">${tracks(current(),true)}${icon('right')}${tracks({snapshot:{recordedParts:{}}},true)}</div><p>Keep your effects, tempo and pedal setup.</p><div class="actions">${button('session:cancel','Cancel')}${button('session:confirm-new','Start new loop','primary')}</div>`;
    } else content=`<h2>Open ${esc(dialog.name)}?</h2><p>Your current session is kept. Playback stops.</p><div class="actions">${button('session:cancel','Cancel')}${button('session:confirm-load','Open session','primary')}</div>`;
    return `<div class="overlay"><section class="dialog ${dialog.type==='name'?'name-dialog':'session-dialog'}${dialog.type==='dependencies'?' session-connections':''}${dialog.connection?.kind==='audio-port'?' session-audio-ports':''}" role="dialog" aria-modal="true">${content}</section></div>`;
  }
  function review(name) {
    selected=state().current.id;
    if(name==='session-ownership'||name==='session-ownership-missing'||name.startsWith('session-connection')||name.startsWith('session-target')){
      selected=ctx.ownershipReview(name);
      if(name.endsWith('-missing')||name.startsWith('session-connection')||name.startsWith('session-target'))transition('load',selected);
      if(name.startsWith('session-target')&&!name.endsWith('-missing')){
        action('session:connection:'+dependencySources().findIndex(s=>s.kind==='target'));
        if(!name.endsWith('-destinations'))action('session:target-destination:Guitar');
        if(name.endsWith('-review')||name.endsWith('-ready')){
          const choice=targetOptions().find(t=>t.enabled&&t.destination==='Guitar'&&t.label==='Delay · Mix')||targetOptions().find(t=>t.enabled&&t.destination==='Guitar');
          if(choice)action('session:target-choice:'+encodeURIComponent(choice.key));
          if(name.endsWith('-ready'))action('session:target-use');
        }
      }
      if(name==='session-connection-picker'||name==='session-connection-ready'||name==='session-connection-midi')action('session:connection:0');
      if(name==='session-connection-ready')action('session:replacement:1');
      return;
    }
    if(name.startsWith('session-recovery')){
      const s=clone(state()),snapshot=ctx.capture(),available=ctx.files();
      const loop=clone(available.find(f=>f.seconds===24)||available[0]),backing=clone(available[0]);
      loop.id='missing-loop';loop.name='Guitar phrase.wav';backing.id='missing-backing';backing.name='Evening lights.wav';
      snapshot.audioLibrary={...snapshot.audioLibrary,prepared:[backing.id],backing,trackImports:{0:{file:loop,state:'stopped',speed:1,sourceLocation:'internal',timing:{policy:'unchanged',effectiveSeconds:loop.seconds}}}};
      const entry={id:'session-'+s.nextId++,name:'Evening set',updated:Date.now(),snapshot};s.sessions.unshift(entry);ctx.metadata(s);selected=entry.id;
      recovery.begin(entry);
      if(name.endsWith('-files'))recovery.action('recover:choose:missing-loop');
      if(name.endsWith('-ready')||name.endsWith('-error')||name.endsWith('-device')){
        for(const problem of window.SegnoSessionRecovery.inspect(entry.snapshot,available)){
          const candidate=window.SegnoSessionRecovery.candidates(problem,available)[0];
          if(candidate){recovery.action('recover:choose:'+encodeURIComponent(problem.id));recovery.action('recover:file:'+encodeURIComponent(candidate.id));}
        }
      }
      if(name.endsWith('-error')){full=true;recovery.action('recover:open');}
      return;
    }
    if(name==='session-new')dialog={type:'new'};
    if(name==='session-name'){dialog={type:'name',id:selected,name:state().current.name};nameSelected=true;}
    if(name==='session-empty')transition('new');
    if(name==='session-saved') {transition('new');selected=state().sessions[0].id;ctx.open();}
    if(name==='session-error'){full=true;transition('new');ctx.open();}
  }
  return {command,footBindings,leave:(next)=>{preview.stop();if(next!=='audio-device')recovery.discard();if(dialog?.type==='dependencies'){dialog=null;error='';}},refresh:root=>{if(!ctx.active()){preview.stop();return;}preview.refresh(root,chosen(),location==='internal'&&!dialog);},body,overlay,action,newLoop,review,initial,tracks,selectedEntry:()=>clone(chosen()),setLocation:value=>{preview.stop();location=value;},reveal:id=>{preview.stop();recovery.discard();location='internal';folder='*';query='';selected=id||state().current.id;dialog=null;error='';},
    currentName:()=>state().current.name,
    back:()=>{preview.stop();if(dialog?.type==='dependencies'){if(dialog.connection){action('session:connection-back');return true;}recovery.discard();dialog=null;error='';show('session:load');return true;}if(recovery.back())return true;if(ctx.backup().back())return true;if(!dialog)return false;dialog=null;error='';return true;},
    initialFocus:()=>dialog?.type==='dependencies'?'session:dependency-cancel':recovery.active()?recovery.initialFocus():dialog?'session:cancel':location==='usb'?ctx.backup().initialFocus():visible().length?'session:row:'+(visible().find(s=>s.id===selected)?.id||visible()[0].id):'session:search',
    key:e=>{if(!ctx.active()||dialog?.type!=='name')return false;if(e.key==='Backspace'){editName('delete');return true;}if(/^[a-zA-Z0-9 _-]$/.test(e.key)){editName(e.key);return true;}return false;},
    remember:root=>{recovery.remember(root);preview.remember(root);const el=root.querySelector('.session-scroll'),usb=root.querySelector('.backup-scroll');if(el)scroll=el.scrollTop;if(usb)usbScroll=usb.scrollTop;},
    restore:root=>{recovery.restore(root);preview.restore(root);preview.refresh(root,chosen(),ctx.active()&&location==='internal'&&!dialog&&!recovery.active());const el=root.querySelector('.session-scroll'),usb=root.querySelector('.backup-scroll');if(el)el.scrollTop=scroll;if(usb)usb.scrollTop=usbScroll;},
    simulate:v=>{if(v.full!==undefined)full=v.full;},
    snapshot:()=>clone({folder,query,visible:visible().map(s=>s.id),notice,preview:preview.snapshot(),location,selected:chosen().id,state:state(),recovery:recovery.snapshot(),dialog,error:errorText()})};
};
