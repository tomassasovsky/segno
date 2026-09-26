// Audio preparation proposal. Files, waveforms and rendering are silent fixtures.
window.createAudioLibraryStudy = function (ctx) {
  const {button, header, icon, escape: esc, render, setFocus} = ctx;
  const clone = value => JSON.parse(JSON.stringify(value));
  const file = (id, name, folder, seconds, format = 'WAV') => ({id, name, folder, seconds, format});
  const internal = [
    file('inside-1', 'Evening lights.wav', 'Backing tracks', 222),
    file('inside-2', 'Acoustic intro.wav', 'Backing tracks', 48),
    file('inside-3', 'Drums — slow groove.wav', 'Backing tracks', 184),
    file('inside-4', 'Piano and strings.wav', 'Backing tracks', 206),
    file('inside-5', 'Chorus harmonies.wav', 'Backing tracks', 32),
    file('inside-6', 'The long way home — instrumental.wav', 'Backing tracks', 257),
    file('inside-7', 'Walking bass.wav', 'Backing tracks', 116),
    file('inside-8', 'Finale.wav', 'Backing tracks', 194),
    {...file('inside-9', 'Yesterday’s loop.wav', 'Saved audio', 24), tempo:120, bars:12, metadataSource:'fixture'},
  ];
  const usb = [
    file('usb-1', 'Evening lights — live version.wav', 'Live set', 228),
    file('usb-2', 'Acoustic intro.wav', 'Live set', 51),
    file('usb-3', 'Drum break.wav', 'Live set', 38),
    file('usb-4', 'Closing song.mp3', 'Live set', 216, 'MP3'),
    {...file('usb-bad', 'Damaged recording.wav', 'Live set', 0), unreadable: true},
  ];
  const initial = () => ({files: clone(internal), usbFiles: clone(usb), backing: null, backingEnd: 'stop', prepared: [], trackImports: {}, nextId: 1});
  const state = () => ctx.read() || initial();
  const commit = value => ctx.write(value);
  let audioQuery = '', view = 'browse', location = 'internal', folder = 'Backing tracks', selected = 'inside-1';
  let position = 0, startedAt = 0;
  let preview = false, playing = false, dialog = null, job = null, timer = null,previewFile=null,previewStarted=0;
  let usbConnected = true, full = false, error = '', lastSaved = null, lastExport = null, selectName = false;
  const scrollPositions = {};
  let draft = {tracks: [], location: 'internal', name: 'Evening loop'};
  let renderOptions={tails:'wrap',mixFx:false};
  const renderPlan=()=>ctx.recipe(draft.tracks,renderOptions);
  let trackImport = null, lastImport = null, destination = null, mixEdit = null, barsEdit = null;
  const mix = () => ({level:1,pan:.5,...ctx.mixRead?.()});
  const db = value => value>0?(20*Math.log10(value)).toFixed(1)+' dB':'−∞ dB';
  const panText = value => Math.abs(value-.5)<.005?'Center':Math.round(Math.abs(value-.5)*200)+(value<.5?' L':' R');
  const importTargets = () => ctx.tracks().map(t=>({...t,imported:state().trackImports?.[t.id],hasAudio:t.hasAudio||!!state().trackImports?.[t.id]}));
  const time = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
  const locationLabel = value => value === 'internal' ? 'Internal' : 'USB drive';
  const preparedFiles = () => (state().prepared || []).map(id=>state().files.find(f=>f.id===id)).filter(Boolean);
  const usbFiles = (s=state(),mediaId=ctx.usbIdentity?.()) => s.usbFiles.filter(f=>!f.storage?.mediaId||f.storage.mediaId===mediaId);
  const files = () => view === 'prepared' ? preparedFiles() : location === 'internal' ? state().files : usbFiles();
  const storageAt = (location,mediaId) => location==='usb'?{location,mediaId}:{location:'internal'};
  const elapsed = () => Math.min(state().backing?.seconds || 0, position + (playing ? (Date.now()-startedAt)/1000 : 0));
  function pause(){position=elapsed();playing=false;}
  function stop(){playing=false;position=0;}
  function play(){if(partError(state().backing)){error=partError(state().backing);return;}if(ctx.audioReady?.()===false){error='Reconnect audio to play.';return;}if(!state().backing)return;if(elapsed()>=state().backing.seconds)position=0;startedAt=Date.now();playing=true;}
  function prepare(s,id){s.prepared ||= [];if(!s.prepared.includes(id))s.prepared.push(id);}
  const chosen = () => files().find(f => f.id === selected);
  const partPlan=f=>f?.performance?window.SegnoPerformanceRecording.manifest(f):null;
  const partError=f=>{
    if(f?.storage?.location==='usb'&&(!usbConnected||f.storage.mediaId!==ctx.usbIdentity?.()))return 'Reconnect the original USB drive to use this recording.';
    if(!f?.performance)return '';
    const plan=partPlan(f);if(plan.error)return plan.error;
    const current=[...state().files,...state().usbFiles].find(item=>item.id===f.id);
    if(!current||JSON.stringify(current.parts)!==JSON.stringify(f.parts)||JSON.stringify(current.performance)!==JSON.stringify(f.performance))return 'The performance parts are unavailable or changed. Choose the recording again.';
    return partPlan(current)?.error||'';
  };
  const partPosition=(f,seconds)=>f?.performance?window.SegnoPerformanceRecording.locate(f,seconds):null;
  const supported = f => !!f && !f.unreadable && !partError(f) && (location !== 'usb' || usbConnected);
  function togglePreview(f){if(partError(f)){error=partError(f);return;}preview=!preview;previewFile=preview?clone(f):null;previewStarted=Date.now();}

  const available = () => ctx.tracks().filter(t => t.hasAudio && !t.capturing);
  const chosenTracks = () => ctx.tracks().filter(t => draft.tracks.includes(t.id));
  const canSave = () => draft.name.trim().length > 0 && draft.tracks.length > 0 && chosenTracks().every(t => t.hasAudio && !t.capturing) && (draft.location !== 'usb' || usbConnected) && !renderPlan().error;
  const paths = {
    folder: 'M3 7V5h7l2 3h9v12H3Z',
    audio: 'M9 18V5l11-2v13M9 8l11-2M9 18a3 3 0 1 1-3-3c2 0 3 1 3 3ZM20 16a3 3 0 1 1-3-3c2 0 3 1 3 3Z',
    play: 'M8 4l12 8-12 8Z', pause: 'M8 4v16M16 4v16', stop: 'M5 5h14v14H5Z',
    drive: 'M5 3h14v18H5ZM8 16h8M8 18h1',
  };
  const pict = name => `<svg class="audio-icon" width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${paths[name]}"/></svg>`;
  const wave = (f, large = false) => `<div class="audio-wave ${large ? 'large' : ''} ${preview || playing ? 'running' : ''}" role="img" aria-label="Illustrative audio waveform">${Array.from({length: 90}, (_, i) => {
    const seed = [...(f?.id || 'audio')].reduce((n, c) => n + c.charCodeAt(0), 0);
    const height = 9 + Math.abs(Math.sin(i * 2.17 + seed) * Math.sin(i * .21 + 1)) * 82;
    return `<span style="height:${height.toFixed(1)}%"></span>`;
  }).join('')}</div>`;
  function show(focus) { render(); if (focus && ctx.active()) setFocus(focus, false, true); }
  function cancelJob() { clearTimeout(timer); timer = null; job = null; }
  function stopPreview() { preview = false;previewFile=null; }
  function navigate(next) { barsEdit=null;mixEdit=null;cancelJob(); stopPreview(); error = ''; dialog = null; view = next; }
  function browseLocation(value) { audioQuery='';stopPreview(); location = value; folder = ''; selected = null; error = ''; }
  const tabs = (prefix, value) => `<div class="audio-locations" role="group" aria-label="Storage location">${['internal', 'usb'].map(key => button(prefix + key, locationLabel(key), 'quiet ' + (value === key ? 'selected' : ''), `aria-pressed="${key === value}"`)).join('')}</div>`;
  function previewPanel() {
    const f = chosen();
    if (!f || location === 'usb' && !usbConnected) return `<aside class="audio-preview empty"><div class="audio-empty-wave">${wave(null)}</div><h2>Choose your audio</h2><p>Preview it, then use it as a backing track.</p></aside>`;
    return `<aside class="audio-preview"><div class="audio-file-kind">${esc(f.format)} <span>${f.seconds ? time(f.seconds) : 'Unreadable'}</span></div><h2>${esc(f.name)}</h2>${f.performance?`<p>${f.parts?.length||0} parts · One take</p>`:''}${wave(f)}<div class="audio-preview-controls">${button('audio:preview', pict(preview ? 'stop' : 'play') + `<span>${preview ? 'Stop preview' : 'Preview'}</span>`, 'quiet icon-label', `aria-pressed="${preview}" ${supported(f) ? '' : 'disabled'}`)}</div><div class="audio-preview-load">${f.unreadable||partError(f) ? '<p class="audio-error">This recording or one of its parts cannot be read. Choose another recording.</p>' : location === 'usb' ? '<p>Copies to Internal, so you can unplug the drive.</p>' : ''}${error ? `<p class="audio-error" role="alert">${esc(error)}</p>` : ''}<div class="audio-file-actions">${view==='prepared'?button('audio:unprepare','Remove from prepared','quiet'):button('audio:prepare',(state().prepared||[]).includes(f.id)?'Prepared':'Add to prepared','quiet',supported(f)&&!(state().prepared||[]).includes(f.id)?'':'disabled')}${location==='internal'?button('audio:export-usb','Export to USB','quiet',supported(f)?'':'disabled'):''}</div><div class="audio-use-actions">${button('audio:load', 'Use as backing', 'primary', supported(f) ? '' : 'disabled')}${button('audio:load-track',destination!==null?'Import into '+esc(ctx.tracks().find(t=>t.id===destination)?.label):'Use in loop','quiet',supported(f)?'':'disabled')}</div></div></aside>`;
  }
  function browseBody() {
    const prepared = view === 'prepared';
    const folders = [...new Set(files().map(f => f.folder))];
    const list = (prepared ? preparedFiles() : folder ? files().filter(f => f.folder === folder) : audioQuery ? files() : []).filter(f=>f.name.toLowerCase().includes(audioQuery.toLowerCase()));
    return header(destination!==null?'Import into '+esc(ctx.tracks().find(t=>t.id===destination)?.label):prepared?'Prepared audio':'Audio library', '', `<div class="audio-heading-actions">${destination!==null?button('audio:cancel-entry','Cancel'):''}${prepared?button('audio:perform','Perform','primary',preparedFiles().length?'':'disabled'):button('audio:prepared','Prepared audio')}${state().backing ? button('audio:backing', 'Backing track') : ''}${button('audio:save', 'Save audio')}${!prepared?button('recorder:open','Record performance'):''}</div>`) + (prepared?'':`<div class="audio-browse-tools">${tabs('audio:location:', location)}${button('audio:search',esc(audioQuery)||'Search audio','quiet')}${audioQuery?button('audio:clear-search','Clear','quiet'):''}</div>`) + `<div class="audio-browser"><section class="audio-files"><div class="audio-path">${folder ? button('audio:up', icon('left'), 'quiet icon-only', 'aria-label="Parent folder"') : pict('drive')}<h2>${esc(prepared?'Performance order':folder || (location === 'internal' ? 'Your audio' : 'USB audio'))}</h2>${prepared?`<div class="audio-order-controls" role="group" aria-label="Reorder selected recording">${button('audio:earlier',icon('up')+'<span>Move up</span>','quiet icon-label',!selected||preparedFiles()[0]?.id===selected?'disabled':'')}${button('audio:later',icon('arrowDown')+'<span>Move down</span>','quiet icon-label',!selected||preparedFiles().at(-1)?.id===selected?'disabled':'')}</div>`:''}</div><div class="audio-scroll" data-path="${esc(location+'/'+folder)}" role="region" aria-label="Audio files">${location === 'usb' && !usbConnected ? `<div class="audio-no-drive">${pict('drive')}<h2>Connect a USB drive</h2><p>Your internal audio is still available.</p></div>` : !folder && !prepared && !audioQuery ? folders.map(name => button('audio:folder:' + encodeURIComponent(name), `${pict('folder')}<span class="audio-row-name">${esc(name)}</span>${icon('right')}`, 'audio-file folder')).join('') : list.length ? list.map((f,index) => button('audio:file:' + f.id, `${prepared?`<span class="audio-order-number">${index+1}</span>`:pict('audio')}<span class="audio-row-name">${esc(f.name)}</span><span class="audio-row-time">${f.seconds ? time(f.seconds) : '—'}</span>`, 'audio-file ' + (selected === f.id ? 'selected' : ''), `aria-pressed="${selected === f.id}"`)).join('') : '<div class="audio-no-drive"><h2>No audio here yet</h2></div>'}</div></section>${previewPanel()}</div>`;
  }
  function saveBody() {
    const tracks = ctx.tracks();
    return header('Save audio', '', button('audio:cancel-save', 'Cancel')) + `<div class="audio-save-layout"><section class="audio-save-sources"><div class="audio-source-heading"><h2>Tracks</h2>${button('audio:all-tracks', 'Select all', 'quiet')}</div><div class="audio-save-tracks">${tracks.map(t => button('audio:track:' + t.id, `<span class="audio-track-number">${t.id + 1}</span><span>${esc(t.label)}</span><span class="audio-track-check">${draft.tracks.includes(t.id) ? icon('check') : ''}</span>`, 'audio-save-track ' + (draft.tracks.includes(t.id) ? 'selected' : ''), `aria-pressed="${draft.tracks.includes(t.id)}" ${t.hasAudio && !t.capturing ? '' : 'disabled'}`)).join('')}</div><p class="audio-save-description">One audio file, with the selected tracks and their effects.</p>${tracks.some(t => t.capturing) ? '<p class="audio-error">Finish recording before saving that track.</p>' : ''}</section><section class="audio-save-details"><div><h2>Save to</h2>${tabs('audio:save-location:', draft.location)}<p class="audio-save-folder">Saved audio</p></div>${window.SegnoSelectedRender.controls({button,prefix:'audio:render:',options:renderOptions,plan:renderPlan(),beatsPerBar:beatsPerBar(timing().signature)})}<div><h2>File name</h2>${button('audio:name', `<span>${esc(draft.name || 'Name your audio')}</span><span class="audio-extension">.wav</span>`, 'audio-name-field')}</div><div class="audio-save-commit">${draft.location === 'usb' && !usbConnected ? '<p class="audio-error" role="alert">Connect a USB drive or choose Internal.</p>' : ''}${error ? `<p class="audio-error" role="alert">${esc(error)}</p>` : ''}${button('audio:commit-save', 'Save audio', 'primary', canSave() ? '' : 'disabled')}</div></section></div>`;
  }
  function timing() {
    const source=ctx.timing?.() || {};
    return {tempo:84,signature:'4/4',mode:'sync',hasAudio:importTargets().some(t=>t.hasAudio),external:false,clockStatus:'internal',...source};
  }
  function importPlan(draft=trackImport) {
    const clock=timing(), f=draft?.file, policy=clock.external?'adapt':draft?.policy||'unchanged';
    const sourceTempo=draft?.confirmedBars?draft.confirmedBars*beatsPerBar(clock.signature)*60/f.seconds:Number(f?.tempo)||null;
    const mediaError=partError(f);let reason='';
    if(!f || f.unreadable || !(f.seconds>0))reason='This file cannot be read.';
    else if(mediaError)reason=mediaError;
    else if(clock.external && clock.clockStatus!=='synced')reason='Wait for a stable MIDI clock before importing.';
    else if(policy!=='unchanged'&&!sourceTempo)reason='Confirm the number of bars to set the file tempo.';
    else if(policy==='file' && sourceTempo && (sourceTempo<30||sourceTempo>300))reason='The loop tempo must be between 30 and 300 BPM. Adapt this file or leave it unchanged.';
    else if(policy==='file'&&clock.hasAudio&&Math.abs(sourceTempo-clock.tempo)>.01)reason='Existing tracks keep their timing. Adapt this file or leave it unchanged.';
    const loopTempo=policy==='file'?sourceTempo:clock.tempo;
    return {policy,sourceTempo,sourceTempoOrigin:draft?.confirmedBars?'user-bar-count':sourceTempo?f.metadataSource||'file-metadata':null,
      sourceBars:draft?.confirmedBars||Number(f?.bars)||null,bars:policy==='unchanged'?f?.seconds*clock.tempo/(beatsPerBar(clock.signature)*60):sourceTempo?f.seconds*sourceTempo/(beatsPerBar(clock.signature)*60):null,signature:clock.signature,loopTempo,
      sourceSeconds:f?.seconds,seconds:policy==='adapt'&&sourceTempo?f.seconds*sourceTempo/clock.tempo:f?.seconds,
      tempoChange:policy==='file'&&sourceTempo!==clock.tempo?sourceTempo:null,external:clock.external,clockStatus:clock.clockStatus,
      timingVersion:JSON.stringify(clock),sourcePreserved:true,processing:'simulated',reason};
  }
  function beatsPerBar(signature){const [n,d]=signature.split('/').map(Number);return n*4/d;}
  function beginTrackImport() {
    const f=chosen();if(!supported(f))return;
    trackImport={file:clone(f),location,mediaId:location==='usb'?ctx.usbIdentity?.():null,target:destination,policy:timing().external?'adapt':'unchanged',barsDraft:f.bars||4,confirmedBars:null};
    navigate('track-import');show(destination!==null?'audio:timing:unchanged':'audio:import-target:'+importTargets().find(t=>!t.hasAudio&&!t.capturing)?.id);
  }
  function timingBody() {
    const plan=importPlan(), clock=timing(), known=plan.sourceTempo;
    return `<div class="audio-import-timing"><div class="audio-timing-meta"><span>File tempo</span><strong>${known?+known.toFixed(2)+' BPM':'Unknown'}</strong><small>${plan.sourceTempoOrigin==='fixture'?'Example metadata':plan.sourceTempoOrigin==='user-bar-count'?'From your bar count':known?'File metadata':'No tempo metadata'}</small></div><div class="audio-timing-choices" role="group" aria-label="Import timing">${[['file','Use file tempo','Set this loop to the file tempo'],['adapt','Adapt to loop tempo',clock.tempo+' BPM · keep original pitch'],['unchanged','Leave unchanged','Original duration and pitch']].map(([id,title,hint])=>button('audio:timing:'+id,`<strong>${title}</strong><span>${hint}</span>`,'quiet '+(plan.policy===id?'selected':''),`aria-pressed="${plan.policy===id}" ${clock.external&&id!=='adapt'?'disabled':''}`)).join('')}</div>${clock.external?'<p>MIDI clock owns the loop tempo.</p>':''}${plan.policy!=='unchanged'?`<div class="audio-bar-count"><span>Bars in the file · ${esc(clock.signature)}</span><div>${button('audio:bars:down','−','quiet','aria-label="Fewer bars" '+(trackImport.barsDraft<=1?'disabled':''))}${button('audio:bars-value',String(trackImport.barsDraft),'quiet '+(barsEdit?'editing':''),'aria-label="Bars in the file"')}${button('audio:bars:up','+','quiet','aria-label="More bars" '+(trackImport.barsDraft>=1024?'disabled':''))}${button('audio:confirm-bars',trackImport.confirmedBars===trackImport.barsDraft?'Confirmed':'Use bar count','quiet')}</div>${button('audio:import-preview',preview?'Stop preview':'Preview file','quiet',supported(trackImport.file)?'':'disabled')}</div>`:''}<p>${plan.policy==='adapt'?(known?'Imported copy: '+time(plan.seconds||0)+' · original kept.':'Original file is kept.'):plan.policy==='file'?'The file keeps its original duration.':'Loads stopped at its original speed.'}</p>${plan.reason?`<p class="audio-error" role="alert">${esc(plan.reason)}</p>`:''}</div>`;
  }
  function trackImportBody() {
    const f=trackImport.file, targets=importTargets(), selectedTarget=targets.find(t=>t.id===trackImport.target), connected=trackImport.location!=='usb'||usbConnected, plan=importPlan(), valid=selectedTarget&&!selectedTarget.hasAudio&&!selectedTarget.capturing&&connected&&!plan.reason;
    return header('Import audio','',button('audio:cancel-track-import','Cancel'))+`<div class="audio-track-import"><section class="audio-import-source"><div class="audio-file-kind">${esc(f.format)} <span>${time(f.seconds)}</span></div><h2>${esc(f.name)}</h2>${timingBody()}${trackImport.location==='usb'?'<p>Copies from USB into Internal.</p>':''}</section><section class="audio-import-destination"><h2>Choose an empty track</h2><div class="audio-import-tracks">${targets.map(t=>button('audio:import-target:'+t.id,`<span class="audio-track-number">${t.id+1}</span><span>${esc(t.label)}<small>${t.capturing?'Recording':t.hasAudio?'Contains audio':'Empty'}</small></span>${t.id===trackImport.target?icon('check'):''}`,'audio-import-track '+(t.id===trackImport.target?'selected':''),`aria-pressed="${t.id===trackImport.target}" ${t.hasAudio||t.capturing?'disabled':''}`)).join('')}</div>${!connected?'<p class="audio-error" role="alert">Connect the USB drive to load this audio.</p>':''}${error?`<p class="audio-error" role="alert">${esc(error)}</p>`:''}${!targets.some(t=>!t.hasAudio&&!t.capturing)?'<p class="audio-error">No empty tracks. Existing loops are kept.</p>':''}${button('audio:commit-track-import',valid?'Load into '+esc(selectedTarget.label):'Load audio','primary',valid?'':'disabled')}</section></div>`;
  }
  function importedBody() {
    return header('Audio loaded','')+`<section class="audio-saved"><div class="audio-saved-mark">${icon('check')}</div><h2>${esc(lastImport.file.name)}</h2><p>${esc(ctx.tracks().find(t=>t.id===lastImport.target)?.label)} · ${time(lastImport.timing?.seconds||lastImport.file.seconds)} · Stopped</p><div class="audio-saved-actions">${button('audio:import-more','Choose more audio')}${button('stage','Tracks','primary')}</div></section>`;
  }
  function backingBody() {
    const f = state().backing;
    return header('Backing track', '', `<div class="audio-heading-actions">${button('audio:browse','Choose audio')}${f?button('audio:clear','Clear backing','quiet'):''}</div>`) + (f ? `<section class="audio-player"><div class="audio-player-file"><span class="audio-file-kind">${esc(f.format)} · ${time(f.seconds)}</span><h2>${esc(f.name)}</h2></div>${wave(f, true)}<div class="audio-player-time"><span>${time(elapsed())}</span><span>${time(f.seconds)}</span></div>${mixBody()}<div class="audio-player-actions">${button('audio:stop', pict('stop') + '<span>Stop</span>', 'quiet icon-label')}${button('audio:play', pict(playing ? 'pause' : 'play') + `<span>${playing ? 'Pause' : 'Play'}</span>`, 'primary icon-label', `aria-pressed="${playing}"`)}</div></section>` : '<div class="audio-no-drive"><h2>Choose a backing track</h2></div>');
  }
  function savedBody() {
    return header('Audio saved', '') + `<section class="audio-saved"><div class="audio-saved-mark">${icon('check')}</div><h2>${esc(lastSaved.name)}</h2><p>${locationLabel(lastSaved.location)} / Saved audio</p><div class="audio-saved-actions">${button('audio:show-saved', 'Show in library')}${button('audio:use-saved', 'Use as backing', 'primary')}</div></section>`;
  }
  function exportedBody() {
    return header('Exported to USB','')+`<section class="audio-saved"><div class="audio-saved-mark">${icon('check')}</div><h2>${esc(lastExport.name)}</h2><p>USB drive / ${esc(lastExport.folder)}</p><p>Your internal recording is kept.</p><div class="audio-saved-actions">${button('audio:show-export','Show on USB')}${button('audio:export-done','Done','primary')}</div></section>`;
  }
  function exportSelected(choice) {
    const f=chosen();if(location!=='internal'||!supported(f))return;
    if(!usbConnected){dialog={type:'export-drive'};show('audio:dialog-cancel');return;}
    if(choice&&dialog?.mediaId!==ctx.usbIdentity?.()){dialog=null;error='The USB drive changed. Review the destination again.';show();return;}
    const current=usbFiles(),existing=current.find(v=>v.folder===f.folder&&v.name.toLowerCase()===f.name.toLowerCase());
    if(existing&&!choice){dialog={type:'export-replace',name:f.name,mediaId:ctx.usbIdentity?.()};show('audio:dialog-cancel');return;}
    const task={kind:'export',parts:partPlan(f)?.parts||null,source:clone(f),name:choice==='both'?uniqueName(f.name,current,f.folder):f.name,folder:f.folder,location:'usb',returnView:view,replace:choice==='replace'?clone(existing):null};
    dialog=null;startJob(task);
  }
  function progressBody() {
    return header(job.kind==='export'?'Exporting audio':job.kind === 'track-import'?'Loading audio':job.kind === 'import' ? 'Copying audio' : 'Saving audio', button('storage:open','Storage','quiet')) + `<section class="audio-progress"><h2>${esc(job.name)}</h2><p>${job.kind==='export'?'Internal → USB drive / '+esc(job.folder):job.kind==='track-import'?'Into '+esc(ctx.tracks().find(t=>t.id===job.target)?.label):job.kind === 'import' ? 'USB drive → Internal' : 'To ' + locationLabel(job.location) + ' / Saved audio'}</p><div class="audio-progress-track" role="progressbar" aria-label="Audio operation" aria-valuetext="In progress"><span></span></div>${button('audio:cancel-job', 'Cancel')}</section>`;
  }
  function persist(s, returnView) {if(commit(s) !== false)return true;view=returnView;error=returnView==='track-import'?'Audio could not be loaded. Try again.':'Audio could not be saved. Try again.';show();return false;}
  function loadInternal(f) { if(partError(f)){error=partError(f);show();return;}const s = clone(state()); s.backing = clone(f);prepare(s,f.id);if(!persist(s,'browse'))return; stop(); navigate('backing'); show('audio:play'); }
  function uniqueName(name, list, targetFolder) {
    let candidate = name, i = 2;
    while (list.some(f => f.folder === targetFolder && f.name.toLowerCase() === candidate.toLowerCase())) candidate = name.replace(/(\.[^.]+)$/, ` (${i++})$1`);
    return candidate;
  }
  function startJob(operation) {
    const needsUsb=operation.kind==='import'||operation.location==='usb',mediaId=ctx.usbIdentity?.();
    if(needsUsb&&(!usbConnected||!mediaId||ctx.allowUsb?.()===false)){error='Reconnect the USB drive and wait for it to be available.';show();return;}
    const sourceMediaId=operation.sourceMediaId||((operation.kind==='import'||operation.kind==='track-import')?operation.source.storage?.mediaId:null);
    if(needsUsb&&sourceMediaId&&sourceMediaId!==mediaId){error='The USB drive changed. Choose the source again.';show();return;}
    stopPreview(); error = ''; job = {...operation,mediaId:needsUsb?mediaId:null}; view = 'progress'; show('audio:cancel-job');
    timer = setTimeout(() => {
      if (!job) return;
      const task = job; cancelJob();
      const needsUsb = task.kind === 'import' || task.location === 'usb';
      if (needsUsb && (!usbConnected||ctx.usbIdentity?.()!==task.mediaId||ctx.allowUsb?.()===false)) {view = task.returnView; error = 'The USB drive changed or is unavailable. Nothing was saved.'; show(); return;}
      if (full) {view = task.returnView; error = 'Not enough space. Free up storage and try again.'; show(); return;}
      const s = clone(state());
      if(task.kind==='export') {
        const original=s.files.find(f=>f.id===task.source.id);
        const existing=usbFiles(s,task.mediaId).find(f=>f.folder===task.folder&&f.name.toLowerCase()===task.name.toLowerCase());
        if(JSON.stringify(original)!==JSON.stringify(task.source)){view=task.returnView;error='The recording changed. Try exporting again.';show();return;}
        if(JSON.stringify(existing||null)!==JSON.stringify(task.replace||null)){view=task.returnView;error='That name is now in use on USB. Try exporting again.';show();return;}
        const plan=partPlan(original);if(plan?.error||JSON.stringify(plan?.parts||null)!==JSON.stringify(task.parts)){view=task.returnView;error='The performance parts changed. Try exporting again.';show();return;}
        const asset={...clone(task.source),id:task.replace?.id||'usb-export-'+s.nextId++,name:task.name,folder:task.folder,storage:storageAt('usb',task.mediaId)};
        if(plan)asset.parts=plan.parts.map(({offsetFrames,...part})=>part);
        s.usbFiles=s.usbFiles.filter(f=>f.id!==asset.id).concat(asset);
        if(!persist(s,task.returnView))return;
        lastExport={...clone(asset),sourceId:task.source.id,returnView:task.returnView};view='exported';show('audio:export-done');
      } else if(task.kind==='track-import') {
        const target=importTargets().find(t=>t.id===task.target);
        if(!target||target.hasAudio||target.capturing){view='track-import';error='That track is no longer empty. Choose another track.';show();return;}
        const currentPlan=importPlan({...trackImport,file:task.source});
        if(currentPlan.reason||JSON.stringify(currentPlan)!==JSON.stringify(task.timing)){view='track-import';error=currentPlan.reason||'Loop timing changed. Review the import settings and try again.';show();return;}
        const source=(task.location==='usb'?usbFiles(s,task.mediaId):s.files).find(f=>f.id===task.source.id);
        if(JSON.stringify(source)!==JSON.stringify(task.source)){view='track-import';error='The source file changed. Choose it again.';show();return;}
        let asset=clone(task.source);
        if(task.location==='usb'){
          asset={...asset,id:'saved-'+s.nextId++,importedFrom:task.source.id,folder:'Imported audio',storage:storageAt('internal')};
          asset.name=uniqueName(asset.name,s.files,asset.folder);s.files.push(asset);
        }
        const imported={file:asset,state:'stopped',speed:1,sourceLocation:'internal',originalSourceLocation:task.location,timing:clone(task.timing)};
        (s.trackImports ||= {})[task.target]=imported;
        // One host transaction publishes the descriptor and an optional new loop tempo.
        const ok=ctx.commitImport?ctx.commitImport(s,{target:task.target,...clone(imported)}):task.timing.tempoChange?false:commit(s);
        if(ok===false){view='track-import';error='Audio could not be loaded. Your loop is unchanged.';show();return;}
        lastImport={target:task.target,file:clone(asset),timing:clone(task.timing)};destination=null;view='imported';show('stage');
      } else if (task.kind === 'import') {
        const current=usbFiles(s,task.mediaId).find(f=>f.id===task.source.id);
        if(JSON.stringify(current)!==JSON.stringify(task.source)||partError(current)){view=task.returnView;error='The source recording changed or its parts are unavailable. Choose it again.';show();return;}
        let asset = s.files.find(f => f.importedFrom === task.source.id);
        if (asset?.performance&&JSON.stringify(asset.parts)!==JSON.stringify(task.source.parts))asset=null;
        if (!asset) {asset = {...clone(task.source), id: 'saved-' + s.nextId++, importedFrom: task.source.id, folder: 'Backing tracks',storage:storageAt('internal')};asset.name = uniqueName(asset.name, s.files, asset.folder);s.files.push(asset);}
        prepare(s,asset.id);if(!task.prepareOnly)s.backing = clone(asset); if(!persist(s,'browse'))return; location = 'internal'; folder = asset.folder; selected = asset.id;if(task.prepareOnly){view='browse';show('audio:prepared');}else{stop();view='backing';show('audio:play');}
      } else {
        const now = ctx.tracks();
        if (task.tracks.some(id => !now.find(t => t.id === id)?.hasAudio || now.find(t => t.id === id)?.capturing) || JSON.stringify(ctx.recipe(task.tracks,task.renderOptions)) !== JSON.stringify(task.recipe)) {view = 'save'; error = 'The selected tracks changed. Try saving again.'; show(); return;}
        const key = task.location === 'internal' ? 'files' : 'usbFiles';
        const existing = (task.location==='usb'?usbFiles(s,task.mediaId):s.files).find(f => f.folder === 'Saved audio' && f.name.toLowerCase() === task.name.toLowerCase());
        if (existing && existing.id !== task.replaceId) {view = 'save';error = 'That name is now in use. Choose another name.';show();return;}
        const asset = {id: task.replaceId || 'saved-' + s.nextId++, name: task.name, folder: 'Saved audio', seconds: task.recipe.seconds, format: 'WAV', recipe: task.recipe,storage:storageAt(task.location,task.mediaId)};
        s[key] = s[key].filter(f => f.id !== asset.id).concat(asset); if(!persist(s,'save'))return; lastSaved = {...clone(asset), location: task.location}; view = 'saved'; show('audio:use-saved');
      }
    }, 1400);
  }
  function loadSelected(confirmed = false) {
    const f = chosen(); if (!supported(f)) return;
    if (playing && !confirmed) {dialog = {type: 'load', name: f.name}; stopPreview(); show('audio:dialog-cancel'); return;}
    if (location === 'usb') startJob({kind: 'import', source: clone(f), name: f.name, location: 'internal', returnView: 'browse'});
    else loadInternal(f);
  }
  function beginSave() {navigate('save');renderOptions={tails:'wrap',mixFx:false}; draft = {tracks: available().map(t => t.id), location: 'internal', name: 'Evening loop'}; show('audio:name');}
  function saveSelected(replaceId) {
    if (!canSave()) return;
    const name = draft.name.trim() + '.wav';
    if(replaceId&&draft.location==='usb'&&dialog?.mediaId!==ctx.usbIdentity?.()){dialog=null;error='The USB drive changed. Review the destination again.';show();return;}
    const existing = (draft.location === 'internal' ? state().files : usbFiles()).find(f => f.folder === 'Saved audio' && f.name.toLowerCase() === name.toLowerCase());
    if (existing && !replaceId) {dialog = {type: 'replace', name, id: existing.id,mediaId:draft.location==='usb'?ctx.usbIdentity?.():null};show('audio:dialog-cancel');return;}
    dialog = null;
    startJob({kind: 'save', tracks: [...draft.tracks], renderOptions:clone(renderOptions),recipe: clone(renderPlan()), name, location: draft.location, replaceId, returnView: 'save'});
  }
  function editName(key) {
    if (key === 'clear') {dialog.name = ''; selectName = false;}
    else if (key === 'delete') {dialog.name = selectName ? '' : dialog.name.slice(0, -1); selectName = false;}
    else {const c = key === 'space' ? ' ' : key; if (!/^[a-zA-Z0-9 _-]$/.test(c)) return;dialog.name = (selectName ? '' : dialog.name) + c;dialog.name = dialog.name.slice(0, 64); selectName = false;}
    show();
  }
  function addPrepared() {
    const f=chosen();if(!supported(f))return;
    if(location==='usb'){startJob({kind:'import',source:clone(f),name:f.name,location:'internal',returnView:'browse',prepareOnly:true});return;}
    const s=clone(state());prepare(s,f.id);if(persist(s,view))show('audio:prepared');
  }
  function mixBody() {
    const m=mix();return `<div class="audio-backing-mix" role="group" aria-label="Backing mix">${['level','pan'].map(key=>`<div><span>${key==='level'?'Level':'Pan'}</span>${button('audio:mix:'+key,`<strong>${key==='level'?db(m[key]):panText(m[key])}</strong>`,'quiet '+(mixEdit?.key===key?'editing':''),`aria-label="Backing ${key}" aria-pressed="${mixEdit?.key===key}"`)}${button('audio:mix-down:'+key,'−','quiet',`aria-label="Decrease backing ${key}"`)}${button('audio:mix-up:'+key,'+','quiet',`aria-label="Increase backing ${key}"`)}${button('audio:mix-reset:'+key,key==='level'?'Unity':'Center','quiet')}</div>`).join('')}</div>`;
  }
  function setMix(key,value) {
    if(!['level','pan'].includes(key)||!Number.isFinite(Number(value)))return false;
    if(!ctx.mixWrite || ctx.mixWrite(key,Math.max(0,Math.min(1,Number(value))))===false){error='The backing mix could not be saved. Try again.';return false;}
    error='';return true;
  }
  function performanceCommand(action,id) {
    error='';stopPreview();
    if(action==='stop'){stop();return;}
    if(action==='level'||action==='pan'){setMix(action,id);return;}
    if(action==='clear'){const s=clone(state());s.backing=null;if(commit(s)===false){error='The backing track could not be cleared.';return;}stop();return;}
    if(action==='rewind'||action==='forward'){performanceCommand('seek',elapsed()+(action==='rewind'?-10:10));return;}
    if(action==='previous'||action==='next'){
      const list=preparedFiles(),index=list.findIndex(f=>f.id===state().backing?.id),next=list[index+(action==='previous'?-1:1)];
      if(!next){error='No '+action+' prepared recording.';return;}
      if(next.unreadable||!next.seconds||partError(next)){error='This recording cannot be read.';return;}
      const s=clone(state());s.backing=clone(next);if(commit(s)===false){error='The backing track could not be loaded.';return;}stop();return;
    }
    if(action==='seek'){if(partError(state().backing)){error=partError(state().backing);pause();return;}if(!state().backing||!Number.isFinite(Number(id)))return;position=Math.max(0,Math.min(state().backing.seconds,Number(id)));startedAt=Date.now();return;}
    if(action==='end'){if(!['stop','repeat','next'].includes(id))return;const s=clone(state());s.backingEnd=id;if(commit(s)===false)error='The playback setting could not be saved. Try again.';return;}
    if(action!=='play')return;
    if(id&&id!==state().backing?.id){const f=preparedFiles().find(f=>f.id===id);if(!f)return;if(partError(f)){error=partError(f);return;}const s=clone(state());s.backing=clone(f);if(commit(s)===false){error='Audio could not be loaded. Try again.';return;}stop();play();}
    else if(playing)pause();else play();
  }
  function action(id) {
    if (!id?.startsWith('audio:')) return false;
    if(id.startsWith('audio:render:')){renderOptions=window.SegnoSelectedRender.adjust(renderOptions,id.slice(13),renderPlan(),beatsPerBar(timing().signature));show(id);return true;}
    const value = id.split(':').slice(2).join(':');
    if(id==='audio:export-usb'||id==='audio:export-retry')exportSelected();
    else if(id==='audio:export-replace')exportSelected('replace');
    else if(id==='audio:export-both')exportSelected('both');
    else if(id==='audio:show-export'){navigate('browse');location='usb';folder=lastExport.folder;selected=lastExport.id;show('audio:file:'+selected);}
    else if(id==='audio:export-done'){navigate(lastExport.returnView);location='internal';selected=lastExport.sourceId;folder=lastExport.returnView==='prepared'?'':lastExport.folder;show('audio:file:'+selected);}
    else if(id==='audio:search'){dialog={type:'name',purpose:'search',name:audioQuery};selectName=true;show('audio:key:Q');}
    else if(id==='audio:clear-search'){audioQuery='';show('audio:search');}
    else if(id==='audio:prepare')addPrepared();
    else if(id==='audio:prepared'){navigate('prepared');location='internal';folder='';selected=preparedFiles()[0]?.id;show('audio:perform');}
    else if(id==='audio:load-track')beginTrackImport();
    else if(id.startsWith('audio:timing:')){if(['file','adapt','unchanged'].includes(value)&&(!timing().external||value==='adapt')){trackImport.policy=value;error='';show(id);}}
    else if(id==='audio:bars-value'){barsEdit=barsEdit?null:{value:trackImport.barsDraft,confirmed:trackImport.confirmedBars};show(id);}
    else if(id.startsWith('audio:bars:')){trackImport.barsDraft=Math.max(1,Math.min(1024,trackImport.barsDraft+(value==='up'?1:-1)));trackImport.confirmedBars=null;show(id);}
    else if(id==='audio:confirm-bars'){trackImport.confirmedBars=trackImport.barsDraft;error='';show(id);}
    else if(id==='audio:import-preview'){if(ctx.audioReady?.()===false){error='Reconnect audio to preview.';}else if(trackImport.location==='usb'&&(!usbConnected||ctx.allowUsb?.()===false)){error='Reconnect the USB drive to preview.';}else{pause();togglePreview(trackImport.file);}show(id);}
    else if(id==='audio:cancel-entry'){destination=null;navigate('browse');ctx.returnToTrack?.();show();}
    else if(id.startsWith('audio:import-target:')){const t=importTargets().find(t=>t.id===Number(value));if(t&&!t.hasAudio&&!t.capturing){trackImport.target=t.id;error='';show(id);}}
    else if(id==='audio:commit-track-import'){const t=importTargets().find(t=>t.id===trackImport?.target);if(t&&!t.hasAudio&&!t.capturing&&!importPlan().reason)startJob({kind:'track-import',timing:clone(importPlan()),source:clone(trackImport.file),sourceMediaId:trackImport.mediaId,name:trackImport.file.name,location:trackImport.location,target:t.id,returnView:'track-import'});}
    else if(id==='audio:cancel-track-import'||id==='audio:import-more'){navigate('browse');show('audio:load-track');}
    else if(id==='audio:perform'){if(preparedFiles().length)ctx.perform();}
    else if(['audio:earlier','audio:later','audio:unprepare'].includes(id)){const s=clone(state()),ids=s.prepared,index=ids.indexOf(selected);if(index>=0){if(id==='audio:unprepare'){ids.splice(index,1);}else{const to=index+(id==='audio:earlier'?-1:1);if(to<0||to>=ids.length)return true;[ids[index],ids[to]]=[ids[to],ids[index]];}if(persist(s,'prepared')){if(id==='audio:unprepare')selected=ids[Math.min(index,ids.length-1)]||null;const to=ids.indexOf(selected),focus=id==='audio:earlier'&&to===0?'audio:later':id==='audio:later'&&to===ids.length-1?'audio:earlier':id;show(focus);document.querySelector('[data-action="audio:file:'+selected+'"]')?.scrollIntoView({block:'nearest'});}}}
    else if (id.startsWith('audio:location:')) {browseLocation(value);show(id);}
    else if (id.startsWith('audio:folder:')) {folder = decodeURIComponent(value);selected = null;stopPreview();show('audio:up');}
    else if (id.startsWith('audio:file:')) {stopPreview();selected = value;error = '';show(id);}
    else if (id === 'audio:up') {const previous=folder;folder = '';selected = null;stopPreview();show('audio:folder:'+encodeURIComponent(previous));}
    else if (id === 'audio:preview') {if(location==='usb'&&ctx.allowUsb?.()===false){error='USB drive is ejecting.';show(id);}else if(ctx.audioReady?.()===false){error='Reconnect audio to preview.';show(id);}else if (supported(chosen())) {pause();togglePreview(chosen());show(id);}}
    else if (id === 'audio:load') loadSelected();
    else if (id === 'audio:load-confirm') {dialog = null;loadSelected(true);}
    else if (id === 'audio:save') beginSave();
    else if (id === 'audio:backing') {navigate('backing');show('audio:play');}
    else if (id === 'audio:browse' || id === 'audio:cancel-save') {navigate('browse');show();}
    else if (id.startsWith('audio:track:')) {const t = ctx.tracks().find(t => t.id === Number(value));if(t?.hasAudio && !t.capturing){draft.tracks = draft.tracks.includes(t.id) ? draft.tracks.filter(i => i !== t.id) : [...draft.tracks, t.id].sort((a,b)=>a-b);show(id);}}
    else if (id === 'audio:all-tracks') {draft.tracks = available().map(t => t.id);show(id);}
    else if (id.startsWith('audio:save-location:')) {draft.location = value;error = '';show(id);}
    else if (id === 'audio:name') {dialog = {type: 'name', name: draft.name};selectName = true;show('audio:key:Q');}
    else if (id === 'audio:name-select') {selectName = true;show(id);}
    else if (id.startsWith('audio:key:')) editName(value);
    else if (id === 'audio:name-done') {if(dialog.purpose==='search'){audioQuery=dialog.name.trim();selected=files().find(f=>(!folder||f.folder===folder)&&f.name.toLowerCase().includes(audioQuery.toLowerCase()))?.id||null;dialog=null;show('audio:search');}else if(dialog.name.trim()){draft.name = dialog.name.trim();dialog = null;error = '';show('audio:name');}}
    else if (id === 'audio:dialog-cancel') {const prior=dialog;dialog=null;error='';show(prior?.purpose==='search'?'audio:search':prior?.type==='clear-backing'?'audio:clear':prior?.type.startsWith('export-')?'audio:export-usb':view==='save'?'audio:name':'audio:load');}
    else if (id === 'audio:commit-save') saveSelected();
    else if (id === 'audio:replace') saveSelected(dialog.id);
    else if (id === 'audio:rename') {dialog = {type: 'name', name: draft.name};selectName = true;show('audio:key:Q');}
    else if (id === 'audio:cancel-job') {const previous = job.returnView;cancelJob();view = previous;show();}
    else if(id==='audio:clear'){dialog={type:'clear-backing',id:state().backing?.id,name:state().backing?.name};show('audio:dialog-cancel');}
    else if(id==='audio:confirm-clear'){if(dialog?.id!==state().backing?.id){error='The backing track changed. Review it before clearing.';show('audio:dialog-cancel');}else{performanceCommand('clear');if(!error)dialog=null;show('audio:browse');}}
    else if(id.startsWith('audio:mix:')){if(mixEdit){mixEdit=null;}else mixEdit={key:value,original:mix()[value]};show(id);}
    else if(id.startsWith('audio:mix-down:')||id.startsWith('audio:mix-up:')){setMix(value,mix()[value]+(id.startsWith('audio:mix-up:')?.01:-.01));show(id);}
    else if(id.startsWith('audio:mix-reset:')){setMix(value,value==='level'?1:.5);show(id);}
    else if (id === 'audio:play') {if(state().backing){if(playing)pause();else play();show(id);}}
    else if (id === 'audio:stop') {stop();show('audio:play');}
    else if (id === 'audio:show-saved' || id === 'audio:use-saved') {location = lastSaved.location;folder = 'Saved audio';selected = lastSaved.id;navigate('browse');if(id === 'audio:use-saved')loadSelected();else show('audio:file:' + selected);}
    return true;
  }
  function overlay() {
    if (!dialog) return '';
    let content;
    if (dialog.type === 'name') content = `<h2>${dialog.purpose==='search'?'Search audio':'Name your audio'}</h2>${button('audio:name-select', `<span class="${selectName ? 'selected-name' : ''}">${esc(dialog.name) || 'Name'}</span>`, 'name-value', `aria-label="Audio name: ${esc(dialog.name)}"`)}<div class="name-keyboard">${['QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM', '1234567890'].map(line => `<div class="key-row">${[...line].map(c => button('audio:key:' + c, c)).join('')}</div>`).join('')}<div class="key-row">${button('audio:key:clear', 'Clear')}${button('audio:key:space', 'Space', 'quiet space-key')}${button('audio:key:delete', icon('delete'), 'quiet icon-only', 'aria-label="Delete character"')}</div></div><div class="actions">${button('audio:dialog-cancel', 'Cancel')}${button('audio:name-done', 'Done', 'primary', dialog.name.trim()||dialog.purpose==='search' ? '' : 'disabled')}</div>`;
    else if(dialog.type==='clear-backing')content=`<h2>Clear backing track?</h2><p>${esc(dialog.name)} stops and unloads. The file and prepared order are kept.</p>${error?`<p class="audio-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${button('audio:dialog-cancel','Cancel')}${button('audio:confirm-clear','Clear backing','danger')}</div>`;
    else if(dialog.type==='export-drive')content=`<h2>Connect a USB drive</h2><p>Your recording stays in Internal.</p><div class="actions">${button('audio:dialog-cancel','Cancel')}${button('audio:export-retry','Try again','primary',usbConnected?'':'disabled')}</div>`;
    else if(dialog.type==='export-replace')content=`<h2>Already on USB</h2><p>${esc(dialog.name)}</p><div class="actions">${button('audio:dialog-cancel','Cancel')}${button('audio:export-both','Keep both','primary')}${button('audio:export-replace','Replace file','danger')}</div>`;
    else if (dialog.type === 'replace') content = `<h2>Replace ${esc(dialog.name)}?</h2><p>A file with this name is already in ${locationLabel(draft.location)} / Saved audio.</p><div class="actions">${button('audio:dialog-cancel', 'Cancel')}${button('audio:rename', 'Rename')}${button('audio:replace', 'Replace file', 'danger')}</div>`;
    else content = `<h2>Change backing track?</h2><p>This stops the current backing track and loads ${esc(dialog.name)}.</p><div class="actions">${button('audio:dialog-cancel', 'Cancel')}${button('audio:load-confirm', 'Change track', 'primary')}</div>`;
    return `<div class="overlay"><section class="dialog ${dialog.type === 'name' ? 'name-dialog' : ''}" role="dialog" aria-modal="true" aria-label="${dialog.type==='export-drive'?'Connect USB drive':dialog.type==='export-replace'?'File already on USB':dialog.type === 'name' ? dialog.purpose==='search'?'Search audio':'Name your audio' : dialog.type === 'replace' ? 'Replace audio file' : 'Change backing track'}">${content}</section></div>`;
  }
  function back() {if(barsEdit){trackImport.barsDraft=barsEdit.value;trackImport.confirmedBars=barsEdit.confirmed;barsEdit=null;show();return true;}if(mixEdit){const edit=mixEdit;mixEdit=null;setMix(edit.key,edit.original);show();return true;}if(dialog){dialog = null;show();return true;}if(job){const prior=job.returnView;cancelJob();view=prior;show();return true;}if(view==='browse'&&destination!==null){destination=null;ctx.returnToTrack?.();return true;}if(view !== 'browse'){navigate('browse');folder='Backing tracks';selected=state().backing?.id||state().files[0]?.id;show();return true;}return false;}
  function review(name) {
    if(name.startsWith('audio-export')){const s=clone(state()),model=window.SegnoPerformanceRecording,take=model.create({id:'performance-export-example',name:'Evening loop — Take 1.wav',sessionName:'Evening loop',output:'Main output'},{sampleRate:48000,channels:2,bitDepth:24,partBytes:2e9}).take,f=model.asset(model.advance(take,83*48000,{freeBytes:64e9,reserveBytes:1e9}).take);s.files.push(f);commit(s);location='internal';folder=f.folder;selected=f.id;
      if(name==='audio-export-collision'){s.usbFiles.push({...clone(f),id:'existing-export',storage:storageAt('usb',ctx.usbIdentity?.())});commit(s);dialog={type:'export-replace',name:f.name,mediaId:ctx.usbIdentity?.()};}
      if(name==='audio-export-missing'){usbConnected=false;dialog={type:'export-drive'};}
      if(name==='audio-export-error')error='Not enough space. Free up storage and try again.';
      if(name==='audio-export-progress'){view='progress';job={kind:'export',parts:partPlan(f).parts,source:clone(f),name:f.name,folder:f.folder,location:'usb',returnView:'browse'};}
      if(name==='audio-export-complete'){lastExport={...clone(f),id:'usb-export-1',sourceId:f.id,returnView:'browse',storage:storageAt('usb',ctx.usbIdentity?.())};s.usbFiles.push(clone(lastExport));commit(s);view='exported';}return;
    }
    if(name.startsWith('performance-backing')){const s=clone(state());s.prepared=name.endsWith('-empty')?[]:s.files.map(f=>f.id);s.backing=s.prepared.length?clone(s.files[0]):null;commit(s);stop();return;}
    if(name.startsWith('audio-track-import')){trackImport={file:clone(state().files[0]),location:name.endsWith('-usb')?'usb':'internal',target:name.endsWith('-selected')?3:null,policy:'unchanged',barsDraft:4,confirmedBars:null};view='track-import';if(name.endsWith('-full')){const s=clone(state());s.trackImports=Object.fromEntries(ctx.tracks().map(t=>[t.id,{file:clone(s.files[0]),state:'stopped',speed:1}]));commit(s);}return;}
    if(name==='audio-prepared'){const s=clone(state());s.prepared=s.files.map(f=>f.id);commit(s);view='prepared';location='internal';folder='';selected=s.prepared[0];return;}
    if (name === 'audio-library') return;
    if (name === 'audio-usb' || name === 'audio-usb-missing' || name === 'audio-file-error') {location = 'usb';folder = 'Live set';selected = name === 'audio-file-error' ? 'usb-bad' : 'usb-1';usbConnected = name !== 'audio-usb-missing';}
    if (name.startsWith('audio-save')) {view = 'save';draft = {tracks: available().map(t=>t.id), location: 'internal', name: 'Evening loop'};if(name === 'audio-save-usb')draft.location = 'usb';if(name === 'audio-save-name'){dialog = {type:'name',name:draft.name};selectName = true;}}
    if (name === 'audio-backing') {const s=clone(state());s.backing=clone(s.files[0]);commit(s);view='backing';}
  }
  return {
    open: () => {destination=null;navigate('browse');},
    openForTrack: target => {const t=importTargets().find(t=>t.id===target);if(!t||t.hasAudio||t.capturing)return false;destination=target;location='internal';folder='Backing tracks';selected=state().files.find(f=>f.folder===folder)?.id||null;navigate('browse');return true;},
    stopPreview,
    browseStorage: value => {navigate('browse');browseLocation(value);},
    reveal: (id,source='internal') => {navigate('browse');location=source;selected=id;folder=files().find(f=>f.id===id)?.folder||'';},
    leave: () => {cancelJob();stopPreview();dialog = null;mixEdit=null;barsEdit=null;},
    body: () => view==='exported'?exportedBody():view === 'track-import'?trackImportBody():view==='imported'?importedBody():view === 'save' ? saveBody() : view === 'backing' ? backingBody() : view === 'saved' ? savedBody() : view === 'progress' ? progressBody() : browseBody(),
    overlay, action, back, review, performanceCommand,
    turn:delta=>{if(!ctx.active())return false;if(barsEdit){trackImport.barsDraft=Math.max(1,Math.min(1024,trackImport.barsDraft+Math.round(delta)));trackImport.confirmedBars=null;show('audio:bars-value');return true;}if(!mixEdit)return false;setMix(mixEdit.key,mix()[mixEdit.key]+delta*.01);show('audio:mix:'+mixEdit.key);return true;},
    finish:(cancel=false)=>{if(barsEdit){if(cancel){trackImport.barsDraft=barsEdit.value;trackImport.confirmedBars=barsEdit.confirmed;}barsEdit=null;show('audio:bars-value');return true;}if(!mixEdit)return false;const edit=mixEdit;mixEdit=null;if(cancel)setMix(edit.key,edit.original);show('audio:mix:'+edit.key);return true;},
    performanceSnapshot:()=>clone({files:preparedFiles(),loaded:state().backing,end:state().backingEnd||'stop',playing,position:elapsed(),part:partPosition(state().backing,elapsed()),error,mix:mix()}),
    tick:()=>{
      if(preview&&previewFile){if(partError(previewFile)){error=partError(previewFile);stopPreview();render();}else if((Date.now()-previewStarted)/1000>=previewFile.seconds){stopPreview();render();}}
      if(playing&&partError(state().backing)){pause();error=partError(state().backing);render();return;}
      if(!playing||!state().backing||elapsed()<state().backing.seconds)return;
      const s=clone(state()),overflow=position+(Date.now()-startedAt)/1000-s.backing.seconds;
      if(s.backingEnd==='repeat'&&s.backing.seconds>0){position=overflow%s.backing.seconds;startedAt=Date.now();}
      else if(s.backingEnd==='next'){
        const list=preparedFiles(),index=list.findIndex(f=>f.id===s.backing.id),next=index>=0?list[index+1]:null;
        if(!next)stop();
        else if(next.unreadable||!next.seconds||partError(next)){stop();error='The next recording could not be played.';}
        else {s.backing=clone(next);if(commit(s)===false){stop();error='The next recording could not be loaded.';}else{position=Math.min(Math.max(0,overflow),next.seconds);startedAt=Date.now();}}
      }else stop();
      render();
    },
    initialFocus: () => dialog?.type.startsWith('export-')?'audio:dialog-cancel':view==='exported'?'audio:export-done':view==='progress'?'audio:cancel-job':view==='track-import'?(importTargets().some(t=>!t.hasAudio&&!t.capturing)?'audio:import-target:'+(trackImport?.target??importTargets().find(t=>!t.hasAudio&&!t.capturing).id):'audio:cancel-track-import'):view === 'save' ? 'audio:name' : view === 'backing' ? 'audio:play' : selected ? 'audio:file:' + selected : 'audio:location:' + location,
    rememberScroll: root => {const el=root.querySelector('.audio-scroll');if(el)scrollPositions[el.dataset.path]=el.scrollTop;},
    restoreScroll: root => {const el=root.querySelector('.audio-scroll');if(el)el.scrollTop=scrollPositions[el.dataset.path]||0;},
    key: e => {if(!ctx.active() || dialog?.type !== 'name')return false;if(e.key === 'Backspace'){editName('delete');return true;}if(/^[a-zA-Z0-9 _-]$/.test(e.key)){editName(e.key);return true;}return false;},
    simulate: change => {if(change.usbConnected !== undefined){usbConnected = change.usbConnected;if(!usbConnected){if(location==='usb')stopPreview();if(job&&(job.kind==='import'||job.location==='usb')){const previous=job.returnView;cancelJob();view=previous;error='The USB drive was disconnected. Nothing was saved.';}}}if(change.full !== undefined)full=change.full;if(change.empty){const s=clone(state());s.files=[];commit(s);selected=null;}show();},
    snapshot: () => clone({view,location,folder,audioQuery,selected,preview,previewPart:previewFile?partPosition(previewFile,(Date.now()-previewStarted)/1000):null,playing,position:elapsed(),part:partPosition(state().backing,elapsed()),dialog,job,usbConnected,full,error,draft,lastSaved,lastExport,trackImport,lastImport,destination,importPlan:trackImport?importPlan():null,mix:mix(),state:state()}),
  };
};
