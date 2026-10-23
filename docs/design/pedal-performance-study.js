// Silent interaction study: state and gesture behavior, without audio dispatch.
window.createPedalPerformanceStudy = function ({getSettings, onChange, newLoop, recordPerformance, recordingState, fx, bankState, muteState, soloState, trackNames, transposeState, mixerState, reverseState, fadeState, speedState, lengthState, peelState, bounceState, backingState, tunerState, icon, currentTrack, transport, trackTransport, showView, assignedAction, initialView = 'tracks'}) {
  const holdMs = 800, doubleMs=300;
  let lastTrackTap=null;
  const labels = ['REC/PLAY', 'STOP', 'UNDO', 'MODE', 'TRACK1', 'TRACK2', 'TRACK3', 'TRACK4', 'CLEAR', 'BANK'];
  const gestures = new Map();
  let view = initialView;
  const esc = text => String(text).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');
  const assignedEntry=value=>window.SegnoAssignableActions.find(a=>a.key===value||a.label===value);
  const assignmentLabel=value=>assignedEntry(value)?.label||(value?.startsWith('instrument:')?'Unavailable instrument':value);
  const availableEntry=value=>!!assignedEntry(value)||['Track','Reset pitch'].includes(value);
  const transpose=window.createTransposePerformanceStudy({state:transposeState,trackNames,currentTrack,transport});

  const tuner=window.createTunerPerformanceStudy({state:tunerState});
  const backing=window.createBackingPerformanceStudy({state:backingState,changed:backingState.changed});
  const bounce=window.createBouncePerformanceStudy({state:bounceState,trackNames,bankState,history:trackTransport});
  const editingLength=()=>view==='multiply'||view==='divide';
  const peel=window.createPeelPerformanceStudy({state:peelState,trackNames,currentTrack,transport,bankState,history:trackTransport});
  const length=window.createLengthPerformanceStudy({state:lengthState,trackNames,currentTrack,transport,bankState,history:trackTransport});

  const speed=window.createSpeedPerformanceStudy({state:speedState,trackNames,currentTrack,transport});

  const fade=window.createFadePerformanceStudy({state:fadeState,trackNames,currentTrack,transport});

  const mixer=window.createMixerPerformanceStudy({state:mixerState,muteState,trackNames,currentTrack,transport,fadeState:fade});

  const reverse=window.createReversePerformanceStudy({state:reverseState,trackNames,currentTrack,transport,icon});

  function assignments(id) {
    const settings = getSettings();
    if(view==='tuner')return tuner.assignments(id);
    if(view==='backing')return backing.assignments(id);
    if(view==='transpose')return transpose.assignments(id);
    if(view==='mixer')return mixer.assignments(id);
    if(view==='reverse')return reverse.assignments(id);
    if(view==='fade')return fade.assignments(id);
    if(view==='speed')return speed.assignments(id);
    if(editingLength())return length.assignments(id);
    if(view==='peel')return peel.assignments(id);
    if(view==='bounce')return bounce.assignments(id);
    if(view==='tracks'||view==='mute'){
      if(id===3)return view==='mute'?{press:'Exit',hold:'None'}:settings.mode;
      if(id===0)return {press:'Record / Play',hold:settings.recordHold};
      if(id===1)return {press:'Stop',hold:'None'};
      if(id===2)return {press:'Undo',hold:'Redo'};
      if(id===8)return {press:'Clear',hold:'None'};
      if(id>=4&&id<=7)return view==='mute'?{press:'Mute track',hold:'None'}:{press:'Select track',hold:settings.trackHold};
    }
    if (view === 'custom') {
      if (id === 3) return {press: 'Exit', hold: 'None'};
      if (id >= 4 && id <= 7 && bankState.get()) return settings.bankB[id - 4];
      return settings.custom[id];
    }
    return {press: id === 3 ? 'Exit' : 'None', hold: 'None'};
  }

  function role(id) {
    if(view==='tuner')return tuner.role(id);
    if(view==='backing')return backing.role(id);
    if(view==='speed')return speed.role(id);
    if(editingLength())return length.role(id,bankState.get());
    if(view==='peel')return peel.role(id,bankState.get());
    if(view==='bounce')return bounce.role(id,bankState.get());
    if(view==='mixer')return mixer.role(id);
    if(view==='fade')return fade.role(id,bankState.get());
    if (id === 9) return {name: `Bank ${bankState.get() ? 'B' : 'A'}`, hint: 'Switch bank', enabled: true, active: bankState.get() === 1};
    if(view==='transpose')return transpose.role(id,bankState.get());
    if(view==='reverse')return reverse.role(id,bankState.get());
    if ((view === 'fx' || view === 'mute') && id >= 4 && id <= 7) {
      const index = bankState.get() * 4 + id - 4;
      return view === 'fx'
        ? {...fx.get(index), momentaryContact: fx.get(index).held && fx.get(index).behavior !== 'toggle'}
        : {name: trackNames[index], hint: 'Mute', enabled: true, active: muteState.get(index)};
    }
    if (view === 'tracks' && id >= 4 && id <= 7) {const i=bankState.get()*4+id-4,reversed=reverseState.hasAudio(i)&&reverseState.get(i);return {name:trackNames[i],hint:!reverseState.hasAudio(i)?'Empty':reversed?'Reverse':'',reverseBadge:reversed,enabled:true,active:soloState?.any()?soloState.get(i):trackTransport.snapshot().tracks[i].playing||!!trackTransport.snapshot().tracks[i].capturing};}
    const pair = assignments(id);
    if(['tracks','mute'].includes(view)&&[0,1,2,8].includes(id)){
      const i=Math.max(0,currentTrack()),state=trackTransport.snapshot().tracks[i];
      return {name:pair.press,hint:pair.hold!=='None'?'Hold · '+pair.hold:'',enabled:id===2?!!(state.undo||state.redo||state.capturing||trackTransport.snapshot().pending.some(p=>p.track===i)):id===8?!!(state.layers||state.capturing):true,active:id===0?!!state.capturing:false};
    }
    if(pair.press==='Record performance'){const phase=recordingState?.()||'ready';return {name:phase==='recording'?'Stop recording':phase==='saving'?'Saving recording':phase==='recovered'?'Save recording':'Record performance',hint:pair.hold&&pair.hold!=='None'?'Hold · '+pair.hold:'',enabled:phase!=='saving',active:phase==='recording'};}
    const names = ['Record / Play', 'Stop', 'Undo', 'Mode', '', '', '', '', 'Clear'];
    return {
      name: pair.press === 'None' ? names[id] : assignmentLabel(pair.press),
      hint: pair.hold && pair.hold !== 'None' ? `Hold · ${assignmentLabel(pair.hold)}` : '',
      enabled: availableEntry(pair.press) || availableEntry(pair.hold),
      active: pair.hold==='Record performance'&&recordingState?.()==='recording'||id === 3 && view !== 'tracks',
    };
  }

  function finishMomentary(gesture) {
    if (gesture.fxToken !== undefined) fx.up(gesture.fxToken);
    if(typeof gesture.assignmentRelease==='function'){gesture.assignmentRelease();gesture.assignmentRelease=null;}
  }

  function enter(next) {
    lastTrackTap=null;
    for (const gesture of gestures.values()) {
      clearTimeout(gesture.timer);
      finishMomentary(gesture);
      gesture.consumed = true;
    }
    backing.controls.cancel();
    view = next;
    if(next==='tuner')tuner.enter();
    if(next==='transpose')transpose.enter();
    if(next==='mixer')mixer.enter();
    if(next==='fade')fade.enter();
    if(next==='peel')peel.enter();
    if(next==='bounce')bounce.enter();
    if(next==='backing')backing.enter();
    if(next==='multiply'||next==='divide')length.enter(next);
  }

  function run(action, id) {
    if (action === 'Exit') enter('tracks');
    else if(action==='Track'||action==='Wave'){enter('tracks');showView?.(action==='Wave'?'wave':'track');}
    else if (action === 'Custom') enter('custom');
    else if (action === 'FX') enter('fx');
    else if (action === 'Mute') enter('mute');
    else if (action === 'Tuner') enter('tuner');
    else if (action === 'Transpose') enter('transpose');
    else if (action === 'Mixer') enter('mixer');
    else if (action === 'Reverse') enter('reverse');
    else if (action === 'Fade') enter('fade');
    else if (action === 'Speed') enter('speed');
    else if (action === 'Multiply') enter('multiply');
    else if (action === 'Divide') enter('divide');
    else if (action === 'Peel') enter('peel');
    else if(action==='Bounce')enter('bounce');
    else if(action==='Backing track')enter('backing');
    else if(action==='New loop')newLoop();
    else if(action==='Record performance')recordPerformance?.();
    else if(window.SegnoDirectActions.some(a=>a.key===action||a.label===action)){const entry=window.SegnoDirectActions.find(a=>a.key===action||a.label===action),gesture=[...gestures.values()].find(g=>g.id===id),source=entry.operation==='instrument'?`custom:${id>=4&&id<=7?gesture?.bank??bankState.get():0}:${id}`:'custom:'+gesture?.token,release=assignedAction?.(entry.key,source);if(typeof release==='function'){if(gesture)gesture.assignmentRelease=release;else release();}}
    else if(view==='tracks'||view==='mute'){
      const i=id>=4&&id<=7?bankState.get()*4+id-4:Math.max(0,currentTrack());
      trackTransport.command(action==='Select track'?'Select':action,i);
    }
    else if(['Record / Play','Stop','Undo','Redo'].includes(action)&&view==='custom')trackTransport.command(action);
    else if(view==='tuner')tuner.run(action,id);
    else if(view==='backing')backing.run(action,id);
    else if(view==='bounce')bounce.run(action,id);
    else if(view==='peel')peel.run(action,id);
    else if(editingLength())length.run(action,id);
    else if(view==='speed')speed.run(action);
    else if(view==='fade'){if(action==='Toggle fade')fade.toggle(bankState.get()*4+id-4);else fade.run(action,id,bankState.get());}
    else if(view==='reverse')reverse.run(action);
    else if(view==='transpose')transpose.run(action);
    else if(view==='mixer'){if(action==='Mixer inputs'||action==='Mixer tracks'){for(const g of gestures.values()){clearTimeout(g.timer);g.consumed=true;}}mixer.run(action,id);}
  }

  // Direct assignments preserve the current performance page and mode selections.
  function direct({operation,tracks=[Math.max(0,currentTrack())],value}={}) {
    const supported=['mute','solo','reverse','fade','pitch-step','pitch-reset','transpose-bypass','speed','multiply','divide','undo-length','peel','restore-peel','clear','undo','redo'];
    if(!supported.includes(operation))return {handled:false,changed:false};
    const list=[...new Set(tracks)];
    if(list.some(i=>!Number.isInteger(i)||i<0||i>=trackNames.length))return {handled:true,changed:false,reason:'Invalid track'};
    const audio=list.filter(i=>reverseState.hasAudio(i));
    const capturing=trackTransport.snapshot().tracks.some((t,i)=>list.includes(i)&&t.capturing);
    if(capturing&&!['mute','solo','clear','undo','redo','transpose-bypass','speed','reverse'].includes(operation))return {handled:true,changed:false,reason:'Finish recording'};
    let changed=false;
    if(operation==='mute'||operation==='solo'){const state=operation==='mute'?muteState:soloState;if(!state?.toggle)return {handled:true,changed:false,reason:'Control unavailable'};for(const i of list)state.toggle(i);changed=list.length>0;}
    else if(operation==='reverse'||operation==='fade'){for(const i of audio)(operation==='reverse'?reverse:fade).toggle(i);changed=audio.length>0;}
    else if(operation==='pitch-step'||operation==='pitch-reset')changed=transpose.direct(audio,operation==='pitch-reset'?0:value);
    else if(operation==='transpose-bypass')changed=transpose.toggleEnabled();
    else if(operation==='speed')changed=speed.set(value);
    else if(operation==='multiply'||operation==='divide'||operation==='undo-length')changed=length.direct(audio,operation==='multiply'?'double':operation==='divide'?'half':'undo',value||'first');
    else if(operation==='peel'||operation==='restore-peel')changed=peel.direct(audio,operation==='restore-peel');
    else if(operation==='undo'||operation==='redo'){if(list.length===1){const before=JSON.stringify(trackTransport.snapshot());trackTransport.command(operation==='undo'?'Undo':'Redo',list[0]);changed=before!==JSON.stringify(trackTransport.snapshot());}else {const eligible=list.filter(i=>trackTransport.nextEdit(i,operation));changed=eligible.length?trackTransport.recover(eligible,operation):false;}}
    else {for(const i of list)trackTransport.command('Clear',i);changed=list.length>0;}
    onChange(3);return {handled:true,changed:!!changed,...(!changed?{reason:'No eligible tracks or edit limit reached'}:{})};
  }

  function press(id, token) {
    if (gestures.has(token) || [...gestures.values()].some(g => g.id === id) || !role(id).enabled) return;
    const now=performance.now(),trackIndex=bankState.get()*4+id-4,doubleEnabled=view==='tracks'&&id>=4&&id<=7&&getSettings().trackDoubleSolo===true;
    const second=doubleEnabled&&lastTrackTap?.track===trackIndex&&now-lastTrackTap.at<=doubleMs;
    lastTrackTap=null;
    const gesture = {id, token, bank:bankState.get(), consumed: false, view, startedAt: now,trackIndex,doubleEnabled,second};
    gestures.set(token, gesture);
    if(['tracks','mute'].includes(view)&&(id===0||id===1)||view==='tracks'&&id>=4&&id<=7){
      if(!second)run(assignments(id).press,id);
      gesture.direct=true;gesture.consumed=assignments(id).hold==='None';
      if(assignments(id).hold!=='None')gesture.timer=setTimeout(()=>{if(!gestures.has(token)||view!==gesture.view)return;gesture.consumed=true;lastTrackTap=null;run(assignments(id).hold,id);onChange(id);},holdMs);
    } else if(view==='custom'&&assignments(id).hold==='None'&&assignedEntry(assignments(id).press)?.operation==='instrument'&&assignedEntry(assignments(id).press).behavior==='held'){
      gesture.consumed=true;
      run(assignments(id).press,id);
    } else if(view==='speed'&&(id===2||id>=4&&id<=7)){
      speed.run(assignments(id).press);
      gesture.consumed=true;
    } else if(view==='reverse'&&id>=4&&id<=7){
      reverse.toggle(bankState.get()*4+id-4);
      gesture.consumed=true;
    } else if(view==='transpose'&&id>=4&&id<=7){
      transpose.toggle(bankState.get()*4+id-4);
      gesture.consumed=true;
    } else if (view === 'fx' && id >= 4 && id <= 7) {
      gesture.fxToken = 'performance:' + token;
      fx.down(bankState.get() * 4 + id - 4, gesture.fxToken);
      gesture.consumed = true;
    } else if (view === 'mute' && id >= 4 && id <= 7) {
      const index = bankState.get() * 4 + id - 4;
      muteState.toggle(index);
      gesture.consumed = true;
    } else if ((id !== 9 || view==='mixer'||view==='fade'||view==='backing') && assignments(id).hold && assignments(id).hold !== 'None') {
      gesture.timer = setTimeout(() => {
        if (gesture.consumed || !gestures.has(token) || view !== gesture.view) return;
        gesture.consumed = true;
        run(assignments(id).hold,id);
        onChange(id);
      }, holdMs);
    }
    onChange(id);
  }

  function release(token, cancelled = false) {
    const gesture = gestures.get(token);
    if (!gesture) return;
    clearTimeout(gesture.timer);
    if(!cancelled&&gesture.doubleEnabled&&!gesture.consumed&&view===gesture.view&&bankState.get()*4+gesture.id-4===gesture.trackIndex&&performance.now()-gesture.startedAt<=doubleMs){
      if(gesture.second){soloState.toggle(gesture.trackIndex);lastTrackTap=null;}
      else lastTrackTap={track:gesture.trackIndex,at:performance.now(),token};
    }else lastTrackTap=null;
    if (!cancelled && !gesture.direct && !gesture.consumed && view === gesture.view) {
      if (gesture.id === 9 && view!=='tuner' && view!=='backing' && view!=='mixer' && view!=='peel' && view!=='bounce' && !editingLength()) bankState.set(1 - bankState.get());
      else run(assignments(gesture.id).press,gesture.id);
    }
    finishMomentary(gesture);
    gestures.delete(token);
    onChange(gesture.id);
  }

  function cancel() {
    lastTrackTap=null;
    backing.controls.cancel();
    for (const gesture of gestures.values()) {
      clearTimeout(gesture.timer);
      finishMomentary(gesture);
    }
    gestures.clear();
  }

  function cancelTouch() {
    if(typeof lastTrackTap?.token==='number')lastTrackTap=null;
    for(const [token,gesture] of gestures)if(typeof token==='number'){
      clearTimeout(gesture.timer);finishMomentary(gesture);gestures.delete(token);
    }
  }

  function feedback(id) {
    const gesture = [...gestures.values()].find(g => g.id === id && g.view === view);
    const pending = !!(gesture?.timer && !gesture.consumed);
    // A held FX contact belongs to its logical slot even after changing banks.
    const contact = view === 'fx' && id >= 4 && id <= 7
      ? fx.get(bankState.get() * 4 + id - 4).held
      : !!gesture;
    return {pending, contact, progress: pending ? Math.min(1, (performance.now() - gesture.startedAt) / holdMs) : 0};
  }

  function refreshFeedback(root) {
    for (const fill of root.querySelectorAll('[data-hold-progress]')) {
      const state = feedback(Number(fill.dataset.holdProgress));
      fill.style.width = `${state.progress * 100}%`;
    }
  }

  function body(colors) {
    const slots = [{id: 8, col: 3, row: 1}, {id: 9, col: 4, row: 1}, ...Array.from({length: 8}, (_, id) => ({id, col: id + 1, row: 2}))];
    return `<div class="pedal-map performance-map ${view==='tuner'?'tuner-map':view==='backing'?'backing-map':view==='transpose'?'transpose-map':view==='mixer'?'mixer-map':view==='reverse'?'reverse-map':view==='fade'?'fade-map':view==='speed'?'speed-map':editingLength()?'length-map':view==='peel'?'peel-map':view==='bounce'?'bounce-map':''}" aria-label="Performance pedals">${view==='tuner'?tuner.body():view==='backing'?backing.body():view==='transpose'?transpose.body():view==='mixer'?mixer.body():view==='reverse'?reverse.body():view==='fade'?fade.body():view==='speed'?speed.body():editingLength()?length.body():view==='peel'?peel.body():view==='bounce'?bounce.body():view==='tracks'?speed.stageBody():''}${slots.map(({id, col, row}) => {
      const r = role(id), gesture = feedback(id);
      return `<button class="pedal ${row === 1 ? 'rear-row' : ''} ${gesture.pending ? 'hold-pending' : ''} ${gesture.contact ? 'pedal-contact' : ''} ${r.momentaryContact ? 'momentary-contact' : ''} ${r.reverseBadge?'has-direction':''}" data-action="perform:${id}" data-perf-id="${id}" style="grid-column:${col};grid-row:${row}" aria-label="${esc(`${id >= 4 && id <= 7 ? 'Pedal ' + (id - 3) : labels[id]}: ${r.name}${r.hint ? ', ' + r.hint : ''}, ${r.active ? 'active' : 'inactive'}`)}" ${r.enabled ? '' : 'disabled'}>
        ${SegnoPedalWidget.indicator({color: colors[id], active: r.active, disabled: !r.enabled})}
        ${SegnoPedalWidget.face({label: labels[id], disabled: !r.enabled})}
        ${gesture.pending ? `<span class="pedal-hold-progress" aria-hidden="true"><span data-hold-progress="${id}" style="width:${gesture.progress * 100}%"></span></span>` : ''}
        <span class="performance-caption">${esc(r.name)}${r.reverseBadge?`<small class="track-reverse-badge">${icon('left')}Reverse</small>`:view==='backing'?backing.caption(r):view==='mixer'?mixer.caption(r):view==='reverse'?reverse.caption(r):view==='fade'?fade.caption(r):view==='speed'?speed.caption(r):editingLength()?length.caption(r):view==='peel'?peel.caption(r):view==='bounce'?bounce.caption(r):r.pitch!=null?`<strong class="transpose-pitch">${esc(r.pitch)}<small>st</small></strong>`:`<small>${esc(r.hint)}</small>`}</span>
      </button>`;
    }).join('')}</div>`;
  }

  return {
    direct,backingControls:backing.controls,body, press, release, cancel, cancelTouch,controls:()=>labels.map((label,id)=>({id,label,...role(id),hold:assignmentLabel(assignments(id).hold)})),
    invoke:label=>{if(!window.SegnoPerformanceActions.some(a=>a.label===label))return false;if(['Record / Play','Stop','Undo','Redo'].includes(label))trackTransport.command(label);else run(label,3);onChange(3);return true;},
    leave:()=>{cancel();if(view==='tuner')enter('tracks');},
    tunerMutedInputs:()=>view==='tuner'?tuner.mutedInputs():[],
    simulateTuner:values=>{tuner.simulate(values);},
    action:id=>{if(view==='bounce'&&bounce.action?.(id)){onChange(0);return true;}if(view!=='mixer'||!['mixer:tracks','mixer:inputs'].includes(id))return false;cancel();mixer.run(id==='mixer:inputs'?'Mixer inputs':'Mixer tracks');onChange(9);return true;},
    title: () => ({tracks: 'Tracks', custom: 'Custom', fx: 'FX', mute: 'Mute',transpose:'Transpose',mixer:'Mixer',reverse:'Reverse',fade:'Fade',speed:'Speed',multiply:'Multiply',divide:'Divide',peel:'Peel',bounce:'Bounce',backing:'Backing track',tuner:'Tuner'})[view],
    snapshot: () => JSON.parse(JSON.stringify({view, bank:bankState.get(), fx:Array.from({length:8},(_,i)=>fx.get(i)), muted:Array.from({length:8},(_,i)=>muteState.get(i)), transpose:transpose.snapshot(),mixer:mixer.snapshot(),reverse:reverse.snapshot(),fade:fade.snapshot(),speed:speed.snapshot(),length:length.snapshot(),peel:peel.snapshot(),bounce:bounce.snapshot(),backing:backing.snapshot(),tuner:tuner.snapshot(),holdMs,doubleMs,doubleSolo:!!getSettings().trackDoubleSolo,pending: gestures.size})),
    selectFadeTime:i=>{fade.select(i);},
    refresh:root=>{refreshFeedback(root);fade.refresh(root,bankState.get());if(view==='backing')backing.refresh(root);},
    indicatorState: id => role(id).active,
    setView: next => {cancel();enter(next);},
  };
};
