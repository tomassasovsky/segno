// Silent chromatic-tuner proposal. Samples are explicit fixtures, never microphone data.
window.createTunerPerformanceStudy = ({state}) => {
  const names = ['C','C♯','D','D♯','E','F','F♯','G','G♯','A','A♯','B'];
  const esc = text => String(text).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  let page = 0, muted = true, error = '', samples = {};
  const inputs = () => state.inputs();
  const source = () => inputs().find(i => i.id === state.read()?.source) || inputs()[0];
  const reference = () => Math.max(420, Math.min(460, Math.round(state.read()?.reference || 440)));
  const pages = () => Math.max(1, Math.ceil(inputs().length / 4));
  function commit(patch) {
    const next = {source:source()?.id, reference:reference(), ...patch};
    if (!state.write(next)) {error = 'Tuner settings could not be saved. Try again.'; return false;}
    error = ''; return true;
  }
  function enter() {muted = true; error = ''; page = Math.max(0, Math.floor(inputs().findIndex(i => i.id === source()?.id) / 4));}
  function select(index) {const input = inputs()[index]; if (input) commit({source:input.id});}
  function reading() {
    const sample = samples[source()?.id];
    if (!sample || !Number.isFinite(sample.frequency) || sample.frequency < 20 || sample.frequency > 5000 || (sample.confidence ?? 1) < .8) return {note:null, cents:null, direction:'Play one note'};
    const midi = 69 + 12 * Math.log2(sample.frequency / reference()), nearest = Math.round(midi), cents = (midi - nearest) * 100;
    return {note:names[((nearest % 12) + 12) % 12], octave:Math.floor(nearest / 12) - 1, cents, direction:Math.abs(cents) < 3 ? 'In tune' : cents < 0 ? 'Flat' : 'Sharp'};
  }
  function assignments(id) {
    return {press:id>=4&&id<=7?'Tuner input':id===1?'Toggle tuner mute':id===2?'Reference down':id===8?'Reference up':id===9?'Next tuner inputs':id===3?'Exit':'None', hold:id===2||id===8?'Reset reference':'None'};
  }
  const monitorLabel = () => muted ? 'Input muted' : state.monitorLabel(source()?.id);
  function role(id) {
    if (id>=4&&id<=7) {const input = inputs()[page*4+id-4]; return {name:input?.name || '—', hint:input?'Input '+(page*4+id-3):'', enabled:!!input, active:!!input&&input.id===source()?.id};}
    if (id===1) return {name:muted?'Unmute input':'Mute input', hint:monitorLabel(), enabled:!!source(), active:muted&&!!source()};
    if (id===2||id===8) return {name:id===2?'Reference −':'Reference +', hint:'Hold · 440 Hz', enabled:true, active:false};
    if (id===9) return {name:'Inputs '+(page*4+1)+'–'+Math.min(inputs().length,(page+1)*4), hint:pages()>1?'Next inputs':'', enabled:pages()>1, active:page>0};
    if (id===3) return {name:'Exit',hint:'',enabled:true,active:true};
    return {name:'Record / Play',hint:'',enabled:false,active:false};
  }
  function run(action,id) {
    if (action==='Tuner input') select(page*4+id-4);
    else if (action==='Toggle tuner mute') muted = !muted;
    else if (action==='Reference down'||action==='Reference up') commit({reference:Math.max(420,Math.min(460,reference()+(action==='Reference down'?-1:1)))});
    else if (action==='Reset reference') commit({reference:440});
    else if (action==='Next tuner inputs') {const next=(page+1)%pages();if(commit({source:inputs()[next*4]?.id})) page=next;}
  }
  const mutedInputs = () => muted&&source() ? state.linkedInputs(source().id) : [];
  function body() {
    const r=reading(), input=source(), position=r.cents==null?50:Math.max(0,Math.min(100,50+r.cents));
    return `<section class="tuner-reference" aria-label="Tuning reference"><span>A4 reference</span><strong>${reference()}<small>Hz</small></strong>${error?`<p role="status">${esc(error)}</p>`:''}</section><section class="tuner-overview" aria-label="Tuner reading"><div class="tuner-source"><h2>${esc(input?.name||'No inputs')}</h2><span>${esc(monitorLabel())}</span></div><div class="tuner-reading"><strong>${r.note||'—'}</strong><div><b>${r.direction}</b><span>${r.cents==null?'':(r.cents>0?'+':'')+r.cents.toFixed(1)+' cents'}</span></div></div><div class="tuner-meter ${r.direction==='In tune'?'in-tune':''}" role="meter" aria-label="Pitch deviation in cents" aria-valuemin="-50" aria-valuemax="50" ${r.cents==null?'':`aria-valuenow="${r.cents.toFixed(1)}"`} aria-valuetext="${esc(r.direction)}"><div class="tuner-center"></div>${Array.from({length:21},(_,i)=>`<i style="left:${i*5}%;height:${i%5===0?28:15}px"></i>`).join('')}${r.note?`<div class="tuner-needle" style="left:${position}%"></div>`:''}</div><div class="tuner-scale"><span>−50</span><span>0</span><span>+50</span></div></section>`;
  }
  function simulate(values) {samples={...samples,...values};}
  return {enter,assignments,role,run,body,simulate,mutedInputs,snapshot:()=>({source:source()?.id,reference:reference(),page,pages:pages(),muted,mutedInputs:mutedInputs(),reading:reading(),error,range:[420,460]})};
};
