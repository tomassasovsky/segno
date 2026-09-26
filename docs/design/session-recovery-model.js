// Session media recovery design model. This works with simulated descriptors,
// not native files. The caller owns the pending snapshot and final Open action.
(function (root) {
  'use strict';
  const copy = value => structuredClone(value);
  const recorded = typeof module !== 'undefined' && module.exports ? require('./recorded-audio-model.js') : root.SegnoRecordedAudio;
  const performance = typeof module !== 'undefined' && module.exports ? require('./performance-recording-model.js') : root.SegnoPerformanceRecording;
  const format = value => String(value || '').toUpperCase();
  const multipart = file => 'performance' in file || 'parts' in file;
  const readable = file => descriptor(file) && !recorded.descriptor(file) && !file.unreadable && !file.damaged && ['WAV', 'MP3'].includes(format(file.format)) && (!multipart(file) || format(file.format) === 'WAV' && !performance.manifest(file).error);
  const compatible = (problem, file) => !problem.unverifiedImport && readable(file) && problem.trackRequirements.every(expected => file.seconds === expected.seconds && format(file.format) === format(expected.format));
  function samePerformance(expected, current) {
    const original = performance.manifest(expected), present = performance.manifest(current);
    return !original.error && !present.error && JSON.stringify(original) === JSON.stringify(present) && JSON.stringify(expected.performance.recordingFormat) === JSON.stringify(current.performance.recordingFormat);
  }
  const object = value => !!value && typeof value === 'object' && !Array.isArray(value);
  const descriptor = value => object(value) && typeof value.id === 'string' && !!value.id && typeof value.name === 'string' && Number.isFinite(value.seconds) && value.seconds > 0 && typeof value.format === 'string';
  function valid(snapshot) {
    const audio=snapshot?.audioLibrary;
    return recorded.valid(snapshot) && object(audio) && (audio.prepared===undefined || Array.isArray(audio.prepared)&&audio.prepared.every(id=>typeof id==='string'&&!!id)) &&
      (audio.backing==null || descriptor(audio.backing)) && (audio.trackImports===undefined || object(audio.trackImports)&&Object.entries(audio.trackImports).every(([track,item])=>/^[0-7]$/.test(track)&&object(item)&&descriptor(item.file))) &&
      recorded.importedReferences(snapshot).every(row=>typeof row.id==='string'&&!!row.id&&(row.file===undefined||descriptor(row.file)));
  }

  function inspect(snapshot, files) {
    if(!valid(snapshot))throw new Error('This session has unreadable audio references.');
    const audio = snapshot.audioLibrary || {}, references = new Map();
    function reference(id, usage, descriptor, track) {
      if (!references.has(id)) references.set(id, {id, name:descriptor?.name || 'Missing backing audio', usages:[], trackRequirements:[]});
      const row = references.get(id);
      if (descriptor?.name) row.name = descriptor.name;
      if (!row.usages.includes(usage)) row.usages.push(usage);
      if (track !== undefined) {
        if(descriptor)row.trackRequirements.push({track, seconds:descriptor.seconds, format:descriptor.format});
        else row.unverifiedImport=true;
      }
      if (descriptor && multipart(descriptor)) (row.performanceRequirements ||= []).push(descriptor);
    }
    for (const id of audio.prepared || []) reference(id, 'Prepared audio');
    if (audio.backing) reference(audio.backing.id, 'Backing track', audio.backing);
    for (const [track, imported] of Object.entries(audio.trackImports || {})) {
      if (imported?.file) reference(imported.file.id, 'Track ' + (Number(track) + 1), imported.file, Number(track));
    }
    for(const row of recorded.importedReferences(snapshot))reference(row.id,row.usage,row.file,row.track);
    const problems = [];
    for (const row of references.values()) {
      const current = files.find(file => file.id === row.id);
      const reason = !current ? 'missing' : !readable(current) ? 'unreadable' : !compatible(row, current) || row.performanceRequirements?.some(expected => !samePerformance(expected, current)) ? 'changed' : null;
      if (reason) problems.push({...row, reason});
    }
    return copy(problems.concat(recorded.inspect(snapshot,files)));
  }

  function candidates(problem, files) {
    if(problem.kind==='recorded')return recorded.candidates(problem,files);
    return copy(files.filter(file => compatible(problem, file)));
  }

  function repair(snapshot, problemId, selected, files) {
    const problem = inspect(snapshot, files).find(row => row.id === problemId);
    if (!problem) throw new Error('This media reference no longer needs repair. Review the session again.');
    if(problem.kind==='recorded')return recorded.repair(snapshot,problemId,selected,files);
    const current = files.find(file => file.id === selected?.id);
    if (!readable(current)) throw new Error('The selected recording is no longer available. Choose another recording.');
    // Candidates are complete descriptor copies. Reject any descriptor change
    // after selection, including a rename, before publishing it into the draft.
    if (JSON.stringify(current) !== JSON.stringify(selected)) throw new Error('The selected recording changed. Select it again.');
    if (!compatible(problem, current)) throw new Error('Choose a recording with the original duration and format to preserve track timing.');
    const next = recorded.repairImported(snapshot,problemId,current), audio = next.audioLibrary;
    if (audio.prepared) audio.prepared = [...new Set(audio.prepared.map(id => id === problemId ? current.id : id))];
    if (audio.backing?.id === problemId) audio.backing = copy(current);
    for (const imported of Object.values(audio.trackImports || {})) {
      if (imported?.file?.id === problemId) imported.file = copy(current);
    }
    return next;
  }

  const api = {valid, inspect, candidates, repair};
  root.SegnoSessionRecovery = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
