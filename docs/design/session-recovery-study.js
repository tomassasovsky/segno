// Pending session repair. Prototype media descriptors stand in for actual files.
window.createSessionRecoveryStudy = ctx => {
  const {button, header, icon, escape:esc} = ctx;
  const clone = value => JSON.parse(JSON.stringify(value));
  const model = window.SegnoSessionRecovery;
  let draft = null, original = null, rows = [], choosing = null, error = '', scroll = 0;
  const files = () => ctx.files();
  const problems = () => draft ? model.inspect(draft.snapshot, files()) : [];
  const ready = () => !!draft && !problems().length && ctx.ready();
  const show = id => {ctx.render(); if(id) ctx.setFocus(id);};
  function begin(entry) {
    original=clone(entry);draft=clone(entry);rows=problems();choosing=null;error='';scroll=0;
  }
  function discard() {draft=null;original=null;rows=[];choosing=null;error='';scroll=0;}
  function cancel() {discard();ctx.cancel();}
  function action(id) {
    if(!id?.startsWith('recover:') || !draft) return false;
    if(id==='recover:cancel'){cancel();return true;}
    if(id==='recover:back'){choosing=null;error='';show('recover:cancel');return true;}
    if(id==='recover:retry'){error='';show(id);return true;}
    if(id==='recover:device'){ctx.openDevice();return true;}
    if(id.startsWith('recover:choose:')){
      const key=decodeURIComponent(id.slice('recover:choose:'.length));
      choosing=problems().find(p=>p.id===key)||null;scroll=0;error='';show('recover:back');return true;
    }
    if(id.startsWith('recover:file:') && choosing){
      const file=files().find(f=>f.id===decodeURIComponent(id.slice('recover:file:'.length)));
      try{
        draft.snapshot=model.repair(draft.snapshot,choosing.id,file,files());
        for(const row of rows.filter(r=>r.id===choosing.id||r.replacement?.id===choosing.id))row.replacement=clone(file);
        choosing=null;error='';show('recover:open');
      }catch(e){error=e.message;show();}
      return true;
    }
    if(id==='recover:open'){
      if(rows.some(row=>row.replacement&&JSON.stringify(files().find(f=>f.id===row.replacement.id))!==JSON.stringify(row.replacement))){
        draft.snapshot=clone(original.snapshot);rows=problems();choosing=null;error='Audio changed. Choose the replacements again.';show('recover:cancel');return true;
      }
      if(!ready()){error=ctx.ready()?'Audio changed. Check the replacements again.':'Reconnect the audio interface first.';show('recover:retry');return true;}
      // The saved source may have changed while this draft was open.
      const result=ctx.commit(draft,original);
      if(result===true){draft=null;original=null;rows=[];choosing=null;error='';ctx.done();}
      else{error=result||'Could not save your current session. Nothing was changed.';show('recover:open');}
      return true;
    }
    return true;
  }
  function body() {
    if(!draft)return '';
    const missing=problems();
    if(choosing){
      const current=missing.find(p=>p.id===choosing.id);
      const options=current?model.candidates(current,files()):[];
      return header(choosing.kind==='recorded'?'Find original recording':'Find audio','',button('recover:back','Back'))+
        `<section class="recovery-panel"><div class="recovery-heading"><h2>${esc(choosing.name)}</h2><span>${choosing.kind==='recorded'?'Internal / backup copies':'Internal audio'}</span></div>`+
        (choosing.kind==='recorded'?'<p class="recovery-note">Choose an intact copy of this recording. Loop length stays the same.</p>':'')+
        (choosing.trackRequirements.length?'<p class="recovery-note">Same duration and format, so the loop keeps its timing.</p>':'')+
        `<div class="recovery-files">${options.length?options.map(f=>button('recover:file:'+encodeURIComponent(f.id),`<span>${esc(f.name)}</span><span class="recovery-meta">${f.location==='usb-backup'?'USB backup · ':''}${esc(f.format)} · ${Math.floor(f.seconds/60)}:${String(Math.round(f.seconds%60)).padStart(2,'0')}</span>`,'recovery-file')).join(''):choosing.kind==='recorded'?'<p class="recovery-empty">No intact original copy is available. Connect its backup and retry. A different recording cannot replace this take.</p>':'<p class="recovery-empty">No matching audio in Library. Import the recording, then open this session again.</p>'}</div>${error?`<p class="recovery-error" role="alert">${esc(error)}</p>`:''}</section>`;
    }
    const allRows=[...rows];for(const p of missing)if(!allRows.some(r=>r.id===p.id||r.replacement?.id===p.id))allRows.push(p);
    return header('Open session','',button('recover:cancel','Cancel'))+
      `<section class="recovery-panel"><div class="recovery-heading"><h2>${esc(draft.name)}</h2><span>${missing.length?missing.length+' audio '+(missing.length===1?'file':'files')+' to find':'Audio ready'}</span></div>`+
      `<div class="recovery-files">${allRows.map(row=>{const problem=missing.find(p=>p.id===(row.replacement?.id||row.id));return `<div class="recovery-row"><span class="recovery-symbol ${problem?'':'resolved'}">${icon(problem?'library':'check')}</span><div><h3>${esc(row.replacement?.name||row.name)}</h3><p>${esc(row.usages.join(' · '))}</p></div>${problem?button('recover:choose:'+encodeURIComponent(problem.id),'Find audio','quiet'): '<span class="recovery-resolved">Ready</span>'}</div>`;}).join('')}${!ctx.ready()?`<div class="recovery-row"><span class="recovery-symbol">${icon('settings')}</span><div><h3>Audio interface unavailable</h3><p>Reconnect it to open this session.</p></div>${button('recover:device','Audio setup','quiet')}</div>`:''}</div>`+
      `<div class="recovery-footer"><p class="${error?'recovery-error':'recovery-note'}" ${error?'role="alert"':''}>${esc(error||'Your current session stays open until everything is ready.')}</p>${button('recover:open',ctx.playing()?'Stop and open':'Open session','primary',ready()?'':'disabled')}</div></section>`;
  }
  return {begin,discard,action,body,active:()=>!!draft,initialFocus:()=>choosing?'recover:back':'recover:cancel',
    back:()=>{if(!draft)return false;if(choosing){choosing=null;error='';show('recover:cancel');}else cancel();return true;},
    remember:root=>{const el=root.querySelector('.recovery-files');if(el)scroll=el.scrollTop;},
    restore:root=>{const el=root.querySelector('.recovery-files');if(el)el.scrollTop=scroll;},
    snapshot:()=>clone({draft,original,choosing,error,problems:problems(),ready:ready()})};
};
