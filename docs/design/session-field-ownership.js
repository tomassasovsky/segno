// Proposed session/physical ownership split for the silent design prototype.
// The caller owns dependency UI, atomic publication and release of live contacts.
// capture() takes materialized rig state after the host settles running fades and
// momentary parameter values. It excludes calibration, aliases and catalogues.
// project() starts from current appliance state, replacing only musical fields.
// Its candidate must not be published as a recalled session unless ready is true.
// Pass connection/target inventories for the candidate and mediaIssues from the
// existing SegnoSessionRecovery.inspect(snapshot, currentFiles) at final Apply.
// MIDI global enable and sync source/send/Thru configuration stay appliance-wide
// in this proposal; musical MIDI device/source/target associations still recall.
// Live held/gesture maps and connection facts live outside rig in the current
// host. Keep its post-publication release/reset calls; this module dispatches none.
(function (root) {
  'use strict';
  const copy = value => structuredClone(value);
  const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
  const musical = [
    'instruments', 'racks', 'channels', 'nextId', 'nextExpressionModuleId', 'latched', 'pedalSettings', 'midiMappings',
    'recordedParts', 'trackLabels', 'liveMonitoring', 'recordingInputs',
    'previewTracks', 'loopSettings', 'trackPlayback', 'trackLength', 'trackLayers',
    'editHistory', 'bounceRecipes', 'expressionMix', 'inputSetup', 'audioRouting',
    'mutedInputs', 'monoOutputs', 'mutedOutputs', 'mutedTracks', 'soloTracks',
    'trackPitch', 'transposeEnabled', 'trackReverse', 'trackFade', 'fadeSeconds',
    'trackFadeSeconds', 'trackFxBypass', 'loopSpeed'
  ];
  const audioFields = ['prepared', 'backing', 'backingEnd', 'trackImports'];
  const switchFields = ['press', 'hold', 'change', 'mappings'];
  const pick = (value, keys) => Object.fromEntries(keys.filter(key => own(value, key)).map(key => [key, copy(value[key])]));
  const assigned = value => !!value && value !== 'none';

  function requirements(rig) {
    const ports = rig.expressionSettings?.ports || [], needed = new Map();
    function need(port, index) {
      if (!needed.has(port)) needed.set(port, new Set());
      if (index !== undefined) needed.get(port).add(index);
    }
    ports.forEach((port, p) => {
      if ((!port.type || port.type === 'expression') && port.mappings?.length) need(p);
      if (['single', 'dual'].includes(port.type)) port.switches?.forEach((s, i) => {
        if (i < (port.type === 'single' ? 1 : 2) &&
          (s.mappings?.length || ['press', 'hold', 'change'].some(key => assigned(s[key])))) need(p, i);
      });
    });
    for (const rack of rig.racks || []) {
      const match = /^external:(\d+):(\d+)$/.exec(rack.rule?.pedal);
      if (match && rack.rule.condition !== 'always') need(Number(match[1]), Number(match[2]));
    }
    return [...needed].map(([port, switches]) => ({port, type:ports[port]?.type || null,
      switches:[...switches].map(index => ({index, hardware:ports[port]?.switches?.[index]?.hardware || null}))}));
  }

  function capture(rig) {
    const session = pick(rig, musical);
    session.trackPlayback = Object.fromEntries(Object.keys(rig.recordedParts || rig.trackPlayback || {}).map(id => [id, false]));
    session.audioLibrary = pick(rig.audioLibrary || {}, audioFields);
    if (rig.expressionSettings) {
      session.expressionSettings = {nextId:rig.expressionSettings.nextId,
        ports:rig.expressionSettings.ports.map(port => ({mappings:copy(port.mappings || []),
          switches:(port.switches || []).map(s => pick(s, switchFields))}))};
    }
    // A projected snapshot keeps its original requirements when copied for New loop.
    session.sessionRequirements = {controlPorts:copy(rig.sessionRequirements?.controlPorts || requirements(rig))};
    return session;
  }

  function project(current, snapshot, available = {}) {
    const session = capture(snapshot), next = copy(current), issues = [];
    for (const key of musical) {
      delete next[key];
      if (own(session, key)) next[key] = copy(session[key]);
    }
    next.audioLibrary = copy(current.audioLibrary || {});
    for (const key of audioFields) {
      delete next.audioLibrary[key];
      if (own(session.audioLibrary, key)) next.audioLibrary[key] = copy(session.audioLibrary[key]);
    }
    const physical = current.expressionSettings?.ports || [], saved = session.expressionSettings?.ports || [];
    if (current.expressionSettings || session.expressionSettings) {
      next.expressionSettings = copy(current.expressionSettings || {});
      next.expressionSettings.nextId = session.expressionSettings?.nextId || 1;
      next.expressionSettings.ports = Array.from({length:Math.max(physical.length, saved.length)}, (_, p) => {
        const port = copy(physical[p] || {}), source = saved[p];
        port.mappings = copy(source?.mappings || []);
        port.switches = Array.from({length:Math.max(port.switches?.length || 0, source?.switches?.length || 0)}, (_, i) => {
          const result = copy(physical[p]?.switches?.[i] || {});
          for (const key of switchFields) delete result[key];
          return {...result, press:'none', hold:'none', change:'none', mappings:[], ...copy(source?.switches?.[i] || {})};
        });
        return port;
      });
    }
    delete next.sessionRequirements;
    // Preserve every target/source ID. Availability is evidence, never a remap.
    for (const requirement of session.sessionRequirements.controlPorts) {
      const port = physical[requirement.port], source = 'CTRL ' + (requirement.port + 1);
      if (!port || port.type !== requirement.type) {
        issues.push({kind:'control-type', source, port:requirement.port, expected:requirement.type, actual:port?.type || null});
        continue;
      }
      if (available.controlConnected?.[requirement.port] !== true) issues.push({kind:'control-connection', source, port:requirement.port});
      if (requirement.type === 'expression' && (!Number.isFinite(port.calibration?.heel) ||
        !Number.isFinite(port.calibration?.toe) || Math.abs(port.calibration.toe - port.calibration.heel) < .1)) {
        issues.push({kind:'control-calibration', source, port:requirement.port});
      }
      for (const s of requirement.switches) {
        const hardware = port.switches?.[s.index]?.hardware;
        if (s.index >= (port.type === 'dual' ? 2 : port.type === 'single' ? 1 : 0) || !s.hardware || hardware !== s.hardware) {
          issues.push({kind:'switch-hardware', source, port:requirement.port, index:s.index, expected:s.hardware, actual:hardware || null});
        }
      }
    }
    const devices = [...new Set((session.midiMappings || []).map(m => m.device))];
    for (const id of devices) if (!available.midiPorts?.some(p => p.id === id && p.online)) issues.push({kind:'midi-device', id});
    const targets = new Set();
    for (const port of saved) {
      for (const mapping of port.mappings || []) targets.add(mapping.target);
      for (const s of port.switches || []) for (const mapping of s.mappings || []) targets.add(mapping.target);
    }
    for (const mapping of session.midiMappings || []) for (const control of mapping.controls || []) {
      if (control.kind === 'parameter') targets.add(control.key);
    }
    for (const id of targets) if (!available.targetKeys?.includes(id)) issues.push({kind:'control-target', id});
    const audio = session.audioLibrary;
    if (audio.prepared?.length || audio.backing || Object.keys(audio.trackImports || {}).length) {
      if (!Array.isArray(available.mediaIssues)) issues.push({kind:'media-unverified'});
      else issues.push(...copy(available.mediaIssues).map(problem => ({...problem, kind:'media'})));
    }
    return {rig:next, issues, ready:issues.length === 0};
  }

  const api = {capture, project};
  root.SegnoSessionFieldOwnership = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
