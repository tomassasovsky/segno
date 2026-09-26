// Silent target UX: one playback or live-monitor channel at a time.
window.createMixerPerformanceStudy = ({state, muteState, trackNames, currentTrack, transport, fadeState}) => {
  const increment = 5;
  let kind = 'tracks', page = 0, selected = -1;
  const esc = s => String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  const channels = () => state.channels(kind);
  const channel = () => channels()[selected];
  const available = c => !!c && c.available;
  const gain = c => state.get(c.id);
  const level = c => Math.round(gain(c) * 1000) / 10;
  const limit = () => kind === 'inputs' ? 100 : 200;
  const muted = c => kind === 'tracks' ? muteState.get(c.track) : state.muted(c.id);
  const canStep = delta => available(channel()) && level(channel()) + delta >= 0 && level(channel()) + delta <= limit();
  const pageCount = () => Math.max(1, Math.ceil(channels().length / 4));
  function enter() {kind = 'tracks'; selected = available(channels()[currentTrack()]) ? currentTrack() : channels().findIndex(available); page = selected < 0 ? 0 : Math.floor(selected / 4);}
  function setKind(value) {kind=value; page=0; selected=channels().findIndex(available); if(selected>=0)page=Math.floor(selected/4);}
  function nextPage() {page=(page+1)%pageCount();const first=channels().findIndex((c,i)=>Math.floor(i/4)===page&&available(c));selected=first;}
  function assignments(id) {
    if(id===9)return {press:'Next channels',hold:kind==='tracks'?'Mixer inputs':'Mixer tracks'};
    const c=channels()[page*4+id-4];
    if(id>=4&&id<=7)return {press:'Select channel',hold:available(c)&&muted(c)?'Unmute channel':'Mute channel'};
    if(id===2||id===8)return {press:id===2?'Volume down':'Volume up',hold:'Reset volume'};
    return {press:id===0?'Record / Play':id===1?'Stop':'Exit',hold:'None'};
  }
  function status(c) {if(muted(c))return 'Muted';if(kind==='inputs'&&!state.monitorOpen(c.id))return state.monitorMode(c.id)==='auto'?'Auto · Live off':'Hear live off';return '';}
  function role(id) {
    if(id===9){const first=page*4+1,last=Math.min((page+1)*4,channels().length);return {name:(kind==='tracks'?'Tracks ':'Inputs ')+first+'–'+last,hint:'Hold · '+(kind==='tracks'?'Inputs':'Tracks'),enabled:true,active:page>0};}
    if(id>=4&&id<=7){const i=page*4+id-4,c=channels()[i],enabled=available(c);return {name:c?.label||'—',hint:enabled?`${level(c)}%, ${status(c)||'hold to mute'}`:c?'Empty':'',level:enabled?level(c):null,muted:enabled&&muted(c),status:enabled?status(c):'',enabled,active:enabled&&i===selected};}
    if(id===2||id===8)return {name:id===2?'Volume −':'Volume +',hint:available(channel())?(canStep(id===2?-increment:increment)?'Hold · Reset':'Limit · Hold reset'):'Select channel',enabled:available(channel()),active:false};
    if(id===0)return {name:'Record / Play',hint:trackNames[currentTrack()],enabled:true,active:false};
    if(id===1)return {name:'Stop',hint:'All tracks',enabled:true,active:false};
    return {name:'Exit',hint:'',enabled:true,active:true};
  }
  function run(action,id) {
    const i=page*4+id-4,c=channels()[i];
    if(action==='Mixer inputs'||action==='Mixer tracks')setKind(action==='Mixer inputs'?'inputs':'tracks');
    else if(action==='Next channels')nextPage();
    else if(action==='Select channel'){if(available(c))selected=i;}
    else if(action==='Mute channel'||action==='Unmute channel'){if(available(c)){if(kind==='tracks')muteState.toggle(c.track);else state.toggleMute(c.id);}}
    else if(action==='Reset volume'){if(available(channel()))state.write(channel().id,1);}
    else if(action==='Volume down'||action==='Volume up'){const delta=action==='Volume down'?-increment:increment;if(canStep(delta))state.write(channel().id,(level(channel())+delta)/100);}
    else if(action==='Record / Play'||action==='Stop')transport(action,currentTrack());
  }
  function body() {
    const c=channel();
    return `<section class="mixer-overview" aria-label="Mixer channel"><div class="segmented mixer-kinds" role="group" aria-label="Mixer sources">${[['tracks','Tracks'],['inputs','Inputs']].map(([key,label])=>`<button data-action="mixer:${key}" class="${kind===key?'selected':''}" aria-pressed="${kind===key}">${label}</button>`).join('')}</div>${available(c)?`<div class="mixer-channel"><div class="mixer-channel-title"><h2>${esc(c.label)}</h2><span>${kind==='inputs'?'Live volume':'Playback volume'}</span></div><div class="mixer-reading"><strong>${level(c)}<small>%</small></strong>${status(c)?`<span class="mixer-status">${esc(status(c))}</span>`:''}${kind==='tracks'?`<span class="mixer-status" data-mixer-fade="${c.track}">${fadeState.read(c.track).active?fadeState.read(c.track).label:''}</span>`:''}</div><div class="mixer-scale"><span class="mixer-level-bar ${muted(c)?'muted':''}" aria-hidden="true"><span style="width:${level(c)/limit()*100}%"></span>${kind==='tracks'?'<i></i>':''}</span><div><span>0</span><span>${limit()}%</span></div></div></div>`:'<p>No recorded tracks in this bank.</p>'}</section>`;
  }
  function caption(r) {if(r.level==null)return `<small>${esc(r.hint)}</small>`;return `<strong class="mixer-level">${r.level}<small>%</small>${r.muted?'<span class="mixer-muted">Muted</span>':''}</strong><small>Hold · ${r.muted?'Unmute':'Mute'}</small>`;}
  return {enter,assignments,role,run,body,caption,snapshot:()=>({kind,page,selected:channel()?.id??null,channels:channels().map(c=>({...c,level:level(c),muted:muted(c),status:status(c)})),limit:limit(),increment,canDown:canStep(-increment),canUp:canStep(increment)})};
};
