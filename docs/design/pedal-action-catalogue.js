// Completed performance flows shared by built-in and external assignment dispatch.
// Loop-mode shortcuts use the same compatible-only guards as Settings.
window.SegnoPerformanceActions = [
  {key:'command:record-play',label:'Record / Play',detail:'Advance recording on the selected track'},
  {key:'command:stop',label:'Stop',detail:'Stop recorded tracks'},
  {key:'command:undo',label:'Undo',detail:'Undo the latest audio edit on the selected track'},
  {key:'command:redo',label:'Redo',detail:'Redo the latest audio edit on the selected track'},
  {key:'view:wave',label:'Wave',detail:'Show waveforms with normal track controls'},
  {key:'mode:mute',label:'Mute',detail:'Enter track mute controls'},
  {key:'mode:custom',label:'Custom',detail:'Enter custom controls'},
  {key:'mode:fx',label:'FX',detail:'Enter FX controls'},
  {key:'mode:mixer',label:'Mixer',detail:'Adjust track or live input levels'},
  {key:'mode:transpose',label:'Transpose',detail:'Change recorded pitch'},
  {key:'mode:reverse',label:'Reverse',detail:'Change track playback direction'},
  {key:'mode:fade',label:'Fade',detail:'Fade tracks in or out'},
  {key:'mode:speed',label:'Speed',detail:'Change whole-loop playback speed'},
  {key:'mode:multiply',label:'Multiply',detail:'Extend a recorded track'},
  {key:'mode:divide',label:'Divide',detail:'Keep the first or last half'},
  {key:'mode:peel',label:'Peel',detail:'Remove an overdub layer'},
  {key:'mode:bounce',label:'Bounce',detail:'Combine recorded tracks'},
  {key:'mode:backing',label:'Backing track',detail:'Choose and play prepared audio'},
  {key:'mode:tuner',label:'Tuner',detail:'Tune an input'},
  {key:'command:new-loop',label:'New loop',detail:'Preserve this session and start fresh'},
  {key:'command:record-performance',label:'Record performance',detail:'Start or finish a performance recording'},
  {key:'mode:tracks',label:'Exit',detail:'Return to track controls'},
];

