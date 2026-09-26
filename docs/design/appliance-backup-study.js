// Whole-appliance backup/restore review for the silent prototype.
// The host owns media availability and atomic publication of all stores.
window.createApplianceBackupStudy=ctx=>{
  const model=window.SegnoApplianceBackupModel,copy=v=>structuredClone(v),esc=ctx.escape;
  let phase='idle',selected=null,pending=null,error='',sequence=0;
  const inspect=archive=>ctx.inspectArchive?ctx.inspectArchive(archive):model.inspect(archive);
  const archives=()=>ctx.archives(),chosen=()=>archives().find(a=>a.id===selected);
  const blocker=()=>ctx.blocker()||'';
  const show=id=>{ctx.render();if(id)ctx.focus(id);};
  function cancel(){phase='idle';pending=null;error='';show('appliance-backup:create');}
  function fail(message){error=message;show('appliance-backup:cancel');}
  function sourceUnchanged(){try{return JSON.stringify(ctx.capture())===JSON.stringify(pending.current);}catch{return false;}}
  function startBackup(){
    const reason=blocker();if(reason)return fail(reason);
    let current;try{current=copy(ctx.capture());}catch(e){return fail(e.message||'Appliance data is unreadable.');}
    const created=ctx.now?ctx.now():Date.now(),packed=model.pack(current,{id:'appliance-'+created+'-'+(++sequence),name:'Appliance backup',created});
    if(packed.error)return fail(packed.error);
    pending={current,archive:packed.archive,archives:copy(archives())};phase='backup-review';error='';show('appliance-backup:save');
  }
  function save(replace=false,keep=false){
    if(phase!=='backup-review'&&phase!=='conflict')return;
    const reason=blocker();if(reason)return fail(reason);
    if(!sourceUnchanged())return fail('Appliance data changed. Cancel and review the backup again.');
    if(JSON.stringify(archives())!==JSON.stringify(pending.archives))return fail('USB backups changed. Cancel and review them again.');
    const checked=inspect(pending.archive);if(!checked.valid)return fail(checked.error);
    const same=archives().find(a=>a.name===pending.archive.name);
    if(same&&!replace&&!keep){phase='conflict';error='';show('appliance-backup:keep');return;}
    const archive=copy(pending.archive),next=copy(archives());
    if(same&&replace)next.splice(next.findIndex(a=>a.id===same.id),1);
    if(same&&keep){let n=2;while(next.some(a=>a.name===archive.name+' ('+n+')'))n++;archive.name+=' ('+n+')';}
    try{if(ctx.writeArchives([archive,...next],pending.archives)!==true)return fail('Could not save the backup. The previous copies are unchanged.');}
    catch(e){return fail(e.message||'Could not save the backup.');}
    selected=archive.id;pending=null;phase='complete';error='';show('appliance-backup:create');
  }
  function reviewRestore(){
    const reason=blocker();if(reason)return fail(reason);
    const archive=chosen(),verified=inspect(archive);if(!verified.valid)return fail(verified.error);let current;try{current=copy(ctx.capture());}catch(e){return fail(e.message||'Appliance data is unreadable.');}
    const checked=model.restore(archive,current);
    if(checked.error)return fail(checked.error);
    pending={archive:copy(archive),current};phase='restore-review';error='';show('appliance-backup:cancel');
  }
  function restore(){
    if(phase!=='restore-review')return;
    const reason=blocker();if(reason)return fail(reason);
    if(!sourceUnchanged())return fail('Appliance data changed. Cancel and review restore again.');
    const latest=archives().find(a=>a.id===pending.archive.id);
    if(JSON.stringify(latest)!==JSON.stringify(pending.archive))return fail('The USB backup changed or disappeared. Choose it again.');
    const checked=model.restore(latest,pending.current);if(checked.error)return fail(checked.error);
    try{const result=ctx.commitRestore(checked.payload,pending.current);if(result!==true)return fail(typeof result==='string'?result:'Restore could not be saved. Current data is unchanged.');}
    catch(e){return fail(e.message||'Restore could not be saved.');}
    phase='complete';pending=null;error='';ctx.completed();show('appliance-backup:create');
  }
  function action(id){
    if(!id?.startsWith('appliance-backup:'))return false;
    if(id==='appliance-backup:open'){cancel();ctx.open();}
    else if(id==='appliance-backup:cancel')cancel();
    else if(id==='appliance-backup:create')startBackup();
    else if(id==='appliance-backup:save')save();
    else if(id==='appliance-backup:keep')save(false,true);
    else if(id==='appliance-backup:replace')save(true);
    else if(id==='appliance-backup:review')reviewRestore();
    else if(id==='appliance-backup:restore')restore();
    else if(id.startsWith('appliance-backup:row:')&&!pending){selected=id.slice('appliance-backup:row:'.length);error='';phase='idle';show('appliance-backup:review');}
    return true;
  }
  function totals(s){return `<div class="appliance-backup-totals">${[['Sessions',s.sessions],['Loop recordings',s.recordedAudio],['Backing audio',s.audio],['Presets',s.presets],['Settings',s.settings]].map(([label,value])=>`<div><span>${esc(label)}</span><strong>${esc(String(value))}</strong></div>`).join('')}</div>`;}
  function body(){
    const checked=chosen()?inspect(chosen()):null,reason=blocker();
    return `<section class="appliance-backup-panel"><div class="appliance-backup-heading"><div><h2>Save the whole appliance</h2><p>Sessions, recorded and backing audio, presets and settings.</p></div>${ctx.button('appliance-backup:create','Back up to USB','primary',reason?'disabled':'')}</div><h2>USB appliance backups</h2><div class="appliance-backup-list">${archives().map(a=>ctx.button('appliance-backup:row:'+a.id,`<span>${esc(a.name)}</span><small>${inspect(a).valid?'Ready to restore':'Needs repair'}</small>`,'appliance-backup-row '+(a.id===selected?'selected':''))).join('')||'<p>No appliance backups on this drive.</p>'}</div><div class="appliance-backup-footer"><p ${error?'role="alert"':''}>${esc(error||reason||(phase==='complete'?'Backup operation completed.':'Restore replaces the current appliance data after review.'))}</p>${ctx.button('appliance-backup:review','Review restore','primary',!checked?.valid||reason?'disabled':'')}</div></section>`;
  }
  function overlay(){
    if(!pending)return '';
    const restoring=phase==='restore-review',conflict=phase==='conflict',s=inspect(pending.archive).summary;
    return `<div class="overlay"><section class="dialog appliance-backup-dialog" role="dialog" aria-modal="true"><h2>${conflict?'A backup has this name':restoring?'Restore this appliance backup?':'Back up the whole appliance?'}</h2><p>${esc(pending.archive.name)}</p>${totals(s)}<p>${restoring?'The current Library, audio, presets and settings will be replaced together. Playback stops and Segno restarts.':conflict?'Keep both copies or replace the existing USB backup.':'Your current appliance data stays unchanged.'}</p>${error?`<p class="appliance-backup-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${ctx.button('appliance-backup:cancel','Cancel')}${conflict?ctx.button('appliance-backup:keep','Keep both','primary')+ctx.button('appliance-backup:replace','Replace'):ctx.button(restoring?'appliance-backup:restore':'appliance-backup:save',restoring?'Restore and restart':'Save backup','primary',blocker()?'disabled':'')}</div></section></div>`;
  }
  return {action,body,overlay,back:()=>{if(pending){cancel();return true;}return false;},leave:cancel,busy:()=>false,pending:()=>!!pending,mediaChanged:()=>{if(pending&&blocker())error=blocker();show();},initialFocus:()=>pending?'appliance-backup:cancel':'appliance-backup:create',snapshot:()=>copy({phase,selected,pending,error})};
};
