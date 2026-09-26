// Executable processing proposal. Packets and tail steps are symbols, not PCM/DSP.
(function (root) {
  'use strict';
  const clone = value => JSON.parse(JSON.stringify(value));
  function freeze(value) {
    if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
    return value;
  }
  const result = value => freeze(value);
  const packet = (id, path) => ({origins:[id], path, tail:false, level:1});

  function create(spec) {
    const state = clone({tracks:[], inputs:[], auxiliary:[], outputs:[], ...spec});
    const ids = new Set();
    for (const source of [...state.tracks, ...state.inputs, ...state.auxiliary, ...state.outputs]) {
      if (!source.id || ids.has(source.id)) throw new Error('Sources and outputs need unique IDs');
      ids.add(source.id);
    }
    const effects = new Set();
    for (const source of [...state.tracks, ...state.inputs, ...state.outputs]) {
      for (const fx of [...(source.pre || []), ...(source.post || []), ...(source.fx || [])]) {
        if (!fx.id || effects.has(fx.id) || !Number.isInteger(fx.tailSteps) || fx.tailSteps < 0) throw new Error('Effects need unique IDs and explicit symbolic tail steps');
        effects.add(fx.id);
      }
    }
    return result({...state, buffers:{}, frame:{tracks:{}, inputs:{}, outputs:{}}, step:0});
  }

  function process(chain, input, buffers) {
    let packets = input;
    for (const fx of chain || []) {
      const old = buffers[fx.id];
      const next = packets.map(p => ({...clone(p), path:[...p.path, (fx.bypassed ? 'dry:' : 'fx:') + fx.id]}));
      if (old?.remaining > 0) {
        next.push({...clone(old.packet), tail:true});
        if (--old.remaining === 0) delete buffers[fx.id];
      }
      if (!fx.bypassed && packets.length && fx.tailSteps > 0) {
        buffers[fx.id] = {remaining:fx.tailSteps, packet:{
          origins:[...new Set(packets.flatMap(p => p.origins))],
          path:[...new Set(packets.flatMap(p => p.path)), 'fx:' + fx.id], tail:true, level:1,
        }};
      }
      packets = next;
    }
    return packets;
  }

  function advance(previous) {
    const state = clone(previous), frame = {tracks:{}, inputs:{}, outputs:{}};
    const routed = Object.fromEntries(state.outputs.map(output => [output.id, []]));
    const route = (source, packets) => { for (const id of source.routes || []) if (routed[id]) routed[id].push(...packets); };
    for (const track of state.tracks) {
      const path = ['recorded:' + track.id, ...(track.printedPre || []).map(id => 'printed:' + id),
        ...(track.mono ? ['track-mono-average'] : []), ...(track.pre || []).filter(fx => !fx.bypassed).map(fx => 'printed:' + fx.id), 'player'];
      const feed = track.playing && track.hasAudio !== false ? [packet(track.id, path)] : [];
      const post = process(track.post, feed, state.buffers);
      const audible = track.muted ? [] : post.map(p => ({...p, level:p.level * (track.level ?? 1), path:[...p.path, 'track-level-pan']})).filter(p => p.level !== 0);
      frame.tracks[track.id] = {feed:feed.length > 0, post, audible};
      route(track, audible);
    }
    for (const input of state.inputs) {
      const feed = input.monitoring && input.signal ? [packet(input.id, ['live:' + input.id])] : [];
      const processed = process(input.post, process(input.pre, feed, state.buffers), state.buffers);
      const audible = processed.map(p => ({...p, level:p.level * (input.level ?? 1), path:[...p.path, 'live-mixer']})).filter(p => p.level !== 0);
      frame.inputs[input.id] = {feed:feed.length > 0, audible};
      route(input, audible);
    }
    for (const source of state.auxiliary) if (source.playing && source.level !== 0) route(source, [{...packet(source.id, ['auxiliary:' + source.id]), level:source.level ?? 1}]);
    for (const output of state.outputs) {
      const afterFx = process(output.fx, routed[output.id], state.buffers);
      const audible = output.muted || output.level === 0 ? [] : afterFx.map(p => ({...p,
        level:p.level * (output.level ?? 1), path:[...p.path, 'output-level-balance-format']}));
      frame.outputs[output.id] = {incoming:clone(routed[output.id]), afterFx, audible};
    }
    state.frame = frame; state.step++;
    return result(state);
  }

  function action(previous, type, id, value) {
    const state = clone(previous), track = state.tracks.find(item => item.id === id);
    if (type === 'all-sound-cut') {
      for (const item of [...state.tracks, ...state.auxiliary]) item.playing = false;
      state.buffers = {};
      state.frame = {tracks:{}, inputs:{}, outputs:Object.fromEntries(state.outputs.map(output => [output.id, {incoming:[], afterFx:[], audible:[]}]))};
    } else if (['stop', 'play', 'clear', 'mute'].includes(type)) {
      if (!track) throw new Error('Unknown track');
      if (type === 'mute') track.muted = !!value;
      else if (type === 'play') track.playing = track.hasAudio !== false;
      else { track.playing = false; if (type === 'clear') track.hasAudio = false; }
    } else if (type === 'bypass') {
      const effects = [...state.tracks, ...state.inputs, ...state.outputs].flatMap(item => [...(item.pre || []), ...(item.post || []), ...(item.fx || [])]);
      const effect = effects.find(item => item.id === id);
      if (!effect) throw new Error('Unknown effect');
      // Printed recorded Pre requires a new render; bypassing it cannot undo PCM.
      if (state.tracks.some(item => (item.pre || []).includes(effect))) throw new Error('Recorded Pre changes require prepared replacement audio');
      effect.bypassed = !!value;
    } else if (type === 'input-signal' || type === 'monitor') {
      const input = state.inputs.find(item => item.id === id);
      if (!input) throw new Error('Unknown input');
      input[type === 'input-signal' ? 'signal' : 'monitoring'] = !!value;
    } else throw new Error('Unknown processing action');
    return result(state);
  }

  function captureRecipe(input, takeId) {
    return result({kind:'symbolic-input-capture', takeId, sourceId:input.id, recordingTrimDb:input.recordingTrimDb ?? 0,
      originalDryRetained:true, pre:clone(input.pre || []), post:clone(input.post || []),
      prePrinted:true, postRunsAfterPlayer:true, liveMixerLevelPrinted:false});
  }
  const monoAverage = (left, right) => {
    if (!Number.isFinite(left) || !Number.isFinite(right)) throw new Error('Finite symbolic channel values required');
    const mean = left / 2 + right / 2; return result([mean, mean]);
  };
  function performanceFrame(state, outputId, captureTap) {
    if (!['before-final-controls', 'after-final-controls'].includes(captureTap)) throw new Error('Choose the proposed performance capture tap explicitly');
    const output = state.frame.outputs[outputId];
    if (!output) throw new Error('Unknown output frame');
    return result({kind:'main-performance', symbolic:true, outputId, captureTap, duration:'elapsed-recording-time',
      packets:clone(captureTap === 'before-final-controls' ? output.afterFx : output.audible)});
  }
  function exportFile(file) { return result({kind:'copy-existing-file', render:false, file:clone(file)}); }

  const api = {create, advance, action, captureRecipe, monoAverage, performanceFrame, exportFile};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.SegnoProcessingBehavior = api;
})(typeof window === 'undefined' ? null : window);
