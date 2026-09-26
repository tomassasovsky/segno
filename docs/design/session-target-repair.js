// Pure pending-session target repair. Descriptors supply normalized coercion and
// formatting; this model never calls get/set/persist or creates target identities.
// The host owns the archived-entry freshness check and final session publication.
(function (root) {
  'use strict';
  const copy = value => structuredClone(value);
  const protocol=typeof module!=='undefined'&&module.exports?require('./midi-protocol-study.js'):root.SegnoMidiProtocol;
  const object = value => !!value && typeof value === 'object' && !Array.isArray(value);
  const normalized = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1;
  function list(value) {
    if (value === undefined) return [];
    if (!Array.isArray(value) || value.some(item => !object(item))) throw new Error('This saved control has an unreadable source.');
    return value;
  }
  const midiName = m => `MIDI ${m.device} · ${protocol.name(m.source).replace('Omni','All channels')}`;
  const validMidi = m => typeof m.device === 'string' && !!m.device && protocol.validSource(m.source) &&
    (m.source.kind === 'program' || ['continuous', 'momentary', 'toggle'].includes(m.behavior));

  function inspect(snapshot, key) {
    const refs = [];
    let error = '';
    function add(mapping, path, context, group, keyField, source, fields) {
      if (fields.some(([field]) => !normalized(mapping[field]))) throw new Error(source + ' has an invalid saved endpoint.');
      refs.push({mapping, path, context, group, keyField, source,
        values:fields.map(([field, label]) => ({field, label, value:mapping[field]}))});
    }
    try {
      if (!object(snapshot) || typeof key !== 'string' || !key) throw new Error('Choose a missing saved control to repair.');
      if (snapshot.expressionSettings !== undefined && !object(snapshot.expressionSettings)) throw new Error('This saved control has an unreadable source.');
      list(snapshot.expressionSettings?.ports).forEach((port, p) => {
        const expressions = list(port.mappings);
        expressions.forEach((mapping, i) => {
          if (mapping.target === key) add(mapping, ['expressionSettings', 'ports', p, 'mappings', i], expressions, 'expression:' + p,
            'target', `CTRL ${p + 1} · Expression`, [['heel', 'Heel'], ['toe', 'Toe']]);
        });
        list(port.switches).forEach((button, b) => {
          const controls = list(button.mappings);
          controls.forEach((mapping, i) => {
            if (mapping.target !== key) return;
            if (!['on', 'held'].includes(mapping.condition)) throw new Error(`CTRL ${p + 1} · Button ${b + 1} has an unreadable saved condition.`);
            add(mapping, ['expressionSettings', 'ports', p, 'switches', b, 'mappings', i], controls, `switch:${p}:${b}`, 'target',
              `CTRL ${p + 1} · Button ${b + 1}`, [['inactive', mapping.condition === 'held' ? 'Released' : 'Off'], ['active', mapping.condition === 'held' ? 'Held' : 'On']]);
          });
        });
      });
      list(snapshot.midiMappings).forEach((m, i) => {
        const controls = list(m.controls);
        controls.forEach((control, c) => {
          if (control.kind !== 'parameter' || control.key !== key) return;
          if (!validMidi(m)) throw new Error('This MIDI mapping has an unreadable saved source.');
          const program = m.source.kind === 'program';
          // Program never uses low. Preserve it, including an absent field, and
          // only coerce/review high. A stored nonfinite low is still corrupt data.
          if (program && Object.hasOwn(control, 'low') && !normalized(control.low)) throw new Error(midiName(m) + ' has an invalid saved endpoint.');
          const fields = program ? [['high', 'Value']] : [[ 'low', m.behavior === 'continuous' ? 'From' : m.behavior === 'momentary' ? 'Released' : 'Off'],
            ['high', m.behavior === 'continuous' ? 'To' : m.behavior === 'momentary' ? 'Held' : 'On']];
          add(control, ['midiMappings', i, 'controls', c], controls, 'midi:' + i, 'key', midiName(m), fields);
        });
      });
      if (!refs.length) throw new Error('This saved control is no longer assigned. Review the session again.');
      const groups = new Set();
      for (const ref of refs) {
        if (groups.has(ref.group)) throw new Error(ref.source + ' has duplicate assignments for the missing control.');
        groups.add(ref.group);
      }
    } catch (failure) {error = failure.message;}
    const named = refs.find(ref => typeof ref.mapping.label === 'string' && ref.mapping.label);
    return {refs, error, label:named?.mapping.label || 'Missing control', detail:typeof named?.mapping.detail === 'string' ? named.mapping.detail : ''};
  }

  function describe(snapshot, key) {
    const result = inspect(snapshot, key);
    return {label:result.label, detail:result.detail, affected:result.error ? [] : result.refs.map(ref =>
      ({source:ref.source, values:ref.values.map(({label, value}) => ({label, value}))}))};
  }

  function sourceReason(result, targets, key) {
    if (result.error) return result.error;
    if (!Array.isArray(targets)) return 'The current controls could not be read.';
    if (targets.some(target => target?.key === key)) return 'This saved control is available again. Review the session without replacing it.';
    return '';
  }

  function evaluate(result, targets, key, target) {
    const sourceError = sourceReason(result, targets, key);
    if (sourceError) return {error:sourceError};
    if (!target) return {error:'The selected control is no longer available. Choose another control.'};
    if (typeof target.key !== 'string' || !target.key || typeof target.label !== 'string' || !target.label ||
      typeof target.detail !== 'string' || typeof target.destination !== 'string' || typeof target.format !== 'function' ||
      target.coerce !== undefined && typeof target.coerce !== 'function') return {error:'This control has an unreadable value descriptor.'};
    if (targets.filter(t => t?.key === target.key).length !== 1) return {error:'This control has an ambiguous target identity.'};
    try {
      if (target.enabled === false || typeof target.enabled === 'function' && !target.enabled()) return {error:target.unavailableReason || 'This control is unavailable right now.'};
      for (const ref of result.refs) {
        if (ref.context.some(m => m !== ref.mapping && (ref.keyField !== 'key' || m.kind === 'parameter') && m[ref.keyField] === target.key)) {
          return {error:ref.source + ' already controls this parameter.'};
        }
      }
      const affected = result.refs.map(ref => ({source:ref.source, values:ref.values.map(value => {
        const coerced = target.coerce ? target.coerce(value.value) : value.value;
        if (!normalized(coerced)) throw new Error('This control produced an invalid endpoint.');
        const formatted = target.format(coerced);
        if (typeof formatted !== 'string' || !formatted) throw new Error('This control produced an unreadable value.');
        return {...value, value:coerced, formatted};
      })}));
      return {target, affected};
    } catch {return {error:'The selected control could not represent these saved endpoints.'};}
  }

  function options(snapshot, targets, key) {
    const result = inspect(snapshot, key);
    if (!Array.isArray(targets)) return [];
    return targets.filter(object).map(target => {
      const checked = evaluate(result, targets, key, target);
      return {key:target.key, destination:target.destination,
        destinationLabel:typeof target.destinationLabel === 'string' ? target.destinationLabel : target.destination,
        detail:target.detail, label:target.label,
        note:target.type === 'unresolved' || target.resolution === 'source-value' ? 'Scale unverified · source values' :
          typeof target.note === 'string' ? target.note : typeof target.descriptor?.note === 'string' ? target.descriptor.note : '',
        enabled:!checked.error, reason:checked.error || ''};
    });
  }

  function preview(snapshot, targets, key, replacementKey) {
    const result = inspect(snapshot, key), checked = evaluate(result, targets, key,
      Array.isArray(targets) ? targets.find(target => target?.key === replacementKey) : null);
    if (checked.error) return {label:result.label, detail:result.detail, affected:[], error:checked.error};
    return {label:checked.target.label, detail:checked.target.detail,
      affected:checked.affected.map(row => ({source:row.source, values:row.values.map(({label, value, formatted}) => ({label, value, formatted}))}))};
  }

  function repair(snapshot, targets, key, replacementKey) {
    const result = inspect(snapshot, key), checked = evaluate(result, targets, key,
      Array.isArray(targets) ? targets.find(target => target?.key === replacementKey) : null);
    if (checked.error) return {error:checked.error};
    const next = copy(snapshot), target = checked.target;
    result.refs.forEach((ref, i) => {
      const mapping = ref.path.reduce((value, key) => value[key], next);
      mapping[ref.keyField] = target.key;
      mapping.label = target.label;
      mapping.detail = target.detail;
      for (const value of checked.affected[i].values) mapping[value.field] = value.value;
    });
    return {snapshot:next, change:{from:{label:result.label,detail:result.detail},to:{label:target.label,detail:target.detail},
      affected:checked.affected.map(row => row.source + ' · ' + row.values.map(value => value.label + ': ' + value.formatted).join(' · '))}};
  }

  const api = {describe, options, preview, repair};
  root.SegnoSessionTargetRepair = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
