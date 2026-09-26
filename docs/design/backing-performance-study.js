// Silent backing-player performance proposal using the same prepared audio as Library.
window.createBackingPerformanceStudy = ({state,changed}) => {
  let page = 0, selected = null, lastLoaded = null, editing = null, clearing = false;
  const esc = value => String(value ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  const name = file => file?.name.replace(/\.[^.]+$/, '') || '';
  const time = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2,'0')}`;
  const data = () => state.get();
  const mixValue=(s,key)=>s.mix?.[key]??(key==='level'?1:.5);
  const mixText=(key,value)=>key==='level'?(value>0?(20*Math.log10(value)).toFixed(1)+' dB':'−∞ dB'):Math.abs(value-.5)<.005?'Center':Math.round(Math.abs(value-.5)*200)+(value<.5?' L':' R');
  const draftPosition=s=>editing?.kind==='seek'?editing.value:s.position;
  function sync() {
    const s = data();
    if(s.loaded?.id!==lastLoaded){if(selected===lastLoaded){selected=s.loaded?.id||null;const i=s.files.findIndex(f=>f.id===selected);if(i>=0)page=Math.floor(i/4);}lastLoaded=s.loaded?.id||null;editing=null;}

    if (!s.files.some(f => f.id === selected)) selected = s.files.find(f => f.id === s.loaded?.id)?.id || s.files[0]?.id || null;
    page = Math.min(page, Math.max(0, Math.ceil(s.files.length / 4) - 1));
    return s;
  }
  function select(id) { const s = sync(), index = s.files.findIndex(f => f.id === id); if(index < 0)return; selected = id; page = Math.floor(index / 4); }
  function assignments(id) { return {press: id >= 4 && id <= 7 ? 'Select backing' : ({0:'Play backing',1:'Stop backing',2:'Previous backing',3:'Exit',8:'Next backing',9:'Backing page'})[id], hold:({2:'Rewind backing',8:'Forward backing',9:'Backing end behavior'})[id]||'None'}; }
  function role(id) {
    const s = sync(), index = s.files.findIndex(f => f.id === selected), pending = selected && s.loaded?.id !== selected;
    if(id >= 4 && id <= 7) {const f=s.files[page*4+id-4];return {name:f ? name(f) : '—',hint:f?.id===s.loaded?.id&&s.playing?'Playing':f?.id===selected?'Selected':'',enabled:!!f,active:!!f&&f.id===selected,playing:!!f&&f.id===s.loaded?.id&&s.playing};}
    if(id===0)return {name:pending?'Play selected':s.playing?'Pause':'Play',hint:'Backing audio',enabled:!!selected||!!s.loaded,active:s.playing};
    if(id===1)return {name:'Stop',hint:'Backing audio',enabled:!!s.loaded,active:false};
    if(id===2)return {name:'Previous',hint:'Hold: −10 seconds',enabled:index>0||!!s.loaded,active:false};
    if(id===8)return {name:'Next',hint:'Hold: +10 seconds',enabled:index>=0&&index<s.files.length-1||!!s.loaded,active:false};
    if(id===9)return {name:'Page '+(page+1)+' / '+Math.max(1,Math.ceil(s.files.length/4)),hint:'Hold: At end',enabled:s.files.length>0,active:page>0};
    return {name:'Exit',hint:'',enabled:true,active:true};
  }
  function run(action,id) {
    const s=sync(), index=s.files.findIndex(f=>f.id===selected);
    editing=null;
    if(action==='Rewind backing')state.command('seek',s.position-10);
    else if(action==='Forward backing')state.command('seek',s.position+10);
    else if(action==='Backing end behavior')state.command('end',({stop:'repeat',repeat:'next',next:'stop'})[s.end]);
    else if(action==='Select backing')select(s.files[page*4+id-4]?.id);
    else if(action==='Previous backing'&&index>0)select(s.files[index-1].id);
    else if(action==='Next backing'&&index<s.files.length-1)select(s.files[index+1]?.id);
    else if(action==='Backing page')page=(page+1)%Math.max(1,Math.ceil(s.files.length/4));
    else if(action==='Play backing')state.command('play',selected);
    else if(action==='Stop backing')state.command('stop');
  }
  function body() {
    const s=sync(), f=s.files.find(f=>f.id===selected), pending=f&&f.id!==s.loaded?.id;
    return `<section class="backing-overview" aria-label="Backing audio"><div class="backing-current"><span class="backing-status">${clearing?'Clear backing?':s.playing?'Playing':s.position>0?'Paused':'Ready'}</span><h2>${esc(name(s.loaded)||'No audio loaded')}</h2>${s.loaded?`<label class="inline-control backing-seek ${editing?'editing':''}"><input type="range" data-action="backing:seek" aria-label="Backing position" aria-valuetext="${time(draftPosition(s))} of ${time(s.loaded.seconds)}" min="0" max="${s.loaded.seconds}" step="1" value="${draftPosition(s)}" style="--amount:${(draftPosition(s))/s.loaded.seconds*100}%"></label><div class="backing-time"><span>${time(draftPosition(s))}</span><span>${time(s.loaded.seconds)}</span></div>`:''}</div><div class="backing-end"><span>At end</span><div role="group" aria-label="At end">${['stop','repeat','next'].map(v=>`<button data-action="backing:end:${v}" aria-pressed="${s.end===v}" class="${s.end===v?'selected':''}">${v[0].toUpperCase()+v.slice(1)}</button>`).join('')}</div></div><div class="backing-selection"><span>${clearing?'Stops and unloads; prepared audio stays.':pending?'Selected · press Play':s.files.length?'Prepared audio':'Nothing prepared yet'}</span><strong>${esc(clearing?'':pending?name(f):s.files.length+' recording'+(s.files.length===1?'':'s'))}</strong>${!s.files.length?'<p>Add audio in Library before performing.</p>':''}</div>${mixBody(s)}${s.error?`<p class="backing-error" role="alert">${esc(s.error)}</p>`:''}</section>`;
  }
  function mixBody(s) {
    return `<div class="backing-mix" role="group" aria-label="Backing mix">${['level','pan'].map(key=>`<div><button data-action="backing:mix:${key}" class="${editing?.kind===key?'editing':''}" aria-pressed="${editing?.kind===key}">${key==='level'?'Level':'Pan'} <strong>${mixText(key,editing?.kind===key?editing.value:mixValue(s,key))}</strong></button><button data-action="backing:less:${key}" aria-label="Decrease backing ${key}">−</button><button data-action="backing:more:${key}" aria-label="Increase backing ${key}">+</button></div>`).join('')}${s.loaded?(clearing?'<button data-action="backing:cancel-clear">Cancel</button><button data-action="backing:confirm-clear">Clear backing</button>':'<button data-action="backing:clear">Clear</button>'):''}</div>`;
  }
  function refresh(root) {
    const s=sync(), progress=root.querySelector('[data-action="backing:seek"]'), reading=root.querySelector('.backing-time>span'), status=root.querySelector('.backing-status');
    if(progress&&s.loaded){const value=draftPosition(s);progress.value=value;progress.style.setProperty('--amount',value/s.loaded.seconds*100+'%');progress.setAttribute('aria-valuetext',time(value)+' of '+time(s.loaded.seconds));}
    if(reading)reading.textContent=time(draftPosition(s));
    if(status)status.textContent=clearing?'Clear backing?':s.playing?'Playing':s.position>0?'Paused':'Ready';
  }
  function finish(cancel=false){if(!editing)return false;const s=sync(),draft=editing;editing=null;if(draft&&!cancel&&(draft.kind!=='seek'||s.loaded?.id===draft.id))state.command(draft.kind,draft.value);changed();return true;}
  const controls={
    action:id=>{
      if(!id.startsWith('backing:'))return false;
      const [,action,key]=id.split(':');
      if(id==='backing:seek'){if(editing)return finish();const s=sync();if(s.loaded)editing={kind:'seek',id:s.loaded.id,value:s.position};}
      else if(action==='mix'){if(editing?.kind===key)return finish();editing={kind:key,value:mixValue(sync(),key)};}
      else if(action==='less'||action==='more'){editing=null;state.command(key,Math.max(0,Math.min(1,mixValue(sync(),key)+(action==='more'?.01:-.01))));}
      else if(action==='clear')clearing=sync().loaded?.id||false;
      else if(action==='cancel-clear')clearing=false;
      else if(action==='confirm-clear'){if(sync().loaded?.id===clearing)state.command('clear');clearing=false;}
      else if(action==='end'){editing=null;state.command('end',key);}
      changed();return true;
    },
    turn:delta=>{const s=sync();if(!editing)return false;editing.value=Math.max(0,Math.min(editing.kind==='seek'?s.loaded.seconds:1,editing.value+delta*(editing.kind==='seek'?1:.01)));changed();return true;},finish,
    input:value=>{editing=null;state.command('seek',Number(value));},
    reset:()=>{editing=null;state.command('seek',0);changed();},
    cancel:()=>{editing=null;clearing=false;}
  };
  return {controls,assignments,role,run,body,refresh,enter:()=>{sync();select(selected);},caption:r=>`<small>${esc(r.hint)}</small>`,snapshot:()=>({...sync(),page,selected,editing,clearing})};
};
