const {test} = require('node:test');
const assert = require('node:assert/strict');
const api = require('./primary-track-study.js');
const copy = value => structuredClone(value);
const context = (mode = 'sync') => ({mode, primaryTrack:'Track 1', pending:false, capturing:false, tracks:[
  {id:'Track 1', label:'Beat', hasAudio:true, beats:16, loopBeats:16, playing:false},
  {id:'Track 2', label:'Verse', hasAudio:true, beats:8, loopBeats:8, playing:false},
  {id:'Track 3', label:'Chorus', hasAudio:false, beats:0, loopBeats:0, playing:false},
]});
function rig(c = context()) {
  let fail = false, saved = copy(c), commits = [], page = '', focus = '';
  const ui = api.createUI({context:() => c, commit:(id, options) => {
    commits.push({id, options});if (fail) return false;
    c.primaryTrack = id;if (options.stop) c.tracks.forEach(t => t.playing = false);saved = copy(c);return true;
  }, button:(id,text,cls='',extra='') => `<button data-action="${id}" ${extra}>${text}</button>`, header:title=>title, escape:String,
  render:()=>{}, focus:id=>focus=id, go:value=>page=value});
  return {ui, c, saved:()=>copy(saved), commits:()=>copy(commits), fail:value=>fail=value, page:()=>page, focus:()=>focus};
}

test('explicit valid source wins; empty or removed source falls back to first recorded track', () => {
  const c = context();c.primaryTrack = 'Track 2';assert.equal(api.current(c), 'Track 2');
  c.primaryTrack = 'removed';assert.equal(api.current(c), 'Track 1');c.tracks.forEach(t => t.hasAudio = false);assert.equal(api.current(c), null);
});
for (const mode of ['sync','band']) test(mode + ' offers compatible recorded tracks and refuses empty tracks', () => {
  const c = context(mode);assert.equal(api.availability(c,'Track 2').enabled,true);
  assert.match(api.availability(c,'Track 3').reason,/Record this track/);
  assert.match(api.availability(c,'removed').reason,/Record this track/);
});
for (const mode of ['multi','song','free']) test(mode + ' cannot silently adopt timing-source semantics', () => {
  assert.equal(api.availability(context(mode),'Track 2').enabled,false);
});
test('ratio check rejects a source that is incompatible with another retained recording', () => {
  const c = context();c.tracks[2] = {...c.tracks[2], hasAudio:true, beats:12, loopBeats:12};
  assert.equal(api.availability(c,'Track 2').enabled,false);assert.match(api.availability(c,'Track 2').reason,/multiples or divisions/);
  assert.equal(api.availability(c,'Track 3').enabled,false);
});
test('timeline span takes priority over sparse captured duration and never rewrites either', () => {
  const c = context();c.tracks[1].beats = 3;c.tracks[1].loopBeats = 16;
  const before = copy(c);assert.equal(api.availability(c,'Track 2').enabled,true);assert.deepEqual(c,before);
  c.tracks[1].loopBeats = NaN;assert.match(api.availability(c,'Track 2').reason,/unavailable/);
});
for (const block of ['capturing','pending','track-capture']) test(block + ' blocks source changes even while stopped', () => {
  const c = context();if (block === 'track-capture') c.tracks[0].capturing = 'record';else c[block] = true;
  assert.equal(api.availability(c,'Track 2').enabled,false);
});
test('stopped handoff commits directly, retains recorded spans and does not request a restart', () => {
  const r = rig(), tracks = copy(r.c.tracks);r.ui.action('primary:open');assert.equal(r.page(),'loop-primary');
  r.ui.action('primary:choose:Track%202');assert.equal(r.saved().primaryTrack,'Track 2');assert.deepEqual(r.c.tracks,tracks);
  assert.deepEqual(r.commits(),[{id:'Track 2',options:{stop:false}}]);assert.equal(r.ui.label(),'Verse');
});
test('choosing the current track does not stop playback or publish', () => {
  const r = rig();r.c.tracks[0].playing = true;r.ui.action('primary:choose:Track%201');
  assert.equal(r.commits().length,0);assert.equal(r.c.tracks[0].playing,true);assert.equal(r.ui.snapshot().pending,null);
});
test('playing handoff stages confirmation; Cancel and Back preserve all state', () => {
  const r = rig();r.c.tracks[0].playing = true;const before = copy(r.c);
  r.ui.action('primary:choose:Track%202');assert.deepEqual(r.ui.snapshot().pending,{id:'Track 2'});assert.equal(r.commits().length,0);
  assert.match(r.ui.overlay(),/Stop and switch/);r.ui.action('primary:cancel');assert.deepEqual(r.c,before);
  r.ui.action('primary:choose:Track%202');assert(r.ui.back());assert.deepEqual(r.c,before);assert.equal(r.ui.snapshot().pending,null);
});
test('confirm revalidates capture, pending action, disappearance and changed lengths before commit', () => {
  for (const invalidate of [c=>c.capturing=true,c=>c.pending=true,c=>c.tracks[1].hasAudio=false,c=>c.tracks[1].loopBeats=7]) {
    const r = rig();r.c.tracks[0].playing = true;r.ui.action('primary:choose:Track%202');invalidate(r.c);
    const before = copy(r.c);r.ui.action('primary:confirm');assert.equal(r.commits().length,0);assert.deepEqual(r.c,before);assert(r.ui.snapshot().error);
  }
});
test('failed save retains playing tracks and pending confirmation; successful retry stops and changes only source', () => {
  const r = rig();r.c.tracks[0].playing = true;r.ui.action('primary:choose:Track%202');const before = copy(r.c);r.fail(true);
  r.ui.action('primary:confirm');assert.deepEqual(r.c,before);assert(r.ui.snapshot().pending);assert.match(r.ui.snapshot().error,/Could not save/);
  r.fail(false);r.ui.action('primary:confirm');assert.equal(r.c.primaryTrack,'Track 2');assert(r.c.tracks.every(t=>!t.playing));
  assert.deepEqual(r.c.tracks.map(t=>[t.beats,t.loopBeats]),before.tracks.map(t=>[t.beats,t.loopBeats]));assert.equal(r.ui.snapshot().pending,null);
});
test('leaving clears stale confirmation and source labels remain readable', () => {
  const r = rig();r.c.tracks[0].playing = true;r.ui.action('primary:choose:Track%202');r.ui.leave();r.ui.action('primary:confirm');
  assert.equal(r.commits().length,0);assert.match(r.ui.body(),/Beat/);assert.match(r.ui.body(),/Timing source/);
});
