// Silent transport model. Content descriptors stand in for audio buffers.
window.createStageTransportStudy = ({tracks, read, settings, capture, playback, select, selected, changed, editState, primaryClearRequested=()=>{}, audioReady=()=>true, now=()=>performance.now()}) => {
  const clone=value=>value===undefined?undefined:JSON.parse(JSON.stringify(value));
  const epsilon=1e-7;
  let enabled=false, last=now(), beat=0, origin=0, elapsed=0, begun=false, notice=null,playbackChanged=false;
  let pending=new Map(), takes=new Map(), positions=tracks.map(()=>0),cycleOrigin=0,primaryClear=null,dismissedTiming=null;
  let history=tracks.map(()=>({undo:[],redo:[]})),resumeTracks=null,editSerial=0,historyLoaded=false;
  const cfg=i=>settings(i);
  const hasAudio=i=>read(i).layers.length>0;
  const duration=i=>read(i).beats;
  const empty=()=>({parts:[],beats:0,layers:[]});
  const active=()=>enabled;
  const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
  const contentKeys=new Set(['parts','length','layers','recipe','imported']);
  function loadHistory(){if(historyLoaded)return;const saved=editState.readHistory();history=clone(saved?.tracks||tracks.map(()=>({undo:[],redo:[]})));editSerial=saved?.serial||0;historyLoaded=true;}
  function activate(){if(enabled)return;loadHistory();enabled=true;last=now();begun=tracks.some((_,i)=>hasAudio(i)||playback(i));}
  function persistHistory(){editState.writeHistory({serial:editSerial,tracks:clone(history)});}
  function reset(){resumeTracks=null;enabled=false;last=now();beat=0;origin=0;cycleOrigin=0;primaryClear=null;dismissedTiming=null;elapsed=0;begun=false;notice=null;pending.clear();takes.clear();positions=tracks.map(()=>0);history=tracks.map(()=>({undo:[],redo:[]}));editSerial=0;historyLoaded=false;}
  function feedback(i,action){notice={track:i,action,until:now()+2400};}
  function canonicalAudio(base,audio,label){const next=clone(base);next.parts=clone(audio.parts);next.layers={layers:clone(audio.layers)};next.length={...(audio.beats===(base.length.durationBeats??base.length.audio.length)?clone(base.length):{}),audio:audio.beats===(base.length.durationBeats??base.length.audio.length)?clone(base.length.audio):[],durationBeats:audio.beats,note:label};if(!audio.layers.length||label==='Recording'){next.recipe=null;next.imported=null;}return next;}
  function appendRecord(journal,changes,before,label,metadata={}){
    const group=Object.keys(changes).map(Number),entry={id:++journal.serial,group,before:clone(before),after:clone(changes),label,metadata:clone(metadata)};
    const discarded=new Set(group.flatMap(i=>journal.tracks[i].redo.map(e=>e.id)));
    for(const h of journal.tracks)h.redo=h.redo.filter(e=>!discarded.has(e.id));
    for(const i of group){journal.tracks[i].undo.push(entry);journal.tracks[i].redo=[];}
    return entry;
  }
  const journalSnapshot=()=>({serial:editSerial,tracks:clone(history)});
  function record(changes,before,label,metadata={}){const journal=journalSnapshot(),entry=appendRecord(journal,changes,before,label,metadata);history=journal.tracks;editSerial=journal.serial;persistHistory();return entry;}
  function publish(changes,journal,i,clock){
    try{if(editState.publish(clone(changes),clone(journal),clone(clock))===false)throw new Error('Not saved');}
    catch{feedback(i,'Could not save recovery · Try again');return false;}
    history=journal.tracks;editSerial=journal.serial;return true;
  }
  function commit(i,before,after,label,playAfter){const full=editState.read(i),prior=canonicalAudio(full,before,full.length.note||''),next=canonicalAudio(full,after,label),journal=journalSnapshot();if(playAfter!==undefined)next.playing=playAfter;appendRecord(journal,{[i]:next},{[i]:prior},label);return publish({[i]:next},journal,i);}
  function compatibility(changes){const lengths=tracks.map((_,i)=>{const v=changes[i];return {i,beats:v?(v.layers.layers.length?(v.length.durationBeats??v.length.audio.length):0):duration(i)};}).filter(t=>t.beats>0),mode=cfg(0).mode,near=(a,b)=>Math.abs(a-b)<=1e-6*Math.max(1,a,b);if(!lengths.length)return '';
    if(mode==='multi'&&lengths.some(t=>!near(t.beats,lengths[0].beats)))return 'Tracks need equal lengths in Multi';
    if(['sync','band'].includes(mode)){const primary=lengths.find(t=>tracks[t.i]===cfg(0).primaryTrack)||lengths[0];if(lengths.some(t=>{const ratio=Math.max(t.beats,primary.beats)/Math.min(t.beats,primary.beats);return !near(ratio,Math.round(ratio));}))return 'Lengths must follow '+tracks[primary.i];}return '';
  }
  function lengthChanged(changes){return Object.entries(changes).some(([i,v])=>duration(+i)!==(v.parts.length?(v.length.durationBeats??v.length.audio.length):0));}
  function edit(changes,label,metadata={}){activate();tick();const group=Object.keys(changes).map(Number);if(!group.length||group.some(i=>takes.has(i)||pending.has(i))){feedback(group[0]||0,'Finish or cancel recording');return false;}const reason=lengthChanged(changes)?compatibility(changes):'';if(reason){feedback(group[0],reason);return false;}const before=Object.fromEntries(group.map(i=>[i,clone(editState.read(i))]));editState.write(clone(changes));record(changes,before,label,metadata);enforceSections(selected());changed();return true;}
  function editPart(changes,key,label){return edit(Object.fromEntries(Object.entries(changes).map(([i,value])=>[i,{...clone(editState.read(+i)),[key]:clone(value)}])),label);}
  function splitRegions(regions,span){
    return regions.flatMap(r=>{if(r.beats<=epsilon||span<=epsilon)return [];if(r.beats>=span)return [{offsetBeats:0,beats:span}];const start=((r.offsetBeats%span)+span)%span,end=start+r.beats;return end<=span?[{offsetBeats:start,beats:r.beats}]:[{offsetBeats:start,beats:span-start},{offsetBeats:0,beats:end-span}];});
  }
  function editLength(changes,label){
    const full={};for(const [key,length]of Object.entries(changes)){
      const i=+key,track=clone(editState.read(i)),span=duration(i),op=length.region;
      for(const layer of track.layers.layers){const regions=splitRegions(layer.regions||[{offsetBeats:0,beats:span}],span);
        layer.regions=op.operation==='repeat'?regions.flatMap(r=>[r,{...r,offsetBeats:r.offsetBeats+span}]):regions.flatMap(r=>{const start=Math.max(r.offsetBeats,op.from),end=Math.min(r.offsetBeats+r.beats,op.from+op.beats);return end>start?[{offsetBeats:start-op.from,beats:end-start}]:[];});
      }
      track.length=clone(length);full[i]=track;
    }return edit(full,label);
  }
  function nextEdit(i,direction='undo'){loadHistory();return history[i]?.[direction]?.at(-1)||null;}
  function recoveryEntries(list,direction,labels,journal=history,releasing=[]){
    const next=i=>journal[i]?.[direction]?.at(-1),entries=[...new Map(list.map(next).filter(Boolean).map(e=>[e.id,e])).values()];
    if(!entries.length||list.some(i=>!next(i)))return null;
    if(entries.some(e=>labels&&!labels.includes(e.label)||e.group.some(i=>!releasing.includes(i)&&(takes.has(i)||pending.has(i))||next(i)?.id!==e.id)))return null;
    return entries;
  }
  function canRecover(list,direction='undo',labels){loadHistory();return !!recoveryEntries(list,direction,labels);}
  // Restore only the fields this edit changed. Later mixer/FX edits survive.
  function restoreField(current,from,to){if(same(from,to))return clone(current);if(same(current,from))return to===undefined?undefined:clone(to);if(from&&to&&current&&typeof from==='object'&&typeof to==='object'&&!Array.isArray(from)&&!Array.isArray(to)){const out=clone(current);for(const key of new Set([...Object.keys(from),...Object.keys(to)])){const value=restoreField(current[key],from[key],to[key]);if(value===undefined)delete out[key];else out[key]=value;}return out;}return current===undefined?undefined:clone(current);}
  function recoverySections(changes,nextPositions,preferred){
    const mode=cfg(0).mode;if(!['song','band'].includes(mode))return true;
    const candidate=i=>changes[i]||editState.read(i),populated=tracks.map((_,i)=>i).filter(i=>candidate(i).layers.layers.length);
    const bed=mode==='band'?(populated.find(i=>tracks[i]===cfg(0).primaryTrack)??populated[0]):-1;
    const playing=populated.filter(i=>i!==bed&&candidate(i).playing),chosen=playing.includes(preferred)?preferred:playing[0];
    for(const i of playing)if(i!==chosen){if(takes.has(i)||pending.has(i)){feedback(i,'Finish or cancel recording');return false;}changes[i]={...clone(candidate(i)),playing:false};nextPositions[i]=0;}
    return true;
  }
  function recover(list,direction='undo',labels,staged){
    activate();if(!staged)tick();const journal=staged?.journal||journalSnapshot();
    const entries=recoveryEntries(list,direction,labels,journal.tracks,staged?.releasing||[]);
    if(!entries){feedback(list[0]||0,'Undo newer edits first');return false;}
    const changes={},target=direction==='undo'?'before':'after',source=direction==='undo'?'after':'before',other=direction==='undo'?'redo':'undo',nextPositions=clone(positions);
    for(const e of entries)for(const i of e.group){
      const current=clone(editState.read(i)),from=e[source][i],to=e[target][i];
      for(const key of new Set([...Object.keys(from),...Object.keys(to)])){
        if(same(from[key],to[key]))continue;
        const value=contentKeys.has(key)?clone(to[key]):restoreField(current[key],from[key],to[key]);
        if(value===undefined)delete current[key];else current[key]=value;
      }
      if(!current.layers.layers.length){current.playing=false;nextPositions[i]=0;}
      else if(direction==='redo'&&e.label==='Recording'&&!e.before[i].layers.layers.length){current.playing=true;nextPositions[i]=cfg(i).mode==='multi'?sharedPosition(i):0;}
      if(e.metadata.positions)nextPositions[i]=e.metadata.positions[target][i];
      changes[i]=current;journal.tracks[i][direction].pop();journal.tracks[i][other].push(e);
    }
    const reason=lengthChanged(changes)?compatibility(changes):'';
    if(reason){feedback(list[0],reason);return false;}
    if(!recoverySections(changes,nextPositions,list[0]))return false;
    if(!audioReady()&&Object.values(changes).some(t=>t.playing)){feedback(list[0],'Reconnect audio to recover playback');return false;}
    const clock={};for(const e of entries)for(const [key,value]of Object.entries(e.metadata.clock?.[target]||{}))if(same(cfg(0)[key]??null,e.metadata.clock[source][key]??null))clock[key]=value;
    if(!publish(changes,journal,list[0],Object.keys(clock).length?clock:undefined))return false;
    for(const e of entries){const cycle=e.metadata.cycle?.[target],p=primary();if(cycle&&cycle.primary===(p>=0?tracks[p]:null))cycleOrigin=beat-cycle.position*(p>=0?duration(p):0);}
    positions=nextPositions;
    for(const i of Object.keys(changes).map(Number)){takes.delete(i);pending.delete(i);capture(i,'idle');}
    begun ||= Object.values(changes).some(t=>t.playing);
    feedback(list[0],(direction==='undo'?'Undo ':'Redo ')+entries.map(e=>e.label).filter((v,i,a)=>a.indexOf(v)===i).join(', '));changed();return true;
  }
  function events(label){loadHistory();return Object.fromEntries(['undo','redo'].map(direction=>[direction,[...new Map(history.flatMap(h=>h[direction]).filter(e=>e.label===label).map(e=>[e.id,e])).values()].sort((a,b)=>a.id-b.id)]));}
  function recordEdit(i,before,label){activate();const prior={serial:editSerial,tracks:clone(history)},after=clone(editState.read(i));record({[i]:after},{[i]:before},label);return ()=>{editSerial=prior.serial;history=prior.tracks;persistHistory();};}
  function primary(){const chosen=tracks.findIndex((t,i)=>t===cfg(0).primaryTrack&&hasAudio(i));return chosen>=0?chosen:tracks.findIndex((_,i)=>hasAudio(i));}
  // Musical cycle follows the session clock, never the audible playback head.
  function cycleOffset(at=beat){const p=primary(),span=p>=0?duration(p):0;return span>0?((at-cycleOrigin)%span+span)%span:0;}
  function cycleState(){const p=primary();return {primary:p>=0?tracks[p]:null,position:p>=0?cycleOffset()/duration(p):0};}
  function recordedSeconds(i){const t=editState.read(i),source=t.layers.layers.find(l=>Number.isFinite(l.seconds??l.recordedAudio?.seconds)&&l.beats>0);return t.imported?.timing?.seconds||(source?(source.seconds??source.recordedAudio.seconds)*duration(i)/source.beats:0);}
  function enforceSections(preferred){const mode=cfg(0).mode;if(!['song','band'].includes(mode))return;const bed=mode==='band'?primary():-1,playing=tracks.map((_,i)=>i).filter(i=>i!==bed&&playback(i));const chosen=playing.includes(preferred)?preferred:playing[0];for(const i of playing)if(i!==chosen){playback(i,false);positions[i]=0;}}
  function play(i){if(!hasAudio(i))return;playback(i,true);enforceSections(i);}
  function grid(i){const c=cfg(i);return ({immediate:0,loop:duration(i)||tracks.map((_,j)=>duration(j)).find(Boolean)||0,bar:c.beatsPerBar,half:2,quarter:1,eighth:.5,sixteenth:.25})[c.quantize]||0;}
  const timing=i=>({loop:'Loop start',bar:'Next bar',half:'Next 1/2 note',quarter:'Next beat',eighth:'Next 1/8 note',sixteenth:'Next 1/16 note'})[cfg(i).quantize]||'';
  function sharedPosition(i){const other=tracks.findIndex((_,j)=>j!==i&&hasAudio(j)&&playback(j));return other>=0?positions[other]:0;}
  function firstTakeTiming(i,t,at){
    const c=cfg(i);if(t.kind!=='record'||t.fixed||t.cycle||t.syncCycle||c.externalClock||c.click!=='off'||tracks.some((_,j)=>hasAudio(j)))return null;
    const seconds=t.seconds;if(seconds<=epsilon)return null;
    let best=null;for(let bars=1;bars<=64;bars++){const tempo=bars*c.beatsPerBar*60/seconds;if(tempo<30||tempo>300)continue;const score=Math.abs(Math.log(tempo/c.tempo));if(!best||score<best.score-1e-12)best={tempo,beats:bars*c.beatsPerBar,bars,seconds,score};}return best;
  }
  function closeBoundary(t){return t.syncCycle?t.start-t.syncCycle.offsetBeats+Math.ceil((beat-t.start+t.syncCycle.offsetBeats-epsilon)/t.syncCycle.beats)*t.syncCycle.beats:beat;}
  function start(i,kind,at=beat){
    if(kind==='record'&&!cfg(i).inputs.length){feedback(i,'Choose recording inputs');return;}
    const options=cfg(i);
    if(kind==='record'&&options.bars){const probe=canonicalAudio(editState.read(i),{parts:options.inputs,beats:options.bars*options.beatsPerBar,layers:[{}]},'Recording'),reason=compatibility({[i]:probe});if(reason){feedback(i,reason);capture(i,'idle');return;}}
    for(const j of [...takes.keys()])if(j!==i&&finish(j,false,at)===false)return;
    const base=tracks.map((_,j)=>j===i?0:duration(j)).find(Boolean);
    if(options.mode==='song'||options.mode==='band'&&i!==primary()){for(let j=0;j<tracks.length;j++)if(j!==i&&(options.mode==='song'||j!==primary())){playback(j,false);positions[j]=0;}}
    if(!tracks.some((_,j)=>playback(j))&&!takes.size)cycleOrigin=at;
    if(!begun)origin=at;begun=true;capture(i,kind==='record'?'recording':'overdubbing');playback(i,kind!=='record');
    const c=cfg(i),shared=c.mode==='multi'?tracks.map((_,j)=>j===i?0:duration(j)).find(Boolean):0;
    const fixed=kind==='record'?(c.bars*c.beatsPerBar||shared||0):0;
    const primaryIndex=primary(),syncCycle=kind==='record'&&base&&['sync','band'].includes(c.mode)&&!fixed?{primary:primaryIndex,beats:duration(primaryIndex),offsetBeats:cycleOffset(at)}:null;
    takes.set(i,{kind,start:at,passStart:at,seconds:0,passSeconds:0,before:clone(read(i)),fixed,windowBeats:kind==='record'&&base&&['sync','band'].includes(c.mode)?fixed:0,cycle:kind==='record'&&shared?{beats:shared,offsetBeats:sharedPosition(i)*shared}:null,syncCycle,offsetBeats:kind==='overdub'?positions[i]*duration(i):0});
    if(kind==='record')positions[i]=0;
  }
  function takeAudio(i,t,end,serial=editSerial){
    end=t.frozenAt??end;const before=clone(read(i)),amount=Math.max(0,end-t.passStart);if(amount<=epsilon)return null;
    const after=clone(before),c=cfg(i);
    if(t.kind==='record'){after.parts=[...c.inputs];after.beats=t.cycle?.beats||t.windowBeats||(t.syncCycle?Math.max(1,Math.ceil((end-t.start+t.syncCycle.offsetBeats-epsilon)/t.syncCycle.beats))*t.syncCycle.beats:Math.max(epsilon,Math.round((end-t.start)*1e9)/1e9));after.layers=[];}
    else {const keep=1-c.decay/100;for(const l of after.layers)l.gain=(l.gain??1)*keep;}
    const offsetBeats=t.cycle?.offsetBeats??t.syncCycle?.offsetBeats??t.offsetBeats??0;
    after.layers.push({id:'take-'+(serial+1),label:t.kind==='record'?'Original':'Overdub '+after.layers.length,gain:1,beats:amount,seconds:t.passSeconds,regions:[{offsetBeats,beats:amount}]});
    return after;
  }
  function layer(i,t,end,playAfter){const after=takeAudio(i,t,end);return !after||commit(i,t.kind==='record'?t.before:clone(read(i)),after,t.kind==='record'?'Recording':'Overdub',playAfter);}
  function finishReason(i,at=beat){const t=takes.get(i);at=t?.frozenAt??at;if(!t||t.kind!=='record'||at-t.start<=epsilon)return '';return compatibility({[i]:canonicalAudio(editState.read(i),takeAudio(i,t,at),'Recording')});}
  function finish(i,overdub=false,at=beat,playAfter=true){const t=takes.get(i);if(!t)return;at=t.frozenAt??at;const reason=finishReason(i,at);if(reason){feedback(i,reason+'; continue recording or Undo');return false;}
    const inferred=firstTakeTiming(i,t,at);
    if(inferred){const full=editState.read(i),audio=takeAudio(i,t,at),ratio=inferred.beats/audio.beats;audio.beats=inferred.beats;for(const l of audio.layers){l.beats*=ratio;l.regions=l.regions.map(r=>({offsetBeats:r.offsetBeats*ratio,beats:r.beats*ratio}));}const before=canonicalAudio(full,t.before,''),after=canonicalAudio(full,audio,'Recording'),journal=journalSnapshot();after.playing=playAfter;appendRecord(journal,{[i]:after},{[i]:before},'Recording',{timing:{tempo:inferred.tempo,bars:inferred.bars,seconds:inferred.seconds}});if(!publish({[i]:after},journal,i,{tempo:inferred.tempo}))return false;feedback(i,inferred.tempo.toFixed(2)+' BPM · '+inferred.bars+' '+(inferred.bars===1?'bar':'bars'));}
    else if(!layer(i,t,at,playAfter))return false;
    if(inferred)cycleOrigin=at;
    if(['finish','play'].includes(pending.get(i)?.action))pending.delete(i);takes.delete(i);capture(i,'idle');playback(i,playAfter&&hasAudio(i));if(playAfter)enforceSections(i);positions[i]=t.kind==='record'?(t.cycle?sharedPosition(i):0):positions[i];if(overdub&&hasAudio(i))start(i,'overdub',at);return true;
  }
  function execute(i,action,at=beat){pending.delete(i);if(action==='record'||action==='overdub')start(i,action,at);else if(action==='finish'){return finish(i,cfg(i).recDub,at);}else if(action==='play'){if(takes.has(i))return finish(i,false,at);else if(hasAudio(i)){if(!tracks.some((_,j)=>playback(j)))cycleOrigin=at;play(i);positions[i]=0;begun=true;capture(i,'idle');}}}
  function schedule(i,action){const c=cfg(i),first=!begun&&action==='record';
    if(c.waitingClock){if(!takes.has(i))capture(i,'armed');pending.set(i,{action,label:action==='record'?'Record':action==='overdub'?'Overdub':'Play',timing:'Waiting for clock',at:Infinity,waiting:'clock'});return;}
    if(first&&c.start==='sound'){capture(i,'armed');pending.set(i,{action,label:'Record',timing:'Waiting for sound',at:Infinity,waiting:'sound'});return;}
    const running=takes.size||tracks.some((_,j)=>playback(j));
    if(!running&&!c.externalClock&&c.countIn&&['record','play','overdub'].includes(action)){capture(i,'armed');const shared=[...pending.values()].find(p=>p.timing==='Count-in');pending.set(i,{action,label:action==='record'?'Record':action==='overdub'?'Overdub':'Play',timing:'Count-in',at:shared?.at??beat+c.countIn*c.beatsPerBar});return;}
    const take=takes.get(i);if(action==='finish'&&take?.fixed&&beat<take.start+take.fixed-epsilon){pending.set(i,{action,label:c.recDub?'Overdub':'Play',timing:'Record length',at:take.start+take.fixed});return;}
    if(action==='finish'&&take?.syncCycle){const at=closeBoundary(take);if(at>beat+epsilon){pending.set(i,{action,label:c.recDub?'Overdub':'Play',timing:'End of primary cycle',at});return;}execute(i,action);return;}
    const step=first&&!c.externalClock?0:grid(i),at=step?origin+Math.ceil((beat-origin-epsilon)/step)*step:beat;
    if(at<=beat+epsilon)execute(i,action);else pending.set(i,{action,label:action==='record'?'Record':action==='overdub'?'Overdub':action==='finish'&&c.recDub?'Overdub':'Play',timing:timing(i),at});
  }
  function advance(seconds){if(seconds<=0)return;const c=cfg(0),delta=seconds*c.tempo/60;if(!tracks.some((_,i)=>playback(i))&&![...takes.values()].some(t=>t.frozenAt===undefined))cycleOrigin+=delta;beat+=delta;if(begun)elapsed+=seconds;
    for(const t of takes.values())if(t.frozenAt===undefined){t.seconds+=seconds;t.passSeconds+=seconds;}
    tracks.forEach((_,i)=>{const t=takes.get(i),d=duration(i);if(playback(i)&&d>0){const options=cfg(i),secondsSpan=options.follow===false?recordedSeconds(i):0,old=positions[i],travel=(secondsSpan?seconds/secondsSpan:delta/d)*(options.speed||1),next=(options.reverse&&old===0?1:old)+(options.reverse?-travel:travel);positions[i]=(next%1+1)%1;if(options.once&&(options.reverse?next<=0:next>=1)&&!t){positions[i]=0;playback(i,false);playbackChanged=true;}}});
  }
  function tick(){if(!enabled)return false;const stamp=now(),seconds=Math.max(0,(stamp-last)/1000);last=stamp;playbackChanged=false;let remaining=seconds,modified=false;
    while(true){const end=beat+remaining*cfg(0).tempo/60;let at=end+1,event=null;for(const [i,p]of pending)if(p.at<=end+epsilon&&p.at<at){at=p.at;event={i,kind:'pending',action:p.action};}
      for(const [i,t]of takes){if(t.frozenAt!==undefined)continue;const boundary=t.kind==='record'?(t.fixed?t.start+t.fixed:Infinity):t.passStart+duration(i);if(boundary<=end+epsilon&&boundary<at){at=boundary;event={i,kind:t.kind};}}
      if(!event){advance(remaining);break;}const step=Math.max(0,at-beat)*60/cfg(0).tempo;advance(step);remaining=Math.max(0,remaining-step);const {i,kind}=event;
      if(kind==='pending'){if(execute(i,event.action,at)===false)freezeTake(i,at);}else if(kind==='record'){if(finish(i,cfg(i).recDub,at)===false)freezeTake(i,at);}else {const t=takes.get(i);if(layer(i,t,at)){t.passStart=at;t.passSeconds=0;}else freezeTake(i,at);}
      modified=true;
    }
    if(notice&&stamp>=notice.until){notice=null;modified=true;}
    modified ||= playbackChanged;if(modified)changed();return modified;
  }
  function cancelPending(i){if(!pending.has(i))return false;pending.delete(i);if(!takes.has(i))capture(i,'idle');return true;}
  function undo(i){
    if(cancelPending(i)){feedback(i,'Canceled');return;}
    const t=takes.get(i);
    if(t){
      const journal=journalSnapshot(),audio=takeAudio(i,t,beat,journal.serial);
      if(audio){const full=clone(editState.read(i)),prior=canonicalAudio(full,t.kind==='record'?t.before:clone(read(i)),full.length.note||''),next=canonicalAudio(full,audio,t.kind==='record'?'Recording':'Overdub');appendRecord(journal,{[i]:next},{[i]:prior},t.kind==='record'?'Recording':'Overdub');}
      if(journal.tracks[i].undo.length){if(recover([i],'undo',undefined,{journal,releasing:[i]})&&t.kind==='overdub')playback(i,hasAudio(i));}
      else {takes.delete(i);capture(i,'idle');playback(i,hasAudio(i));}
      return;
    }
    if(nextEdit(i))recover([i]);
  }
  function redo(i){if(!takes.has(i)&&!pending.has(i)&&nextEdit(i,'redo'))recover([i],'redo');}
  function freezeTake(i,at){const t=takes.get(i);if(!t)return;t.frozenAt??=at;pending.delete(i);capture(i,'idle');feedback(i,'Take held safely · Stop to retry saving or Undo');}
  function clockLost({keepPlaying=false}={}){
    activate();tick();const held=[...takes.keys()];
    for(const i of held)if(finish(i,false,beat,false)===false)freezeTake(i,beat);
    pending.clear();for(let i=0;i<tracks.length;i++){capture(i,'idle');if(!keepPlaying)playback(i,false);}
    if(!held.some(i=>takes.has(i)))feedback(held[0]??selected(),held.length?'Clock lost · Captured audio kept':'Clock lost');
    changed();return !held.some(i=>takes.has(i));
  }
  function cutSound(){
    primaryClear=null;resumeTracks=null;const saved=clockLost({keepPlaying:false});
    feedback(selected(),saved?'All sound cut':'Sound cut · Take held safely · Stop to retry or Undo');changed();return saved;
  }
  function firstTimingReview(){
    const audio=tracks.map((_,i)=>i).filter(hasAudio);if(audio.length!==1||takes.size||pending.size)return null;
    const i=audio[0],entry=nextEdit(i),timing=entry?.metadata.timing;
    if(!timing||cfg(i).externalClock||Math.abs(duration(i)-timing.bars*cfg(i).beatsPerBar)>epsilon||dismissedTiming===entry.id||Math.abs(timing.tempo-cfg(i).tempo)>epsilon)return null;
    const option=bars=>Number.isInteger(bars)&&bars>=1&&bars<=64&&bars*cfg(i).beatsPerBar*60/timing.seconds>=30&&bars*cfg(i).beatsPerBar*60/timing.seconds<=300?bars:null;
    return {track:i,id:entry.id,bars:timing.bars,tempo:timing.tempo,seconds:timing.seconds,halfBars:option(timing.bars/2),doubleBars:option(timing.bars*2)};
  }
  function adjustFirstTiming(bars){
    activate();tick();const review=firstTimingReview();if(!review||![review.halfBars,review.doubleBars].includes(bars)||bars===null)return false;
    const i=review.track,before=clone(editState.read(i)),after=clone(before),span=bars*cfg(i).beatsPerBar,ratio=span/duration(i),tempo=span*60/review.seconds,journal=journalSnapshot();
    after.length.durationBeats=span;after.length.note='Adjust timing';for(const l of after.layers.layers){l.beats*=ratio;l.regions=l.regions.map(r=>({offsetBeats:r.offsetBeats*ratio,beats:r.beats*ratio}));}
    const clock={before:{tempo:cfg(i).tempo},after:{tempo}},phase=cycleOffset()/duration(i);
    appendRecord(journal,{[i]:after},{[i]:before},'Adjust timing',{clock,cycle:{before:cycleState(),after:cycleState()},timing:{bars,tempo,seconds:review.seconds}});
    if(!publish({[i]:after},journal,i,{tempo}))return false;
    cycleOrigin=beat-phase*span;feedback(i,bars+' '+(bars===1?'bar':'bars')+' · '+tempo.toFixed(2)+' BPM');changed();return true;
  }
  function dismissFirstTiming(){dismissedTiming=firstTimingReview()?.id??null;changed();}
  function primarySuccessors(i){return tracks.map((_,j)=>j).filter(j=>j!==i&&hasAudio(j)&&tracks.every((_,k)=>{if(k===i||!hasAudio(k))return true;const ratio=Math.max(duration(j),duration(k))/Math.min(duration(j),duration(k));return Number.isFinite(ratio)&&Math.abs(ratio-Math.round(ratio))<1e-6;}));}
  function requestPrimaryClear(i){
    if(!['sync','band'].includes(cfg(0).mode)||primary()!==i||!tracks.some((_,j)=>j!==i&&hasAudio(j)))return false;
    if(takes.size||pending.size){feedback(i,'Finish or cancel recording before clearing the timing source');return true;}
    primaryClear={track:i,source:tracks[i],content:clone(read(i))};primaryClearRequested(i);return true;
  }
  function cancelPrimaryClear(){primaryClear=null;changed();}
  function resolvePrimaryClear(successor){
    activate();tick();const request=primaryClear;if(!request)return false;const i=request.track;
    if(takes.size||pending.size||primary()!==i||!same(read(i),request.content)||!primarySuccessors(i).includes(successor)){feedback(i,'Timing source changed · Cancel and choose again');changed();return false;}
    const before=Object.fromEntries(tracks.map((_,j)=>[j,clone(editState.read(j))])),after=clone(before),journal=journalSnapshot(),nextPositions=tracks.map(()=>0),clock={before:{primaryTrack:cfg(0).primaryTrack??tracks[i]},after:{primaryTrack:tracks[successor]}};
    after[i]=canonicalAudio(before[i],empty(),'Clear');for(const track of Object.values(after))track.playing=false;
    appendRecord(journal,after,before,'Clear timing source',{clock,cycle:{before:cycleState(),after:{primary:tracks[successor],position:0}},positions:{before:clone(positions),after:nextPositions}});
    if(!publish(after,journal,i,clock.after))return false;
    primaryClear=null;positions=nextPositions;cycleOrigin=beat;resumeTracks=null;feedback(successor,'Timing source · '+tracks[successor]);changed();return true;
  }
  function clearTrack(i){
    if(requestPrimaryClear(i))return;
    if(!hasAudio(i))return;
    const before=clone(editState.read(i)),after={...canonicalAudio(before,empty(),'Clear'),playing:false},journal=journalSnapshot(),lastAudio=!tracks.some((_,j)=>j!==i&&hasAudio(j)),clock=lastAudio?{before:{primaryTrack:cfg(0).primaryTrack??tracks[i]},after:{primaryTrack:null}}:null;
    appendRecord(journal,{[i]:after},{[i]:before},'Clear',clock?{clock,cycle:{before:cycleState(),after:{primary:null,position:0}}}:{});
    if(!publish({[i]:after},journal,i,clock?.after))return;
    positions[i]=0;if(lastAudio){cycleOrigin=beat;begun=false;}feedback(i,'Cleared');
  }
  function clearAll(i){
    const journal=journalSnapshot(),group=tracks.map((_,j)=>j),before=Object.fromEntries(group.map(j=>[j,clone(editState.read(j))])),beforePositions=clone(positions);
    for(const [j,t]of takes){
      const audio=takeAudio(j,t,beat,journal.serial);
      if(audio){const prior=clone(before[j]),next=canonicalAudio(prior,audio,t.kind==='record'?'Recording':'Overdub');appendRecord(journal,{[j]:next},{[j]:prior},t.kind==='record'?'Recording':'Overdub');before[j]=next;}
      before[j].playing=false;
      if(t.cycle)beforePositions[j]=sharedPosition(j);
    }
    if(!Object.values(before).some(t=>t.layers.layers.length)){
      pending.clear();takes.clear();for(const j of group){capture(j,'idle');playback(j,false);}feedback(i,'Canceled recording');return;
    }
    const reason=compatibility(before);if(reason){feedback(i,reason+' · Clear canceled');return;}
    const after=Object.fromEntries(group.map(j=>[j,{...canonicalAudio(before[j],empty(),''),playing:false}])),afterPositions=tracks.map(()=>0);
    const clock={before:{primaryTrack:cfg(0).primaryTrack??(primary()>=0?tracks[primary()]:null)},after:{primaryTrack:null}};
    appendRecord(journal,after,before,'Clear all',{positions:{before:beforePositions,after:afterPositions},clock,cycle:{before:cycleState(),after:{primary:null,position:0}}});
    if(!publish(after,journal,i,clock.after))return;
    positions=afterPositions;pending.clear();takes.clear();resumeTracks=null;primaryClear=null;cycleOrigin=beat;begun=false;
    for(const j of group)capture(j,'idle');feedback(i,'Cleared all tracks');
  }
  function command(action,i=selected()){
    activate();tick();if(i<0||i>=tracks.length)i=0;
    if(!audioReady()&&['Record / Play','Arm overdub','Start / Stop all'].includes(action)){feedback(i,'Reconnect audio');changed();return;}
    if(action==='Select'){select(i);changed();return;}
    if(primaryClear){feedback(i,'Choose a successor or cancel clearing the timing source');changed();return;}
    if([...takes.values()].some(t=>t.frozenAt!==undefined)&&!['Stop','Undo','Undo recording','Clear all'].includes(action)){feedback(i,'Take held safely · Stop to retry saving or Undo');changed();return;}
    if(action==='Start / Stop all'){const stop=takes.size>0||pending.size>0||tracks.some((_,j)=>playback(j));if(stop){command('Stop',i);return;}const mode=cfg(0).mode,bed=primary(),populated=tracks.map((_,j)=>j).filter(hasAudio),section=hasAudio(i)&&i!==bed?i:populated.find(j=>j!==bed);for(const j of populated)if(mode==='song'?j===(hasAudio(i)?i:populated[0]):mode==='band'?j===bed||j===section:true)schedule(j,'play');}
    else if(action==='Clear all')clearAll(i);
    else if(action==='Stop'){const blocked=[...takes.keys()].find(j=>finishReason(j));if(blocked!==undefined){feedback(blocked,'Length does not fit this mode; continue recording or Undo');changed();return;}for(const j of [...takes.keys()])if(finish(j,false,beat,false)===false){changed();return;}pending.clear();for(let j=0;j<tracks.length;j++){capture(j,'idle');playback(j,false);positions[j]=0;}notice=null;}
    else if(action==='Undo'||action==='Undo recording')undo(i);
    else if(action==='Redo')redo(i);
    else if(action==='Clear'||action==='Clear track'){if(takes.has(i)&&finish(i,false)===false){changed();return;}cancelPending(i);clearTrack(i);}
    else if(action==='Peel layer'){if(takes.has(i)&&finish(i,false)===false){changed();return;}const before=read(i);if(before.layers.length>1){const after=clone(before);after.layers.pop();commit(i,before,after,'Peel');feedback(i,'Peel layer');}}
    else if(action==='Arm overdub'){select(i);if(hasAudio(i)&&!takes.has(i))schedule(i,'overdub');}
    else if(action==='Record / Play'){if(!cancelPending(i)){const t=takes.get(i);schedule(i,t?.kind==='record'?'finish':t?'play':!hasAudio(i)?'record':playback(i)?'overdub':'play');}}
    changed();
  }
  function signal(input){if(!audioReady())return;activate();tick();for(const [i,p]of [...pending])if(p.waiting==='sound'&&(!input||cfg(i).inputs.includes(input))){pending.delete(i);scheduleSound(i);}changed();}
  function scheduleSound(i){const c=cfg(i);if(c.countIn&&!c.externalClock){pending.set(i,{action:'record',label:'Record',timing:'Count-in',at:beat+c.countIn*c.beatsPerBar});}else execute(i,'record');}
  function info(i){const t=takes.get(i),c=cfg(i),end=t?.frozenAt??beat,d=t?.kind==='record'?Math.max(0,end-t.start):duration(i);const loopBeats=t?.cycle?.beats||(t?.syncCycle?Math.max(1,Math.ceil((d+t.syncCycle.offsetBeats-epsilon)/t.syncCycle.beats))*t.syncCycle.beats:duration(i)),audioLayers=read(i).layers,regions=audioLayers.length?audioLayers.flatMap(l=>l.regions?clone(l.regions):[{offsetBeats:0,beats:loopBeats}]):[];if(t&&end-t.passStart>epsilon)regions.push({offsetBeats:t.cycle?.offsetBeats??t.syncCycle?.offsetBeats??t.offsetBeats??0,beats:end-t.passStart});return {sourceTempo:hasAudio(i)&&recordedSeconds(i)>0?duration(i)*60/recordedSeconds(i):null,regions,loopBeats,captureWindow:t?.fixed?t.fixed/c.beatsPerBar:t?.syncCycle?loopBeats/c.beatsPerBar:0,playing:playback(i),hasAudio:hasAudio(i),beats:d,bars:Math.round(d/c.beatsPerBar*100)/100,position:t?.kind==='record'?(t.fixed?Math.min(1,d/t.fixed):d%c.beatsPerBar/c.beatsPerBar):positions[i],layers:read(i).layers.length+(t&&end-t.passStart>epsilon?1:0)};}
  function snapshot(){loadHistory();return {active:enabled,elapsed,beat,timingCycle:{primary:primary(),beats:primary()>=0?duration(primary()):0,position:primary()>=0?cycleOffset()/duration(primary()):0},primaryClear:primaryClear?{track:primaryClear.track,successors:primarySuccessors(primaryClear.track)}:null,firstTakeTiming:firstTimingReview(),frozenRecoveries:[...takes].filter(([,t])=>t.frozenAt!==undefined).map(([track,t])=>({track,seconds:t.seconds,beats:t.frozenAt-t.start})),notice:notice?clone(notice):null,pending:[...pending].map(([track,p])=>({track,action:p.label,timing:p.timing==='Count-in'?'Count-in · '+Math.max(1,Math.ceil((p.at-beat-epsilon)/(4/Number(cfg(track).signature.split('/')[1])))):p.timing==='End of primary cycle'?'Primary cycle · '+Math.max(1,Math.ceil((p.at-beat-epsilon)/(4/Number(cfg(track).signature.split('/')[1]))))+' beats':p.timing})),tracks:tracks.map((_,i)=>({...info(i),undo:history[i].undo.length,redo:history[i].redo.length,capturing:takes.get(i)?.kind||null}))};}
  function syncTransport(action){if(!audioReady()&&action!=='stop')return;if(!['start','continue','stop'].includes(action))return;activate();tick();const blocked=[...takes.keys()].find(i=>finishReason(i));if(blocked!==undefined){feedback(blocked,'Length does not fit this mode; continue recording or Undo');changed();return;}const queued=action==='stop'?[]:[...pending].filter(([,p])=>['record','overdub'].includes(p.action));for(const i of [...takes.keys()])if(finish(i,false,beat,action!=='stop')===false){changed();return;}pending.clear();for(let i=0;i<tracks.length;i++)capture(i,'idle');
    if(action==='stop'){const playing=tracks.map((_,i)=>playback(i));if(playing.some(Boolean))resumeTracks=playing;tracks.forEach((_,i)=>playback(i,false));}
    if(action==='start'){origin=beat;cycleOrigin=beat;tracks.forEach((_,i)=>{positions[i]=0;playback(i,hasAudio(i));});resumeTracks=null;enforceSections(selected());begun=tracks.some((_,i)=>hasAudio(i));}
    if(action==='continue'){tracks.forEach((_,i)=>playback(i,hasAudio(i)&&(resumeTracks?.[i]??true)));begun ||= tracks.some((_,i)=>playback(i));resumeTracks=null;enforceSections(selected());}
    for(const [i,p]of queued)schedule(i,p.action);changed();
  }
  function songPosition(value){
    activate();tick();if(!cfg(0).externalClock||!Number.isFinite(value)||value<0||value>16383/4)return false;
    if(takes.size||pending.size||tracks.some((_,i)=>playback(i))){feedback(selected(),'Stop playback and recording before setting song position');changed();return false;}
    origin=beat-value;cycleOrigin=origin;positions=tracks.map((_,i)=>duration(i)?(value%duration(i))/duration(i):0);feedback(selected(),'Song position · '+value+' beats');changed();return true;
  }
  function clockReady(){activate();tick();for(const [i,p]of [...pending])if(p.waiting==='clock'){pending.delete(i);schedule(i,p.action);}changed();}
  function allowPlaybackChange(){tick();return true;}
  function modeChanged(resetPositions){
    if(takes.size||pending.size)return false;
    resumeTracks=null;notice=null;
    if(resetPositions){positions=tracks.map(()=>0);cycleOrigin=beat;}
    enforceSections(selected());
    return true;
  }
  return {cutSound,clockLost,songPosition,resolvePrimaryClear,cancelPrimaryClear,adjustFirstTiming,dismissFirstTiming,active,activate,reset,modeChanged,allowPlaybackChange,command,tick,signal,info,snapshot,syncTransport,clockReady,edit,editPart,editLength,recover,canRecover,nextEdit,events,recordEdit,compatibility};
};
