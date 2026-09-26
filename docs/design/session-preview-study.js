// Library recognition preview. Waveforms use the same example PCM as Stage.
// Audition transport is simulated; it never changes the loaded session.
window.createSessionPreviewStudy = function (ctx) {
  const {button, icon, escape: esc} = ctx;
  let audition = null, scroll = 0, shown = null;
  const stop = () => {audition = null;};
  const blocked = () => ctx.capturing() ? 'Finish recording to listen' : ctx.playing() ? 'Stop playback to listen' : !ctx.ready() ? 'Connect audio to listen' : '';
  function rows(session) {
    const s = session.snapshot, live = session.current ? ctx.live().tracks : null;
    return Array.from({length:8}, (_,i) => {
      const id = 'Track '+(i+1), imported = s.audioLibrary?.trackImports?.[i];
      if (!s.recordedParts?.[id]?.length && !imported) return null;
      const meta = live?.[i] || s.previewTracks?.[i] || {}, length = s.trackLength?.[id];
      const [n,d] = (s.loopSettings?.signature || '4/4').split('/').map(Number), beatsPerBar = n*4/d;
      const bars = imported?.timing?.bars ?? meta.bars ?? (length?.durationBeats ?? length?.audio?.length)/beatsPerBar;
      const layers = meta.layers ?? s.trackLayers?.[id]?.layers?.length;
      const fx = (s.racks || []).filter(r => r.source === id || r.source?.startsWith(id+' / '));
      return {i, imported:!!imported, name:s.trackLabels?.[id]?.trim() || id, bars:Number.isFinite(bars)&&bars>0?bars:null,
        layers:Number.isFinite(layers)?layers:null, muted:!!s.mutedTracks?.[i], fx:fx.length,
        seconds:imported?.timing?.seconds ?? imported?.file?.seconds ?? (Number.isFinite(bars)&&bars>0?bars*beatsPerBar*60/(s.loopSettings?.tempo||84):null)};
    }).filter(Boolean);
  }
  function body(session) {
    if (shown !== session.id) {stop();scroll=0;shown=session.id;}
    const list = rows(session), maxBars = Math.max(1,...list.map(t=>t.bars||1));
    return `<div class="session-audio-preview"><div class="session-audio-scroll" role="region" aria-label="Recorded tracks">${list.length?list.map(t=>
      `<article class="session-audio-track ${t.muted?'muted':''}" data-session-track="${t.i}"><div class="session-audio-heading"><strong title="${esc(t.name)}">${esc(t.name)}</strong><span class="session-audio-facts">${t.bars?`<span>${+t.bars.toFixed(2)} <small>${t.bars===1?'bar':'bars'}</small></span>`:''}${t.layers!==null?`<span>${t.layers} <small>${t.layers===1?'layer':'layers'}</small></span>`:''}${t.muted?`<span class="session-muted" aria-label="Muted">${icon('mute')}</span>`:''}${t.fx?`<span class="session-audio-fx" aria-label="${t.fx} track effects">FX ${t.fx}</span>`:''}</span></div><div class="session-audio-lane"><div class="session-audio-clip" style="width:${t.bars?Math.max(2,t.bars/maxBars*100):100}%">${t.imported?'<span class="session-wave-pending">Imported audio · waveform unavailable</span>':`<svg viewBox="0 0 1024 100" preserveAspectRatio="none" aria-hidden="true"><path data-part="Recorded audio waveform" d="${ctx.waveform(t.i)}"/></svg>`}<span class="session-audio-head" data-session-head="${t.i}" hidden></span></div></div></article>`).join(''):'<p class="session-audio-empty">No recorded tracks</p>'}</div><span class="session-audio-more" aria-hidden="true" hidden>${icon('down')}</span></div>`;
  }
  function controls(session) {
    const reason=blocked(), has=rows(session).length>0;
    return `<div class="session-listen">${reason&&has?`<span>${esc(reason)}</span>`:''}${button('session:listen',icon(audition?'stop':'play')+(audition?'Stop preview':'Listen'),'quiet',`aria-pressed="${!!audition}" ${!has||reason?'disabled':''}`)}</div>`;
  }
  function toggle(session) {if(audition)stop();else if(!blocked()&&rows(session).length)audition={id:session.id,started:Date.now()};}
  function refresh(root, session, active) {
    if(!active) {stop();return;}
    if(audition&&(blocked()||session.id!==audition.id)){stop();ctx.render();return;}
    const list = rows(session), live=session.current?ctx.live().tracks:null;
    for(const head of root.querySelectorAll('[data-session-head]')) {
      const i=+head.dataset.sessionHead, t=list.find(t=>t.i===i), playing=live&&['Playing','Recording','Overdubbing'].includes(live[i]?.state);
      head.hidden=!t||!(audition&&t.seconds||playing);
      head.style.left=(audition&&t?.seconds?((Date.now()-audition.started)/1000/t.seconds)%1:live?.[i]?.position||0)*100+'%';
    }
    const area=root.querySelector('.session-audio-scroll'), more=root.querySelector('.session-audio-more');
    if(area&&more)more.hidden=area.scrollHeight-area.clientHeight-area.scrollTop<8;
    const b=root.querySelector('[data-action="session:listen"]');
    if(b)b.disabled=!!blocked()||!list.length;
  }
  return {body,controls,toggle,stop,rows,refresh,
    remember:root=>{const e=root.querySelector('.session-audio-scroll');if(e)scroll=e.scrollTop;},
    restore:root=>{const e=root.querySelector('.session-audio-scroll');if(e)e.scrollTop=scroll;},
    snapshot:()=>({audition:!!audition})};
};
