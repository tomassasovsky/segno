// Reversible same-rack preset audition for the silent prototype. Host owns sound
// publication; temporary values must be projected out of every persistence path.
(function (root) {
  'use strict';
  const copy = value => structuredClone(value);
  const finite = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1;
  function compatibility(original, preset) {
    const rack = original?.rack;
    if (!rack || !preset || rack.family !== preset.family) return 'Choose a preset from this rack family.';
    if (!Array.isArray(preset.modules) || !preset.modules.length || !Array.isArray(rack.modules) ||
      [...preset.modules, ...rack.modules].some(m => !m || typeof m.name !== 'string' || !m.name)) return 'This preset has no readable effects.';
    const names = modules => modules.map(m => m.name);
    if (new Set(names(rack.modules)).size !== rack.modules.length || new Set(names(preset.modules)).size !== preset.modules.length ||
      rack.modules.length !== preset.modules.length || rack.modules.some(m => !preset.modules.some(p => p.name === m.name))) return 'This preset has a different effect layout. Existing assignments stay unchanged.';
    for (const module of rack.modules) {
      const source = preset.modules.find(m => m.name === module.name), params = source.params;
      if (!Array.isArray(params) || !Array.isArray(module.params) || params.length !== module.params.length ||
        new Set(params.map(p => p?.[0])).size !== params.length || params.some(p => !Array.isArray(p) || typeof p[0] !== 'string' || !finite(p[1]) || typeof p[2] !== 'string') ||
        module.params.some(p => !params.some(q => q[0] === p[0]))) return 'This preset has different or unreadable controls. Existing assignments stay unchanged.';
    }
    return '';
  }
  function candidate(original, preset) {
    const reason = compatibility(original, preset);
    if (reason) return {error:reason};
    const next = copy(original), rack = next.rack;
    rack.name = preset.name;
    for (const field of ['presetId', 'parameterSourcePresetId', 'artwork']) {
      const value = field === 'presetId' ? preset.id : preset[field];
      if (value === undefined) delete rack[field];else rack[field] = copy(value);
    }
    rack.original = copy(preset.raw || preset.original || {});
    rack.modules = rack.modules.map(module => {
      const source = preset.modules.find(m => m.name === module.name), next = {...module};
      for (const field of ['sourceValues', 'bypass', 'sourceFamily', 'sourcePresetId', 'parameterSourcePresetId', 'icon']) {
        if (source[field] === undefined) delete next[field];else next[field] = copy(source[field]);
      }
      next.params = module.params.map(p => {const q = source.params.find(q => q[0] === p[0]);return [q[0], q[1], q[2], q[1]];});
      return next;
    });
    if (preset.channels !== undefined) next.channels = copy(preset.channels);
    return {scope:next};
  }
  function createSession(ctx) {
    let original = null, selected = null, error = '';
    function begin(rackId) {
      if (original) cancel();
      const scope = ctx.read(rackId);
      if (!scope?.rack || scope.rack.id !== rackId) return false;
      original = copy(scope);selected = null;error = '';return true;
    }
    function select(preset) {
      if (!original) return false;
      const result = candidate(original, preset);
      if (result.error) {error = result.error;return false;}
      ctx.preview(copy(result.scope));selected = copy(preset);error = '';return true;
    }
    function cancel() {
      if (!original) return false;
      ctx.restore(copy(original));original = null;selected = null;error = '';return true;
    }
    function keep() {
      if (!original || !selected) return false;
      const current = ctx.read(original.rack.id);
      if (!current?.rack || current.rack.id !== original.rack.id) {error = 'This rack changed. Cancel and open Try preset again.';return false;}
      try {
        if (ctx.publish(copy(current), copy(original)) === false) throw Error('Could not save this sound. Keep or Cancel to try again.');
      } catch (failure) {error = failure.message;return false;}
      original = null;selected = null;error = '';return true;
    }
    function persisted(rig) {
      if (!original) return rig;
      const next = copy(rig), index = next.racks.findIndex(r => r.id === original.rack.id);
      if (index >= 0) next.racks[index] = copy(original.rack);
      if (original.channels === undefined) {if (next.channels) delete next.channels[original.rack.id];}
      else (next.channels ||= {})[original.rack.id] = copy(original.channels);
      return next;
    }
    return {begin, select, cancel, keep, persisted, active:() => !!original,
      original:() => copy(original), snapshot:() => ({active:!!original, original:copy(original), selected:copy(selected), error})};
  }
  function createUI(ctx) {
    const session = createSession(ctx), {button, escape:esc} = ctx;
    let entries = [], selected = -1, opener = '';
    const show = action => {ctx.render();if (action) ctx.focus(action);};
    function open({rackId, presets, opener:from = 'try-preset'}) {
      if (!session.begin(rackId)) return false;
      entries = copy(presets);selected = -1;opener = from;show('audition:cancel');return true;
    }
    function choose(index) {
      if (!session.active() || !entries[index] || index === selected) return;
      if (session.select(entries[index])) selected = index;
      show();
    }
    function close(keep = false) {
      const done = keep ? session.keep() : session.cancel();
      if (done) {entries = [];selected = -1;show(opener);}else show();
      return done;
    }
    function overlay() {
      if (!session.active()) return '';
      const state = session.snapshot(), original = state.original, bypass = original.rack.bypass;
      return `<div class="overlay"><section class="dialog preset-audition-dialog" role="dialog" aria-modal="true"><h2>Try preset</h2><p>${esc(original.rack.family)} · ${bypass ? 'Rack bypassed' : 'Rack enabled'}</p><div class="preset-audition-list">${entries.map((p, i) => {
        const reason = compatibility(original, p);
        return button('audition:choose:' + i, `<span><strong>${esc(p.name)}</strong><small>${esc(reason || p.origin || 'Factory')}</small></span>${selected === i ? '<span class="preset-audition-current">Trying</span>' : ''}`, 'quiet preset-audition-option' + (selected === i ? ' selected' : ''), `aria-pressed="${selected === i}" ${reason ? 'disabled' : ''}`);
      }).join('') || '<p>No presets are available for this rack.</p>'}</div><p>${selected < 0 ? 'Choose a sound to try.' : 'Keep saves this sound. Cancel restores your previous sound.'}${bypass ? ' The rack stays bypassed.' : ''}</p>${state.error ? `<p class="preset-audition-error" role="alert">${esc(state.error)}</p>` : ''}<div class="actions">${button('audition:cancel', 'Cancel')}${button('audition:keep', 'Keep', 'primary', selected < 0 ? 'disabled' : '')}</div></section></div>`;
    }
    function action(id) {
      if (!id?.startsWith('audition:')) return false;
      if (id.startsWith('audition:choose:')) choose(Number(id.slice(16)));
      else if (id === 'audition:cancel') close();
      else if (id === 'audition:keep') close(true);
      return true;
    }
    return {open, overlay, action, active:session.active, persisted:session.persisted,
      focused:id => {if (id?.startsWith('audition:choose:')) choose(Number(id.slice(16)));},
      cancel:() => {entries = [];selected = -1;return session.cancel();},
      leave:() => {entries = [];selected = -1;return session.cancel();},
      back:() => {if (!session.active()) return false;close();return true;},
      snapshot:() => ({...session.snapshot(), selectedIndex:selected})};
  }
  const api = {compatibility, candidate, createSession, createUI};
  root.SegnoPresetAudition = api;root.createPresetAuditionStudy = createUI;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
