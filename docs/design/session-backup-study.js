// Session backup UX. Packages contain prototype state and media descriptions,
// not real audio bytes. USB IO, integrity checks and free space are simulated.
window.createSessionBackupStudy = ctx => {
  const {button, escape: esc} = ctx;
  const copy = value => JSON.parse(JSON.stringify(value));
  let archives = ctx.read() || [], selected = null, source = null, mode = 'export';
  let phase = 'ready', error = '', progress = 0, timer = null, operation = null;
  let failure = false, full = false, restoredId = null, resultName = '';
  const busy = () => !!timer;
  const chosen = () => archives.find(a => a.id === selected);
  const trackCount = s => Array.from({length:8}, (_,i) => !!s?.snapshot?.recordedParts?.['Track ' + (i+1)]?.length || !!s?.snapshot?.audioLibrary?.trackImports?.[i]).filter(Boolean).length;
  const details = s => `${trackCount(s)} tracks · ${s?.snapshot?.racks?.length || 0} FX · ${s?.snapshot?.audioLibrary?.prepared?.length || 0} backing tracks`;
  const blocker = () => !ctx.usb() ? 'Connect a USB drive.' : ctx.ejecting() ? 'Wait for USB eject to finish.' : ctx.capturing() ? 'Finish recording first.' : ctx.transferring() ? 'Finish the current transfer first.' : '';
  function show(focus) { ctx.changed(); if (ctx.active()) { ctx.render(); if (focus) ctx.focus(focus); } }
  function unique(name, list) { const names = new Set(list.map(s => s.name)); let n = 2, result = name; while (names.has(result)) result = name + ' (' + n++ + ')'; return result; }
  function valid(a) {
    const s = a?.session?.snapshot, audio = s?.audioLibrary;
    if (!a || a.format !== 1 || a.damaged || !s || !Array.isArray(s.racks) || !audio || !Array.isArray(audio.prepared) || !Array.isArray(a.media)) return false;
    if (!['recordingInputs','liveMonitoring','loopSettings','trackLabels','trackPlayback'].every(k => s[k] && typeof s[k] === 'object')) return false;
    if (!Array.from({length:8}, (_,i) => 'Track ' + (i+1)).every(t => Array.isArray(s.recordedParts?.[t]))) return false;
    const ids = new Set(a.media.filter(f => f?.id && !f.unreadable).map(f => f.id));
    return [...audio.prepared, audio.backing?.id, ...Object.values(audio.trackImports || {}).map(i => i.file?.id)].filter(Boolean).every(id => ids.has(id));
  }
  function packageFor(session) {
    const snap = copy(session.snapshot), audio = snap.audioLibrary, all = ctx.files();
    const embedded = [audio.backing, ...Object.values(audio.trackImports || {}).map(i => i.file)].filter(Boolean);
    const ids = [...new Set([...audio.prepared, ...embedded.map(f => f.id)])];
    const media = ids.map(id => all.find(f => f.id === id) || embedded.find(f => f.id === id));
    if (media.some(f => !f || f.unreadable)) return null;
    return {id: 'backup-' + Date.now(), name: session.name, format: 1, created: Date.now(), session: {...copy(session), snapshot:snap}, media:copy(media)};
  }
  function cancel() { clearInterval(timer); timer = null; phase = 'ready'; progress = 0; error = ''; operation = null; show(mode === 'export' ? 'backup:export' : 'backup:restore'); }
  function fail(message) { clearInterval(timer); timer = null; phase = 'error'; error = message; show('backup:retry'); }
  function store(next) { if (!ctx.write(next)) return false; archives = next; return true; }
  function restored(a) {
    const library = copy(ctx.library()), session = copy(a.session), media = copy(a.media), names = [library.current, ...library.sessions];
    let id; do { id = 'session-' + library.nextId++; } while (names.some(s => s.id === id));
    const used = new Set(ctx.files().map(f => f.id)), remap = new Map();
    for (const f of media) { let n = 1, newId = id + '-audio-' + n; while (used.has(newId)) newId = id + '-audio-' + ++n; used.add(newId); remap.set(f.id, newId); f.id = newId; }
    const audio = session.snapshot.audioLibrary;
    audio.prepared = audio.prepared.map(id => remap.get(id));
    const restoredFile = file => file ? copy(media.find(f => f.id === remap.get(file.id))) : null;
    audio.backing = restoredFile(audio.backing);
    for (const value of Object.values(audio.trackImports || {})) value.file = restoredFile(value.file);
    session.id = id; session.name = unique(a.name, names); session.updated = Date.now(); delete session.current;
    session.snapshot.trackPlayback = Object.fromEntries(Object.keys(session.snapshot.recordedParts).map(t => [t,false]));
    library.sessions.unshift(session);
    if (!ctx.restore(library, media)) return false;
    restoredId = id; resultName = session.name; return true;
  }
  function finish() {
    clearInterval(timer); timer = null;
    if (!ctx.usb()) return fail('USB drive disconnected. Nothing was changed.');
    if (failure || full) { const reason = full ? 'Not enough space. Free up space and try again.' : 'The copy could not be completed. Try again.'; failure = false; return fail(reason); }
    if (mode === 'export') {
      const next = copy(archives), a = copy(operation.archive);
      a.id = 'backup-' + Date.now(); a.created = Date.now();
      if (operation.replaceId) { const i = next.findIndex(v => v.id === operation.replaceId); if (i >= 0) next.splice(i,1); }
      a.name = operation.replaceId ? a.name : unique(a.name, next); next.unshift(a);
      if (!store(next)) return fail('The backup could not be saved. The previous copy is unchanged.');
      resultName = a.name; selected = a.id;
    } else {
      if (!valid(operation.archive)) return fail('This backup is incomplete or unreadable. Choose another backup.');
      if (!restored(operation.archive)) return fail('Could not save the restored session. Your Library is unchanged.');
    }
    phase = 'complete'; progress = 100; error = ''; operation = null; if(mode === 'import')ctx.reveal(restoredId); show(mode === 'export' ? 'backup:export' : 'session:load'); ctx.notice(resultName + (mode === 'export' ? ' · Saved to USB' : ' · Restored to Library'));
  }
  function start(replace = false, retry = false) {
    if (busy()) return;
    const reason = blocker(); if (reason) { error = reason; show(); return; }
    let a = retry && operation ? operation.archive : mode === 'export' ? packageFor(source) : copy(chosen() || null);
    if (!a || !valid(a)) { error = mode === 'export' ? 'Some backing audio is unavailable. Reconnect it before backing up.' : 'This backup is incomplete or unreadable. Choose another backup.'; phase = 'error'; operation = null; show(); return; }
    const same = archives.find(v => v.name === a.name);
    if (mode === 'export' && same && !replace && !retry && phase !== 'conflict') { phase = 'conflict'; error = ''; show('backup:keep'); return; }
    operation = {archive:copy(a), replaceId:mode === 'export' && replace ? same?.id : retry ? operation?.replaceId : null};
    phase = 'progress'; error = ''; progress = 0;
    timer = setInterval(() => { if (!ctx.usb()) { fail('USB drive disconnected. Nothing was changed.'); return; } progress += 20; if (progress >= 100) finish(); else show(); }, 300);
    show('backup:cancel');
  }
  function action(id) {
    if (!id.startsWith('backup:')) return false;
    if (id === 'backup:export' && !busy()) { mode='export';source=copy(ctx.selected());phase='ready';error='';operation=null;start(); }
    else if (id === 'backup:restore' && !busy()) {mode='import';phase='ready';error='';operation=null;start();}
    else if (id.startsWith('backup:row:') && !busy()) {selected=id.slice(11);phase='ready';error='';operation=null;show(id);}
    else if (id === 'backup:keep') start();
    else if (id === 'backup:replace') start(true);
    else if (id === 'backup:retry') start(false,true);
    else if (id === 'backup:cancel') cancel();
    return true;
  }
  function usbList() {
    const reason=blocker() || (chosen()&&!valid(chosen())?'This backup is incomplete or unreadable. Choose another backup.':'');
    return `<section class="backup-usb-list"><div class="backup-list-heading"><span>Session</span><span>Saved</span></div><div class="backup-scroll">${!ctx.usb()?'<p class="backup-empty">Connect a USB drive to see your backups.</p>':archives.map(a=>button('backup:row:'+a.id,`<span class="backup-row-info"><span class="session-row-title">${esc(a.name)}</span><span class="session-row-meta">${esc(details(a.session))}</span></span><span class="backup-row-date">${new Date(a.created).toLocaleDateString('en-GB',{day:'numeric',month:'short'})}</span>`,'backup-row '+(selected===a.id?'selected':''),`aria-pressed="${selected===a.id}" ${busy()?'disabled':''}`)).join('') || '<p class="backup-empty">No session backups on this drive.</p>'}</div></section>${busy()?notice():`<div class="backup-restore-actions"><span>${esc(error||reason||'Adds a new session to Library.')}</span>${button('backup:restore','Restore to Library','primary',!chosen()||reason||busy()?'disabled':'')}</div>`}`;
  }
  function notice() {
    if (phase==='progress') return `<div class="backup-inline" role="status"><span>${mode==='export'?'Backing up':'Restoring'} ${esc(operation.archive.name)}…</span><div class="backup-progress" role="progressbar" aria-label="Copy progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${progress}"><span style="width:${progress}%"></span></div>${button('backup:cancel','Cancel')}</div>`;
    return '';
  }
  function overlay() {
    let content = '';
    if (phase === 'conflict') content = `<h2>A backup has this name</h2><p>${esc(source.name)}</p><div class="actions">${button('backup:cancel','Cancel')}${button('backup:keep','Keep both','primary')}${button('backup:replace','Replace')}</div>`;
    if (phase !== 'conflict' && error) content = `<h2>${mode === 'export' ? 'Backup' : 'Restore'} interrupted</h2><p role="alert">${esc(error)}</p><div class="actions">${button('backup:cancel','Cancel')}${operation?button('backup:retry','Retry','primary',blocker()?'disabled':''):''}</div>`;
    return content ? `<div class="overlay"><section class="dialog backup-dialog" role="dialog" aria-modal="true">${content}</section></div>` : '';
  }
  function mediaChanged() { if (!ctx.usb() && busy()) fail('USB drive disconnected. Nothing was changed.'); else show(); }
  function fixture(scene) {
    const s=copy(ctx.selected());s.name='Evening loop';
    if(!s.snapshot.audioLibrary.prepared.length)s.snapshot.audioLibrary.prepared=ctx.files().slice(0,2).map(f=>f.id);
    const a=packageFor(s);a.id='backup-example';
    archives=[a,{...copy(a),id:'backup-other',name:'Acoustic set',session:{...copy(a.session),name:'Acoustic set'}}];selected=a.id;
    source=copy(s);phase='ready';mode=['backup-usb','backup-restored','backup-missing','backup-damaged'].includes(scene)?'import':'export';
    ctx.location(mode==='import'?'usb':'internal');
    if(scene==='backup-copying'){archives=[];start();}
    if(scene==='backup-conflict')phase='conflict';
    if(scene==='backup-recovery'){operation={archive:a};phase='error';error='USB drive disconnected. Nothing was changed.';}
    if(scene==='backup-damaged')archives[0].damaged=true;
    if(scene==='backup-restored'){restored(a);phase='complete';ctx.reveal(restoredId);}
    if(scene==='backup-missing')ctx.disconnect();
  }
  return {action,usbList,notice,overlay,busy,mediaChanged,fixture,
    back:()=>{if(['error','conflict'].includes(phase)){cancel();return true;}return false;},
    initialFocus:()=>phase==='conflict'?'backup:keep':phase==='error'&&operation?'backup:retry':mode==='import'&&chosen()?'backup:row:'+selected:'backup:export',
    beginBrowse:()=>{if(!chosen())selected=archives[0]?.id||null;},
    simulate:v=>{if(v.full!==undefined)full=v.full;if(v.fail!==undefined)failure=v.fail;if(v.archives)archives=copy(v.archives);show();},
    snapshot:()=>copy({mode,phase,error,progress,archives,selected,restoredId,busy:busy()})};
};
