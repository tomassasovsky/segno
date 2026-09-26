// Explicit timing-source selection for the silent prototype. No audio conversion.
(function (root) {
  'use strict';
  const copy = value => structuredClone(value);
  const span = track => track.loopBeats ?? track.beats;
  const recorded = context => context.tracks.filter(t => t.hasAudio);
  const near = (a, b) => Math.abs(a - b) <= 1e-6 * Math.max(1, a, b);
  function current(context) {
    const audio = recorded(context);
    return audio.find(t => t.id === context.primaryTrack)?.id ?? audio[0]?.id ?? null;
  }
  function availability(context, id) {
    const audio = recorded(context), selected = audio.find(t => t.id === id);
    if (!['sync', 'band'].includes(context.mode)) return {enabled:false, reason:'Timing source is used in Sync and Band.'};
    if (context.capturing || context.tracks.some(t => t.capturing)) return {enabled:false, reason:'Finish recording before changing the timing source.'};
    if (context.pending) return {enabled:false, reason:'Finish or cancel the queued action first.'};
    if (!selected) return {enabled:false, reason:'Record this track before using it for timing.'};
    if (audio.some(t => !Number.isFinite(span(t)) || span(t) <= 0)) return {enabled:false, reason:'Recorded loop lengths are unavailable.'};
    if (audio.some(t => {const ratio = Math.max(span(t), span(selected)) / Math.min(span(t), span(selected));return !near(ratio, Math.round(ratio));})) {
      return {enabled:false, reason:'Other loop lengths must be whole multiples or divisions of this track.'};
    }
    return {enabled:true, reason:'', stop:context.tracks.some(t => t.playing), current:current(context) === id};
  }
  function createUI(ctx) {
    const {button, header, escape:esc} = ctx;
    let pending = null, error = '', clearing = null, footBank=0, revision=0;
    const choices = () => {const c=ctx.context();return clearing?{...c,tracks:c.tracks.filter(t=>t.id!==clearing)}:c;};
    const show = id => {revision++;ctx.render();if (id) ctx.focus(id);};
    const label = () => {const c = ctx.context(), id = current(c);return c.tracks.find(t => t.id === id)?.label || id || 'First recording';};
    function choose(id, confirmed = false) {
      const c = choices(), choice = availability(c, id);if(clearing)choice.stop=ctx.context().tracks.some(t=>t.playing);
      if (!choice.enabled) {error = choice.reason;show();return;}
      if (choice.current && !clearing) {pending = null;error = '';show('primary:choose:' + encodeURIComponent(id));return;}
      if (choice.stop && !confirmed) {pending = {id};error = '';show('primary:cancel');return;}
      try {
        if ((clearing ? ctx.clear(id) : ctx.commit(id, {stop:choice.stop})) === false) throw Error('Could not save the timing source. Try again.');
        clearing = null;pending = null;error = '';show('primary:choose:' + encodeURIComponent(id));
      } catch (failure) {error = failure.message;show();}
    }
    function body() {
      const c = choices(), selected = current(ctx.context());
      return header(clearing?'Clear timing source':'Timing source', '') + `<div class="primary-track-study"><p>${clearing?'Choose the recorded track that will provide timing after '+esc(clearing)+' is cleared.':'Sync and Band follow this recorded track’s musical cycle. Speed, direction and Once change its playback only.'} Recordings keep their length.</p><div class="primary-track-options">${c.tracks.map(t => {
        const option = availability(c, t.id), isCurrent = t.id === selected, beats = span(t);
        return button('primary:choose:' + encodeURIComponent(t.id), `<span><strong>${esc(t.label || t.id)}</strong><small>${esc(option.reason || (Number.isFinite(beats) ? beats + ' beats' : 'Empty track'))}</small></span>${isCurrent ? '<span class="primary-track-current">Timing source</span>' : ''}`, 'quiet primary-track-option' + (isCurrent ? ' selected' : ''), `aria-pressed="${isCurrent}" ${option.enabled ? '' : 'disabled'}`);
      }).join('')}</div><div class="actions">${button('primary:bank','Bank '+(footBank?'B · Tracks 5–8':'A · Tracks 1–4')+' <small>BANK</small>','quiet')}${button('primary:exit',clearing?'Cancel clear <small>MODE</small>':'Stage <small>MODE</small>','quiet')}</div>${!selected ? '<p>The first recording becomes the timing source.</p>' : ''}${error ? `<p class="primary-track-error" role="alert">${esc(error)}</p>` : ''}</div>`;
    }
    function overlay() {
      if (!pending) return '';
      const c = choices(), choice = availability(c, pending.id), target = c.tracks.find(t => t.id === pending.id);
      return `<div class="overlay"><section class="dialog primary-track-dialog" role="dialog" aria-modal="true"><h2>Use ${esc(target?.label || pending.id)} for timing?</h2><p>${clearing?'Stop playing tracks, clear '+esc(clearing)+' and switch the timing source.':'Stop playing tracks and switch the timing source.'} Other recordings keep their length. Playback stays stopped.</p>${error || !choice.enabled ? `<p class="primary-track-error" role="alert">${esc(error || choice.reason)}</p>` : ''}<div class="actions">${button('primary:cancel', 'Cancel <small>MODE</small>')}${button('primary:confirm', (clearing?'Stop, clear and switch':'Stop and switch')+' <small>STOP</small>', 'primary', choice.enabled ? '' : 'disabled')}</div></section></div>`;
    }
    function action(id) {
      if (!id?.startsWith('primary:')) return false;
      if (id === 'primary:open') {leave();ctx.go('loop-primary');}
      else if (id.startsWith('primary:choose:')) choose(decodeURIComponent(id.slice(15)));
      else if (id === 'primary:confirm' && pending) choose(pending.id, true);
      else if (id === 'primary:cancel') {pending = null;error = '';show();}
      else if (id === 'primary:bank') {footBank=1-footBank;show();}
      else if (id === 'primary:exit') {leave();ctx.go('stage');}
      return true;
    }
    function leave(){revision++;if(clearing)ctx.cancelClear();clearing=null;pending=null;error='';}
    function openClear(id){ctx.go('loop-primary');footBank=0;clearing=id;pending=null;error='';show();}
    function footBindings(){
      if(pending)return [{id:1,action:'primary:confirm'},{id:3,action:'primary:exit'}];
      const c=choices();return [{id:3,action:'primary:exit'},{id:9,action:'primary:bank'},...ctx.context().tracks.slice(footBank*4,footBank*4+4).flatMap((t,i)=>t.id!==clearing&&availability(c,t.id).enabled?[{id:i+4,action:'primary:choose:'+encodeURIComponent(t.id)}]:[])];
    }
    return {body, overlay, action, label, openClear, leave, footBindings, back:() => {if (!pending) {if(clearing)leave();return false;}pending = null;error = '';show();return true;}, snapshot:() => ({current:current(ctx.context()), clearing, pending:copy(pending), error,footBank,revision})};
  }
  const api = {current, availability, createUI};
  root.SegnoPrimaryTrack = api;root.createPrimaryTrackStudy = createUI;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