// Direct commands are deliberately separate from the mode-entry catalogue above.
// A target is resolved once at dispatch time; fixed tracks never follow the bank.
window.SegnoDirectActions = (() => {
  const actions=[
    {key:'command:start-stop-all',label:'Start / Stop all',group:'transport',operation:'start-stop-all'},
    {key:'command:tap-tempo',label:'Tap tempo',group:'transport',operation:'tap-tempo'},
    {key:'command:clear-all',label:'Clear all tracks',group:'transport',operation:'clear-all'},
    {key:'command:cut-sound',label:'Cut all sound',detail:'Stop tracks and backing, and end existing effect tails',group:'transport',operation:'cut-sound'},
    {key:'command:transpose-bypass',label:'Toggle transpose',detail:'Bypass or enable all tracks without changing stored pitches',group:'transport',operation:'transpose-bypass',scope:'all'},
    ...[['multi','Multi'],['sync','Sync'],['song','Song'],['band','Band'],['free','Free']].map(([value,name])=>({key:'loop-mode:'+value,label:name+' loop mode',detail:'Keep compatible recordings · confirm before stopping loops',group:'loop-modes',operation:'loop-mode',value})),
    ...[.5,1,2,4,8].map(value=>({key:'direct:speed:'+value,label:(value===.5?'Half speed':value===1?'Normal speed':value===2?'Double speed':value+'× speed'),group:'transport',operation:'speed',scope:'all',value})),
    ...Array.from({length:8},(_,i)=>({key:'track:'+i,label:'Track '+(i+1)+' pedal',detail:'Select this track and advance Record / Play',group:'tracks',operation:'track-pedal',scope:i})),
    ...Array.from({length:8},(_,i)=>({key:'select-track:'+i,label:'Select track '+(i+1),detail:'Change the selected track',group:'tracks',operation:'select-track',scope:i})),
    {key:'bank:next',label:'Next bank',detail:'Switch track bank A / B',group:'tracks',operation:'bank'},
    ...Array.from({length:8},(_,i)=>({key:'fx:'+i,label:'FX '+(i<4?'A':'B')+(i%4+1),detail:'Use this FX assignment · release follows source',group:'fx',operation:'fx',slot:i})),
    ...[['rewind','Rewind backing'],['stop','Stop backing'],['play','Play / Pause backing'],['forward','Fast forward backing'],['previous','Previous backing track'],['next','Next backing track']].map(([value,label])=>({key:'backing:'+value,label,group:'backing',operation:'backing',value})),
    ...[['previous','Load previous session'],['next','Load next session'],['save','Save session']].map(([value,label])=>({key:'session:'+value,label,group:'sessions',operation:'session',value})),
  ];
  const operations=[['mute','Mute'],['solo','Solo'],['reverse','Reverse'],['fade','Fade'],['pitch-step','Pitch +1 semitone',1],['pitch-step','Pitch −1 semitone',-1],['pitch-reset','Reset pitch'],['clear','Clear'],['peel','Peel'],['restore-peel','Restore peeled layer'],['multiply','Double length'],['divide','Keep first half','first'],['divide','Keep last half','last'],['undo-length','Undo length'],['undo','Undo audio edit'],['redo','Redo audio edit']];
  for(const scope of ['selected','all',...Array.from({length:8},(_,i)=>i)])for(const [operation,name,value] of operations){
    if(scope==='all'&&operation==='clear')continue;
    const target=scope==='selected'?'Selected track':scope==='all'?'All tracks':'Track '+(scope+1);
    actions.push({key:'direct:'+operation+':'+scope+(value!==undefined?':'+value:''),label:target+' · '+name,detail:scope==='selected'?'Uses the selected track when triggered':scope==='all'?'Applies to all eight tracks':'Fixed track · independent of bank',group:scope==='selected'?'selected':scope==='all'?'all':'fixed',operation,scope,value});
  }
  return actions;
})();
window.SegnoAssignableActions = [...window.SegnoPerformanceActions.map(a=>({...a,group:'functions'})),...window.SegnoDirectActions];
window.SegnoMappingActionGroups=[['functions','Modes & functions'],['transport','Loop transport'],['loop-modes','Loop modes'],['selected','Selected track'],['fixed','Fixed tracks'],['all','All tracks'],['tracks','Track pedals & bank'],['fx','FX pedals'],['instruments','Instruments'],['backing','Backing'],['sessions','Sessions']];
// Instrument definitions own their identity. Names can change without rewriting
// controller assignments, and removed instruments disappear from every picker.
window.setSegnoInstrumentActions = instruments => {
  const actions=instruments.flatMap(instrument=>['notes','sustain'].flatMap(kind=>['held','latch'].map(behavior=>({
    key:`instrument:${instrument.id}:${kind}:${behavior}`,
    label:instrument.name+' · '+(kind==='notes'?'Play notes':'Sustain')+' · '+(behavior==='held'?'Held':'Latch'),
    detail:kind==='notes'?'Play this instrument’s saved note or chord':behavior==='held'?'Sustain while this control is held':'Toggle this instrument’s sustain',
    group:'instruments',operation:'instrument',instrument:instrument.id,kind,behavior,
  }))));
  for(const catalogue of [window.SegnoDirectActions,window.SegnoAssignableActions]){
    const remaining=catalogue.filter(action=>action.operation!=='instrument');
    catalogue.splice(0,catalogue.length,...remaining,...actions);
  }
};
// Evidence index only: Segno uses Learn, not a reserved CC3/note-number protocol.
window.SegnoReferenceMidiActions = (()=>{
 const m={0:'command:start-stop-all',6:'command:tap-tempo',15:'direct:divide:all:first',16:'direct:multiply:all',17:'direct:speed:0.5',18:'direct:speed:2',23:'direct:mute:all',24:'command:clear-all',29:'direct:reverse:all',34:'direct:fade:all',43:'direct:pitch-step:all:1',44:'direct:pitch-step:all:-1',57:'backing:rewind',58:'backing:stop',59:'backing:play',60:'backing:forward',63:'backing:previous',64:'backing:next',65:'session:previous',66:'session:next',76:'command:record-play',77:'command:stop',78:'mode:mute',79:'mode:custom'};
 for(let i=0;i<4;i++){m[1+i]='fx:'+i;m[19+i]='direct:mute:'+i;m[25+i]='direct:reverse:'+i;m[30+i]='direct:fade:'+i;m[35+i]='direct:pitch-step:'+i+':1';m[39+i]='direct:pitch-step:'+i+':-1';m[49+i]='direct:clear:'+i;m[53+i]='direct:peel:'+i;m[68+i]='direct:solo:'+i;m[72+i]='track:'+i;}
 return m;
})();
