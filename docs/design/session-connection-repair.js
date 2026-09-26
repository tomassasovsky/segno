// Pure pending-session repair for the silent prototype. The host owns the draft,
// archived-entry freshness check, final ownership projection and publication.
(function (root) {
  'use strict';
  const copy = value => structuredClone(value);
  const protocol=typeof module!=='undefined'&&module.exports?require('./midi-protocol-study.js'):root.SegnoMidiProtocol;
  const assigned = value => !!value && value !== 'none';
  const portName = port => 'CTRL ' + (port + 1);
  const requirements = snapshot => snapshot.sessionRequirements?.controlPorts || [];
  const ports = rig => rig.expressionSettings?.ports || [];
  const mappings = snapshot => snapshot.midiMappings || [];
  const external = rack => /^external:(\d+):(\d+)$/.exec(rack.rule?.pedal);
  const typeName = type => ({expression:'Expression', single:'Single switch', dual:'Dual switch'})[type];
  const readable = text => String(text || '').replace(/^command:/, '').replace(/[:_-]+/g, ' ').replace(/^./, c => c.toUpperCase());
  const actionName = (key, available) => available.actions?.find(a => a.key === key)?.label || readable(key);
  function parameterName(control) {
    if (control.label) return [control.detail, control.label].filter(Boolean).join(' · ');
    try {
      const key = JSON.parse(control.target || control.key);
      if (Array.isArray(key)) return key.slice(1).map(readable).join(' · ') || 'Missing control';
    } catch { /* An unresolved target stays unresolved in the repaired snapshot. */ }
    return 'Missing control';
  }
  const midiSource = source => protocol.name(source).replace('Omni','All channels');
  const validMidiSource = protocol.validSource;
  // Compare exact semantic sources and overlapping raw protocol constituents.
  const overlaps = protocol.overlaps;

  function affected(snapshot, available, source) {
    if (source.kind === 'midi') return mappings(snapshot).filter(m => m.device === source.id).flatMap(m => {
      const labels = (m.controls || []).map(c => c.kind === 'action' ? actionName(c.key, available) : parameterName(c));
      return (labels.length ? labels : ['No assigned controls']).map(label => midiSource(m.source) + ' · ' + label);
    });
    const saved = ports(snapshot)[source.port], result = (saved?.mappings || []).map(parameterName);
    (saved?.switches || []).forEach((s, i) => {
      for (const key of ['press', 'hold', 'change']) if (assigned(s[key])) result.push(`Button ${i + 1} · ${key === 'change' ? 'On change' : readable(key)} · ${actionName(s[key], available)}`);
      for (const mapping of s.mappings || []) result.push(`Button ${i + 1} · ${parameterName(mapping)}`);
    });
    for (const rack of snapshot.racks || []) {
      const match = external(rack);
      if (match && Number(match[1]) === source.port) result.push(`Button ${Number(match[2]) + 1} · ${[rack.source, rack.name || rack.label || 'FX rack'].filter(Boolean).join(' · ')} · Activation`);
    }
    return result;
  }

  function sourceError(snapshot, source) {
    if (source?.kind === 'control' && Number.isInteger(source.port) && source.port >= 0) {
      const requirement = requirements(snapshot).find(r => r.port === source.port);
      if (!requirement) return 'This saved pedal connection is no longer assigned. Review the session again.';
      if (!typeName(requirement.type) || !Array.isArray(requirement.switches)) return 'This saved pedal has an unreadable hardware requirement.';
      return '';
    }
    if (source?.kind === 'midi' && typeof source.id === 'string' && source.id) {
      const saved = mappings(snapshot).filter(m => m.device === source.id);
      if (!saved.length) return 'This saved MIDI connection is no longer assigned. Review the session again.';
      if (saved.some(m => !validMidiSource(m.source))) return 'This saved MIDI connection has an unreadable message source.';
      return '';
    }
    return 'Choose a saved controller connection to repair.';
  }

  function occupied(snapshot, port) {
    const saved = ports(snapshot)[port];
    return requirements(snapshot).some(r => r.port === port) || !!saved?.mappings?.length ||
      !!saved?.switches?.some(s => s.mappings?.length || ['press', 'hold', 'change'].some(key => assigned(s[key]))) ||
      (snapshot.racks || []).some(rack => Number(external(rack)?.[1]) === port);
  }

  function controlReason(snapshot, current, available, source, id) {
    if (id === source.port) return 'This is the original connection. Choose another pedal port.';
    if (occupied(snapshot, id)) return 'This port already has assignments in the saved session.';
    const required = requirements(snapshot).find(r => r.port === source.port), physical = ports(current)[id];
    if (physical.type !== required.type) return 'Needs ' + typeName(required.type).toLowerCase() + ' setup.';
    if (available.controlConnected?.[id] !== true) return 'This pedal is not connected.';
    if (required.type === 'expression' && (!Number.isFinite(physical.calibration?.heel) ||
      !Number.isFinite(physical.calibration?.toe) || Math.abs(physical.calibration.toe - physical.calibration.heel) < .1)) return 'Calibrate this expression pedal first.';
    const count = required.type === 'dual' ? 2 : required.type === 'single' ? 1 : 0;
    for (const s of required.switches) {
      if (!Number.isInteger(s.index) || s.index < 0 || s.index >= count || !['momentary', 'latching'].includes(s.hardware)) return 'This saved pedal has an unreadable switch requirement.';
      if (physical.switches?.[s.index]?.hardware !== s.hardware) return `Button ${s.index + 1} needs ${s.hardware} hardware.`;
    }
    return '';
  }

  function midiReason(snapshot, device, source) {
    if (device.id === source.id) return 'This is the original connection. Choose another MIDI controller.';
    if (!device.online) return 'This MIDI controller is not connected.';
    const moved = mappings(snapshot).filter(m => m.device === source.id), existing = mappings(snapshot).filter(m => m.device === device.id);
    const collision = moved.find((m, i) => [...existing, ...moved.slice(i + 1)].some(other => validMidiSource(other.source) && overlaps(m.source, other.source)));
    return collision ? midiSource(collision.source) + ' overlaps a saved mapping on this controller.' : '';
  }

  function options(snapshot, current, available, source) {
    if (sourceError(snapshot, source)) return [];
    const assignments = affected(snapshot, available, source);
    const choices = source.kind === 'control' ? ports(current).map((physical, id) => ({id,
      label:portName(id) + (typeName(physical.type) ? ' · ' + typeName(physical.type) : ''),
      reason:controlReason(snapshot, current, available, source, id)})) :
      (available.midiPorts || []).map(device => ({id:device.id, label:device.name || device.id, reason:midiReason(snapshot, device, source)}));
    return choices.map(choice => ({...choice, enabled:!choice.reason, affected:[...assignments]}));
  }

  function musicalPort(port) {
    return {mappings:copy(port?.mappings || []), switches:(port?.switches || []).map(s =>
      Object.fromEntries(['press', 'hold', 'change', 'mappings'].filter(key => Object.hasOwn(s, key)).map(key => [key, copy(s[key])])))};
  }

  function repair(snapshot, current, available, source, replacement) {
    const error = sourceError(snapshot, source);
    if (error) return {error};
    // Recompute against the supplied current inventories and latest pending draft.
    const choice = options(snapshot, current, available, source).find(row => row.id === replacement);
    if (!choice) return {error:'The selected controller is no longer available. Choose another connection.'};
    if (!choice.enabled) return {error:choice.reason};
    const next = copy(snapshot);
    let from;
    if (source.kind === 'control') {
      from = portName(source.port);
      const saved = musicalPort(ports(snapshot)[source.port]);
      next.expressionSettings ||= {ports:[]};
      next.expressionSettings.ports ||= [];
      while (next.expressionSettings.ports.length <= replacement) next.expressionSettings.ports.push({mappings:[], switches:[]});
      next.expressionSettings.ports[source.port] = {mappings:[], switches:[]};
      next.expressionSettings.ports[replacement] = saved;
      for (const rack of next.racks || []) {
        const match = external(rack);
        if (match && Number(match[1]) === source.port) rack.rule.pedal = `external:${replacement}:${match[2]}`;
      }
      for (const requirement of next.sessionRequirements.controlPorts) if (requirement.port === source.port) requirement.port = replacement;
    } else {
      from = available.midiPorts?.find(p => p.id === source.id)?.name || source.id;
      for (const mapping of next.midiMappings) if (mapping.device === source.id) mapping.device = replacement;
    }
    return {snapshot:next, changes:[`${from} → ${choice.label}`, ...choice.affected]};
  }

  const api = {options, repair};
  root.SegnoSessionConnectionRepair = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
