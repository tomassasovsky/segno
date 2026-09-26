// Interactive design study, isolated from the FX rig and all audio processing.
window.createLoopStudy = ({button, header, icon, getSettings, go, back, render, save, setFocus, recording, modeContext, commitMode, confirmMode, closeMode, tracks, trackLabel, escape, externalClock=()=>false, allowPlaybackChange=()=>true, primarySummary=()=>'', review=''}) => {
  const modes = [
    ['multi', 'Multi', 'Tracks share one loop length.'],
    ['sync', 'Sync', 'Different lengths, in time.'],
    ['song', 'Song', 'One section at a time.'],
    ['band', 'Band', 'Rhythm beneath changing sections.'],
    ['free', 'Free', 'Each track loops independently.'],
  ];
  let modeError='';
  function modeAvailability(key){
    const context=modeContext(),audio=context.tracks.filter(t=>t.hasAudio);
    if(recording())return {enabled:false,reason:'Finish recording to change loop mode.'};
    if(context.pending)return {enabled:false,reason:'Finish or cancel the queued action first.'};
    if(!modes.some(m=>m[0]===key))return {enabled:false,reason:'Unknown loop mode.'};
    if(key===state().mode||!audio.length)return {enabled:true,reason:''};
    if(audio.some(t=>!Number.isFinite(t.beats)||t.beats<=0))return {enabled:false,reason:'Track lengths are unavailable.'};
    const near=(a,b)=>Math.abs(a-b)<=1e-6*Math.max(1,a,b);
    if(key==='multi'&&audio.some(t=>!near(t.beats,audio[0].beats)))return {enabled:false,reason:'Tracks need equal lengths.'};
    if(['sync','band'].includes(key)){
      const primary=audio.find(t=>t.id===state().primaryTrack)||audio[0];
      const fits=audio.every(t=>{const ratio=Math.max(t.beats,primary.beats)/Math.min(t.beats,primary.beats);return near(ratio,Math.round(ratio));});
      if(!fits)return {enabled:false,reason:'Lengths must follow '+primary.id+'.'};
    }
    return {enabled:true,reason:''};
  }
  function changeMode(key,confirmed=false){
    modeError='';
    if(!modeAvailability(key).enabled){render();return true;}
    if(key===state().mode){closeMode();render();return true;}
    if(modeContext().tracks.some(t=>t.playing)&&!confirmed){confirmMode(key,modes.find(m=>m[0]===key)[1]);return true;}
    if(!commitMode(key)){modeError=modeAvailability(key).reason||'Could not save loop mode. Try again.';render();return true;}
    closeMode();render();setFocus('loop:mode:'+key);return true;
  }
  const signatures = [...[2,3,4,5,6,7].map(n=>n+'/4'), ...Array.from({length:11},(_,i)=>(i+5)+'/8')];
  let fineTempo = false, tempoEdit = null, lengthEdit = null, decayEdit = null, target = 'defaults', rememberedBars = {}, taps = [], tapBeat = -1;
  const tempoBaseline = getSettings().tempo;
  const state = () => getSettings();
  const lengths = () => state().lengthTiming ||= {bars:0,quantize:'immediate'};
  const overrides = () => state().trackLengthTiming ||= {};
  const raw = (scope=target) => scope==='defaults'?lengths():overrides()[scope]||{};
  const sharedLength = () => target!=='defaults'&&state().mode==='multi';
  const effective = (scope=target) => ({...lengths(),...raw(scope),...(scope!=='defaults'&&state().mode==='multi'?{bars:lengths().bars}:{})});
  const write = (field,value,scope=target) => {
    const settings=scope==='defaults'?lengths():(overrides()[scope] ||= {});
    if(value===undefined)delete settings[field];else settings[field]=value;
    if(scope!=='defaults'&&!Object.keys(settings).length)delete overrides()[scope];
  };
  const playback = () => state().playback ||= {once:false,decay:0};
  const playbackOverrides = () => state().trackPlayback ||= {};
  const rawPlayback = (scope=target) => scope==='defaults'?playback():playbackOverrides()[scope]||{};
  const effectivePlayback = (scope=target) => ({...playback(),...rawPlayback(scope)});
  const writePlayback = (field,value,scope=target) => {
    const settings=scope==='defaults'?playback():(playbackOverrides()[scope] ||= {});
    if(value===undefined)delete settings[field];else settings[field]=value;
    if(scope!=='defaults'&&!Object.keys(settings).length)delete playbackOverrides()[scope];
  };
  const playbackOrigin = field => target==='defaults'?'':Object.hasOwn(rawPlayback(),field)?'Custom':'Default';
  const playbackLabel = (title,field) => `<div class="length-label"><h2>${title}</h2><span data-playback-origin="${field}" class="field-origin ${playbackOrigin(field)==='Custom'?'custom':''}">${playbackOrigin(field)}</span></div>`;
  const playbackRestore = field => button('loop:playback-inherit:'+field,'Use default','quiet restore-default',`aria-label="Use default ${field==='once'?'playback':'overdub decay'}" ${target==='defaults'||!Object.hasOwn(rawPlayback(),field)?'hidden':''}`);
  const decayText = value => value===0?'Earlier layers stay at full volume.':value===100?'Each overdub pass replaces earlier audio.':`Keeps ${100-value}% of earlier audio each overdub pass.`;
  const audioTempo = () => state().audioTempo ||= {follow:true,keepPitch:true};
  const audioTempoOverrides = () => state().trackAudioTempo ||= {};
  const rawAudioTempo = (scope=target) => scope==='defaults'?audioTempo():audioTempoOverrides()[scope]||{};
  const effectiveAudioTempo = (scope=target) => ({...audioTempo(),...rawAudioTempo(scope)});
  const writeAudioTempo = (field,value) => {
    const settings=target==='defaults'?audioTempo():(audioTempoOverrides()[target] ||= {});
    if(value===undefined)delete settings[field];else settings[field]=value;
    if(target!=='defaults'&&!Object.keys(settings).length)delete audioTempoOverrides()[target];
  };
  const audioTempoOrigin = field => target==='defaults'?'':Object.hasOwn(rawAudioTempo(),field)?'Custom':'Default';
  const audioTempoLabel = (title,field) => `<div class="length-label"><h2>${title}</h2>${audioTempoOrigin(field)?`<span class="field-origin ${audioTempoOrigin(field)==='Custom'?'custom':''}">${audioTempoOrigin(field)}</span>`:''}</div>`;
  const audioTempoRestore = field => target!=='defaults'&&Object.hasOwn(rawAudioTempo(),field)?button('loop:audio-tempo-inherit:'+field,'Use default','quiet restore-default',`aria-label="Use default ${field==='follow'?'tempo following':'pitch behavior'}"`):'';
  const scopeSelector = label => `<div class="length-scopes" role="group" aria-label="${label}"><h2>Tracks</h2><div class="scope-controls">${button('loop:scope:defaults','Defaults','scope-tab scope-defaults '+(target==='defaults'?'selected':''),`aria-pressed="${target==='defaults'}"`)}${tracks.map((t,i)=>button('loop:scope:'+t,i+1,'scope-tab '+(t===target?'selected':''),`aria-pressed="${t===target}" aria-label="${escape(trackLabel(t))}"`)).join('')}${target!=='defaults'&&trackLabel(target)!==target?`<span class="selected-track-name">${escape(trackLabel(target).slice(target.length+3))}</span>`:''}</div></div>`;
  const origin = field => target==='defaults'?'':field==='bars'&&sharedLength()?'Shared in Multi':Object.hasOwn(raw(),field)?'Custom':'Default';
  const fieldLabel = (title,field) => `<div class="length-label"><h2>${title}</h2>${origin(field)?`<span class="field-origin ${origin(field)==='Custom'?'custom':''}">${origin(field)}</span>`:''}</div>`;
  const restore = field => target!=='defaults'&&Object.hasOwn(raw(),field)&&!(field==='bars'&&sharedLength())?button('loop:inherit:'+field,'Use default','quiet restore-default',`aria-label="Use default ${field==='bars'?'loop length':'record timing'}" ${recording()?'disabled':''}`):'';
  const quantizeOptions = [['immediate','Immediately'],['loop','Loop start'],['bar','1 bar'],['half','1/2 note'],['quarter','1/4 note'],['eighth','1/8 note'],['sixteenth','1/16 note']];
  if(['loop-length-fixed','loop-length-locked','loop-length-midi'].includes(review)){lengths().bars=4;lengths().quantize='bar';}
  if(review.startsWith('loop-track-')){
    target='Track 3';state().mode=review==='loop-track-multi'?'multi':'sync';lengths().bars=4;lengths().quantize='bar';
    if(review!=='loop-track-default')overrides()[target]={bars:8,quantize:'quarter'};
  }
  if(review.startsWith('loop-playback-')){
    target='Track 3';
    if(review!=='loop-playback-default')playbackOverrides()[target]={once:true,decay:25};
  }
  if(review.startsWith('loop-audio-tempo-')){
    target='Track 3';
    if(review==='loop-audio-tempo-original')audioTempoOverrides()[target]={follow:false,keepPitch:false};
    if(review==='loop-audio-tempo-pitch')audioTempoOverrides()[target]={keepPitch:false};
  }
  const external = externalClock;
  const lock = () => recording()?'Finish recording to change these settings.':external()?'Tempo follows MIDI clock.':'';
  const chosen = (action, label, selected, disabled=false) => button(action, label, 'loop-choice '+(selected?'chosen':''), `aria-pressed="${selected}" ${disabled?'disabled':''}`);
  const notice = message => message?`<div class="loop-lock" role="status">${message}</div>`:'';
  const modeGraphic = key => {
    const patterns = {
      multi: [[[0,100]], [[0,100]], [[0,100]]],
      sync: [[[0,22],[26,22],[52,22],[78,22]], [[0,48],[52,48]], [[0,100]]],
      song: [[[0,30]], [[35,30]], [[70,30]]],
      band: [[[0,100]], [[0,48]], [[52,48]]],
      free: [[[0,37],[42,37]], [[15,61]], [[3,24],[33,24],[63,24]]],
    };
    return `<span class="mode-graphic" aria-hidden="true">${patterns[key].map(segments=>`<span class="mode-track">${segments.map(([left,width])=>`<span class="mode-loop" style="left:${left}%;width:${width}%"></span>`).join('')}</span>`).join('')}</span>`;
  };
  function body(page){
    const s=state();
    if(page==='loop-settings')return header('Loop settings','')+`<div class="loop-menu">${[
      ['loop-mode','Loop mode',modes.find(m=>m[0]===s.mode)[1]],
      ['loop-recording','Recording',s.recDub?'Record · Overdub · Play':'Record · Play · Overdub'],
      ['loop-timing','Tempo & click',s.tempo+' BPM · '+s.signature],
      ['loop-length','Length & quantize',(lengths().bars?lengths().bars+' bars':'Auto')+' · '+quantizeOptions.find(q=>q[0]===lengths().quantize)[1]],
      ['loop-playback','Playback & overdub',(playback().once?'Once':'Loop')+' · '+(playback().decay?playback().decay+'% decay':'No decay')],
      ['loop-audio-tempo','Audio & tempo',!audioTempo().follow?'Original speed':audioTempo().keepPitch?'Follow tempo · Same pitch':'Follow tempo · Pitch changes'],
    ].map(([target,title,value])=>button('loop:page:'+target,`<span>${title}</span><span class="loop-summary">${value}</span>${icon('right')}`,'loop-menu-row')).join('')}${['sync','band'].includes(s.mode)?button('primary:open',`<span>Timing source</span><span class="loop-summary">${escape(primarySummary()||'First recording')}</span>${icon('right')}`,'loop-menu-row'):''}</div>`;
    if(page==='loop-mode'){
      const busy=recording()?'Finish recording to change loop mode.':modeContext().pending?'Finish or cancel the queued action first.':'';
      return header('Loop mode','')+notice(modeError||busy)+`<div class="mode-choices">${modes.map(([key,label,description])=>{const choice=modeAvailability(key),reason=busy?'':choice.reason;return chosen('loop:mode:'+key,`<span class="mode-heading"><span class="mode-name">${label}</span><span class="mode-selected" aria-hidden="true">${s.mode===key?icon('check'):''}</span></span>${modeGraphic(key)}<span class="mode-description ${reason?'mode-reason':''}">${reason||description}</span>`,s.mode===key,!choice.enabled);}).join('')}</div>`;
    }
    if(page==='loop-recording')return header('Recording','')+notice(recording()?'Finish recording to change recording behavior.':'')+`<div class="recording-layout"><section class="recording-decision"><h2>Start recording</h2><div class="loop-pairs">${chosen('loop:start:press','Pedal',s.start==='press',recording())}${chosen('loop:start:sound','Sound',s.start==='sound',recording())}</div><p class="recording-note">${s.start==='sound'?'Press Record to arm, then play.':s.countIn?`From stopped: ${s.countIn}-bar count-in. While playing: follows Record timing.`:'Starts when you press Record.'}</p></section><section class="recording-decision"><h2>Second pedal press</h2><div class="loop-pairs">${chosen('loop:recDub:false','Play',!s.recDub,recording())}${chosen('loop:recDub:true','Overdub',s.recDub,recording())}</div></section></div>`;
    if(page==='loop-timing')return header('Tempo & click','')+(external()?'<div class="timing-clock-owner">'+notice(lock())+button('sync:open','Clock & sync','quiet')+'</div>':notice(lock()))+`<div class="timing-layout"><section class="tempo-strip"><div class="tempo-value"><div class="tempo-readout"><output data-loop-tempo>${s.tempo.toFixed(2)}</output><span>${external()?'MIDI clock':'BPM'}</span></div><div class="beat-strip" aria-hidden="true">${Array.from({length:Number(s.signature.split('/')[0])},(_,i)=>`<span class="beat-cell ${i===0?'downbeat':''} ${i===tapBeat?'tap-hit':''}"></span>`).join('')}</div></div><div class="tempo-controls"><label class="inline-control tempo-rail"><input type="range" data-action="loop:tempo" min="30" max="300" step=".01" value="${s.tempo}" style="--amount:${(s.tempo-30)/270*100}%" aria-label="Tempo" aria-valuetext="${s.tempo} BPM" ${recording()||external()?'disabled':''}></label><div class="tempo-tools"><div class="tempo-resolution" role="group" aria-label="Tempo adjustment">${button('loop:tempo-step:coarse','1 BPM',fineTempo?'quiet':'selected',recording()||external()?'disabled':'')}${button('loop:tempo-step:fine','0.01 BPM',fineTempo?'selected':'quiet',recording()||external()?'disabled':'')}</div>${button('loop:tap','Tap tempo','tap-tempo',recording()||external()?'disabled':'')}</div></div><div class="tempo-signature"><h2>Time signature</h2>${button('loop:page:loop-signature',s.signature+icon('down'),'quiet icon-label',recording()?'disabled':'')}</div></section><div class="timing-options"><section><h2>Hear click</h2><div class="loop-four">${[['off','Off'],['first','First recording'],['rec','Recording'],['always','Play & record']].map(([key,label])=>chosen('loop:click:'+key,label,s.click===key,recording())).join('')}</div></section><section><h2>Count-in</h2><div class="loop-four">${[0,1,2,4].map(n=>chosen('loop:countIn:'+n,n===0?'Off':n+' '+(n===1?'bar':'bars'),s.countIn===n,recording())).join('')}</div><p class="recording-note">${external()?'External clock starts directly.':'Before Record, Overdub or Play from stopped.'}</p></section></div></div>`;
    if(page==='loop-length'){
      const l=effective(),lengthLocked=recording()||sharedLength();
      const timingNote=l.quantize==='immediate'?'Record and overdub respond as soon as you press.':`Record and overdub wait for ${l.quantize==='loop'?'the loop to restart':l.quantize==='bar'?'the next bar':'the next '+quantizeOptions.find(q=>q[0]===l.quantize)[1]}. The first loop follows Recording settings.`;
      const scopes=scopeSelector('Length and timing for');
      return header('Length & quantize','')+scopes+notice(recording()?'Finish recording to change length or timing.':'')+`<div class="length-timing"><section class="length-section">${fieldLabel('Loop length','bars')}<div class="length-controls"><div class="length-kind">${chosen('loop:length:auto','Auto',!l.bars,lengthLocked)}${chosen('loop:length:fixed','Bars',!!l.bars,lengthLocked)}</div>${l.bars?`<div class="bars-stepper">${button('loop:bars-step:-1',icon('minus'),'quiet',`aria-label="Shorter loop" ${lengthLocked||l.bars===1?'disabled':''}`)}${button('loop:bars',`<span>${l.bars}</span><span>${l.bars===1?'bar':'bars'}</span>`,'bars-value'+(lengthEdit?' adjusting':''),`aria-label="Loop length: ${l.bars} ${l.bars===1?'bar':'bars'}" ${lengthLocked?'disabled':''}`)}${button('loop:bars-step:1',icon('plus'),'quiet',`aria-label="Longer loop" ${lengthLocked||l.bars===64?'disabled':''}`)}</div>`:''}${restore('bars')}</div><p class="length-note">${sharedLength()?'All tracks share the length set in Defaults.':!l.bars?(['sync','band'].includes(s.mode)&&modeContext().tracks.some(t=>t.hasAudio)?'Press again to finish with the primary cycle.':'Press the pedal again to set the length.'):`Ends after ${l.bars} ${l.bars===1?'bar':'bars'}, then ${s.recDub?'overdubs':'plays'}.`}</p></section><section class="quantize-section"><div class="quantize-heading">${fieldLabel('Record timing','quantize')}${restore('quantize')}</div><div class="quantize-options">${quantizeOptions.map(([key,label])=>chosen('loop:quantize:'+key,label,l.quantize===key,recording())).join('')}</div><p class="length-note">${timingNote}</p></section></div>`;
    }
    if(page==='loop-playback'){
      const p=effectivePlayback();
      return header('Playback & overdub','')+scopeSelector('Playback and overdub for')+`<div class="playback-layout"><section class="playback-section">${playbackLabel('Playback','once')}<div class="playback-choices">${chosen('loop:once:false',icon('repeat')+'<span>Loop</span>',!p.once)}${chosen('loop:once:true',icon('once')+'<span>Once</span>',p.once)}${playbackRestore('once')}</div><p class="playback-note">${p.once?'Plays to the end, then stops.':'Repeats until you stop it.'}</p></section><section class="playback-section decay-section">${playbackLabel('Overdub decay','decay')}<div class="decay-controls"><div class="decay-readout"><output data-loop-decay>${p.decay===0?'Off':p.decay+'%'}</output>${playbackRestore('decay')}</div><label class="inline-control decay-rail"><input type="range" data-action="loop:decay" min="0" max="100" step="1" value="${p.decay}" style="--amount:${p.decay}%" aria-label="Overdub decay" aria-valuetext="${p.decay}% decay"></label><div class="decay-ends"><span>Keep layers</span><span>Replace layers</span></div></div><p class="playback-note" data-decay-note>${decayText(p.decay)} Playback is unchanged.</p></section></div>`;
    }
    if(page==='loop-audio-tempo'){
      const a=effectiveAudioTempo();
      return header('Audio & tempo','')+scopeSelector('Audio tempo behavior for')+`<div class="audio-tempo-layout"><section class="playback-section">${audioTempoLabel('Follow tempo','follow')}<div class="audio-tempo-choices">${chosen('loop:audio-tempo:follow:false',icon('original')+'<span>Off</span>',!a.follow)}${chosen('loop:audio-tempo:follow:true',icon('tempoFollow')+'<span>On</span>',a.follow)}${audioTempoRestore('follow')}</div><p class="playback-note">${a.follow?`Recorded audio follows ${external()?'MIDI clock':'the song tempo'}.`:'Keeps its recorded speed, even when the song tempo changes.'}</p></section><section class="playback-section pitch-section">${a.follow?audioTempoLabel('Pitch','keepPitch'):'<div class="length-label"><h2>Pitch</h2></div>'}${a.follow?`<div class="audio-tempo-choices pitch-choices">${chosen('loop:audio-tempo:keepPitch:true',icon('pitchHold')+'<span>Unchanged</span>',a.keepPitch)}${chosen('loop:audio-tempo:keepPitch:false',icon('pitchFollow')+'<span>Follows speed</span>',!a.keepPitch)}${audioTempoRestore('keepPitch')}</div><p class="playback-note">${a.keepPitch?'Changes speed without changing the notes.':'Faster raises the pitch. Slower lowers it.'}</p>`:`<div class="original-pitch">${icon('pitchHold')}<span>Unchanged</span></div><p class="playback-note">Pitch stays unchanged at the recorded speed.</p>`}</section></div>`;
    }
    if(page==='loop-signature')return header('Time signature','')+`<div class="signature-grid">${signatures.map(sig=>chosen('loop:signature:'+sig,sig,s.signature===sig,recording())).join('')}</div>`;
    return '';
  }
  function finish(cancel=false){
    if(decayEdit){
      if(cancel)writePlayback('decay',decayEdit.original,decayEdit.target);
      decayEdit=null;save();render();return true;
    }
    if(lengthEdit){
      if(cancel)write('bars',lengthEdit.original,lengthEdit.target);
      const value=effective(lengthEdit.target).bars;if(value)rememberedBars[lengthEdit.target]=value;
      lengthEdit=null;save();render();return true;
    }
    if(!tempoEdit)return false;
    if(cancel)state().tempo=tempoEdit.original;
    tempoEdit=null;save();render();return true;
  }
  function action(id){if(!id.startsWith('loop:'))return false;const [,key,value]=id.split(':');const s=state();
    if(key==='mode'||key==='mode-confirm')return changeMode(value,key==='mode-confirm');
    if(key==='page'){if(value==='loop-signature'&&(recording()))return true;finish();go(value);return true;}
    if(key==='scope'&&['defaults',...tracks].includes(value)){finish(true);target=value;render();return true;}
    if(key==='audio-tempo'){
      const field=value,valuePart=id.split(':')[3];
      if(!['follow','keepPitch'].includes(field)||!['true','false'].includes(valuePart)||field==='keepPitch'&&!effectiveAudioTempo().follow)return true;
      if(field==='follow'&&!allowPlaybackChange(target))return true;finish();writeAudioTempo(field,valuePart==='true');save();render();return true;
    }
    if(key==='audio-tempo-inherit'&&target!=='defaults'&&['follow','keepPitch'].includes(value)){
      if(value==='keepPitch'&&!effectiveAudioTempo().follow)return true;
      if(value==='follow'&&!allowPlaybackChange(target))return true;finish();writeAudioTempo(value,undefined);save();render();setFocus('loop:audio-tempo:'+value+':'+effectiveAudioTempo()[value]);return true;
    }
    // Target product: these controls remain available during playback/capture
    // in all modes. Current native limitations are recorded in the design doc.
    if(key==='once'){if(!allowPlaybackChange(target))return true;finish();writePlayback('once',value==='true');save();render();return true;}
    if(key==='playback-inherit'&&target!=='defaults'&&['once','decay'].includes(value)){if(value==='once'&&!allowPlaybackChange(target))return true;finish(true);writePlayback(value,undefined);save();render();return true;}
    if(key==='decay'){finish();decayEdit={original:rawPlayback().decay,target};render();return true;}
    if(recording())return true;
    if(key==='inherit'&&target!=='defaults'&&['bars','quantize'].includes(value)){if(value==='bars'&&sharedLength())return true;finish(true);write(value,undefined);}
    if(key==='length'){if(sharedLength())return true;finish();if(effective().bars)rememberedBars[target]=effective().bars;write('bars',value==='auto'?0:rememberedBars[target]||4);}
    if(key==='bars'){if(sharedLength()||!effective().bars)return true;if(lengthEdit)return finish();lengthEdit={original:raw().bars,target};render();return true;}
    if(key==='bars-step'){if(sharedLength()||!effective().bars)return true;finish();write('bars',Math.max(1,Math.min(64,effective().bars+Number(value))));rememberedBars[target]=effective().bars;}
    if(key==='quantize'&&quantizeOptions.some(q=>q[0]===value)){finish();write('quantize',value);}
    if(key==='recDub')s.recDub=value==='true';
    if(key==='start'){s.start=value;if(value==='sound')s.countIn=0;}
    if(key==='click')s.click=value;
    if(key==='countIn'){s.countIn=Number(value);if(s.countIn)s.start='press';}
    if(key==='signature'){s.signature=value;save();back();return true;}
    if(key==='tempo-step'){if(recording()||external())return true;finish();fineTempo=value==='fine';setFocus('loop:tempo');render();return true;}
    if(key==='tempo'){if(external())return true;if(tempoEdit)return finish();tempoEdit={original:s.tempo};render();return true;}
    if(key==='tap'&&!external()){const now=performance.now();if(taps.length&&now-taps.at(-1)>2000)taps=[];taps.push(now);taps=taps.slice(-5);tapBeat=(tapBeat+1)%Number(s.signature.split('/')[0]);if(taps.length>1)s.tempo=Math.max(30,Math.min(300,Math.round(60000*(taps.length-1)/(taps.at(-1)-taps[0]))));}
    save();render();return true;
  }
  return {body,action,finish,modeAvailability,get modeError(){return modeError;},
    snapshot:()=>({modeAvailability:Object.fromEntries(modes.map(m=>[m[0],modeAvailability(m[0])])),modeError,target,effective:effective(),origins:{bars:origin('bars'),quantize:origin('quantize')},playback:effectivePlayback(),playbackOrigins:{once:playbackOrigin('once'),decay:playbackOrigin('decay')},audioTempo:effectiveAudioTempo(),audioTempoOrigins:{follow:audioTempoOrigin('follow'),keepPitch:audioTempoOrigin('keepPitch')},effectivePitch:effectiveAudioTempo().follow&&!effectiveAudioTempo().keepPitch?'follows-speed':'unchanged'}),
    get editing(){return tempoEdit!==null||lengthEdit!==null||decayEdit!==null;},
    get editingAction(){return decayEdit?'loop:decay':tempoEdit?'loop:tempo':lengthEdit?'loop:bars':null;},
    touchBegin(action){if(action==='loop:decay')decayEdit=null;else tempoEdit=null;},
    reset(action){if(action==='loop:decay'){decayEdit=null;writePlayback('decay',target==='defaults'?0:undefined);save();render();return;}if(recording()||external())return;tempoEdit=null;state().tempo=tempoBaseline;save();render();},
    turn(delta){if(decayEdit){writePlayback('decay',Math.max(0,Math.min(100,effectivePlayback().decay+delta)));render();return true;}if(lengthEdit){write('bars',Math.max(1,Math.min(64,effective().bars+delta)));render();return true;}if(!tempoEdit)return false;state().tempo=Math.max(30,Math.min(300,Math.round((state().tempo+delta*(fineTempo?.01:1))*100)/100));render();return true;},
    input(value,action){if(action==='loop:decay'){writePlayback('decay',Math.max(0,Math.min(100,Number(value))));return;}if(recording()||external())return;state().tempo=Number(value);},
    refreshDecay(root){const value=effectivePlayback().decay;root.querySelector('[data-loop-decay]').textContent=value===0?'Off':value+'%';root.querySelector('[data-decay-note]').textContent=decayText(value)+' Playback is unchanged.';const o=root.querySelector('[data-playback-origin="decay"]');o.textContent=playbackOrigin('decay');o.classList.toggle('custom',playbackOrigin('decay')==='Custom');root.querySelector('[data-action="loop:playback-inherit:decay"]').hidden=target==='defaults'||!Object.hasOwn(rawPlayback(),'decay');},
    persisted(){
      const result=JSON.parse(JSON.stringify(state()));
      if(lengthEdit){
        const scope=lengthEdit.target;
        const settings=scope==='defaults'?result.lengthTiming:((result.trackLengthTiming ||= {})[scope] ||= {});
        if(lengthEdit.original===undefined)delete settings.bars;else settings.bars=lengthEdit.original;
        if(scope!=='defaults'&&!Object.keys(settings).length)delete result.trackLengthTiming[scope];
      }
      if(tempoEdit)result.tempo=tempoEdit.original;
      if(decayEdit){
        const scope=decayEdit.target;
        const settings=scope==='defaults'?result.playback:((result.trackPlayback ||= {})[scope] ||= {});
        if(decayEdit.original===undefined)delete settings.decay;else settings.decay=decayEdit.original;
        if(scope!=='defaults'&&!Object.keys(settings).length)delete result.trackPlayback[scope];
      }
      return result;
    },
  };
};
