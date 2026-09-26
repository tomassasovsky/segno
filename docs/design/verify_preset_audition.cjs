const {test} = require('node:test');
const assert = require('node:assert/strict');
const api = require('./preset-audition-study.js');
const copy = value => structuredClone(value);
function fixture() {
  return {rack:{id:'rack-7',name:'Unsaved sound',family:'Guitar Rack',source:'Track 2 / Guitar',rule:{pedal:'external:1:0',condition:'held'},bypass:true,
    custom:{retain:true},modules:[
      {name:'Delay',expressionId:'delay-stable',bypass:true,params:[['Delay',0,'',1],['Mix',.37,'',.5]]},
      {name:'Amp',expressionId:'amp-stable',sourceValues:true,params:[['Amp',1,'',1],['Drive',.19,'',.4]]}
    ]},channels:{input:'left',output:'mono',pan:['Pan',.21,'',.5]}};
}
function preset(name = 'Clean') {
  return {id:'factory-clean',name,family:'Guitar Rack',artwork:'guitar',raw:{source:'fixture'},origin:'Factory',modules:[
    {name:'Amp',params:[['Amp',1,''],['Drive',.8,'']],sourceValues:true},
    {name:'Delay',params:[['Delay',1,''],['Mix',.6,'']],bypass:false}
  ],channels:{input:'stereo',output:'stereo',pan:['Pan',.5,'',.5]}};
}
function rig(original = fixture()) {
  let scope = copy(original), saved = copy(original), fail = false, attempts = [], previews = 0;
  const ctx = {read:id=>scope?.rack.id===id?copy(scope):null,preview:value=>{scope=copy(value);previews++;},restore:value=>scope=copy(value),
    publish:(value,before)=>{attempts.push({value:copy(value),before:copy(before)});if(fail)return false;saved=copy(value);return true;}};
  return {ctx, session:api.createSession(ctx), read:()=>copy(scope), saved:()=>copy(saved), fail:value=>fail=value,
    mutate:fn=>fn(scope), attempts:()=>copy(attempts), previews:()=>previews};
}
test('same family/name/key layout maps values onto stable IDs and existing effect order', () => {
  const original = fixture(), p = preset(), before = copy(original), sourceBefore = copy(p), result = api.candidate(original,p).scope;
  assert.deepEqual(result.rack.modules.map(m=>m.expressionId),['delay-stable','amp-stable']);
  assert.deepEqual(result.rack.modules.map(m=>m.name),['Delay','Amp']);
  assert.equal(result.rack.modules[0].params[1][1],.6);assert.equal(result.rack.modules[1].params[1][1],.8);
  for(const field of ['id','source','rule','bypass','custom'])assert.deepEqual(result.rack[field],original.rack[field]);
  assert.deepEqual(result.channels,p.channels);assert.deepEqual(original,before);assert.deepEqual(p,sourceBefore);
});
test('different family, modules, duplicate module names, keys and corrupt values are refused explicitly', () => {
  for(const change of [p=>p.family='Studio Rack',p=>p.modules.pop(),p=>p.modules[1].name='Amp',p=>p.modules[0].params[1][0]='Removed',p=>p.modules[0].params[1][1]=NaN,p=>p.modules[0]=null]) {
    const original=fixture(),p=preset();change(p);const before=copy(original);assert(api.compatibility(original,p));assert(api.candidate(original,p).error);assert.deepEqual(original,before);
  }
});
test('original is captured once across multiple previews and Cancel restores exact values, enable, placement and assignments', () => {
  const original=fixture(),r=rig(original);assert(r.session.begin('rack-7'));assert(r.session.select(preset()));
  const second=preset('Second');second.modules[1].params[1][1]=.92;r.session.select(second);
  assert.equal(r.read().rack.modules[0].params[1][1],.92);assert.deepEqual(r.session.original(),original);
  r.session.cancel();assert.deepEqual(r.read(),original);assert.deepEqual(r.saved(),original);assert.equal(r.session.active(),false);
});
test('preview and MIDI changes never enter ordinary persistence; unrelated setup remains current', () => {
  const original=fixture(),r=rig(original);r.session.begin('rack-7');r.session.select(preset());
  r.mutate(scope=>{scope.rack.modules[0].params[1][1]=.99;scope.rack.bypass=false;scope.channels.pan[1]=.88;});
  const other={id:'rack-8',name:'Other rack',modules:[]};
  const live={racks:[other,r.read().rack],channels:{'rack-7':r.read().channels},midiMappings:[{id:'mapping',controls:[{key:'delay-stable'}]}],tempo:123};
  const before=copy(live), projected=r.session.persisted(live);
  assert.deepEqual(projected.racks,[other,original.rack]);assert.deepEqual(projected.channels['rack-7'],original.channels);
  assert.deepEqual(projected.midiMappings,live.midiMappings);assert.equal(projected.tempo,123);assert.deepEqual(live,before);
  r.session.cancel();assert.deepEqual(r.read(),original);
});
test('Cancel and persistence remove trial channel overrides when no original override existed', () => {
  const original=fixture();delete original.channels;const r=rig(original);r.session.begin('rack-7');r.session.select(preset());
  const projected=r.session.persisted({racks:[r.read().rack],channels:{'rack-7':r.read().channels,'rack-8':{keep:true}}});
  assert.equal(Object.hasOwn(projected.channels,'rack-7'),false);assert.deepEqual(projected.channels['rack-8'],{keep:true});
  r.session.cancel();assert.equal(Object.hasOwn(r.read(),'channels'),false);
});
test('failed Keep preserves temporary sound and original baseline; retry publishes latest audition values once', () => {
  const original=fixture(),r=rig(original);r.session.begin('rack-7');r.session.select(preset());r.mutate(scope=>scope.rack.modules[1].params[1][1]=.44);
  const trying=r.read();r.fail(true);assert.equal(r.session.keep(),false);assert.equal(r.session.active(),true);assert.deepEqual(r.read(),trying);
  assert.deepEqual(r.saved(),original);assert.deepEqual(r.session.original(),original);assert.match(r.session.snapshot().error,/Could not save/);
  r.fail(false);assert(r.session.keep());assert.deepEqual(r.saved(),trying);assert.equal(r.session.active(),false);
  assert.deepEqual(r.attempts().map(a=>a.value),[trying,trying]);assert.deepEqual(r.attempts()[1].before,original);
});
test('Cancel after failed Keep restores unsaved edits and never publishes them', () => {
  const original=fixture(),r=rig(original);r.session.begin('rack-7');r.session.select(preset());r.fail(true);r.session.keep();r.session.cancel();
  assert.deepEqual(r.read(),original);assert.deepEqual(r.saved(),original);assert.equal(r.attempts().length,1);
});
test('Keep needs a chosen preset; a removed rack refuses and opening another attempt restores previous trial first', () => {
  const r=rig();r.session.begin('rack-7');assert.equal(r.session.keep(),false);assert.equal(r.attempts().length,0);
  r.session.select(preset());r.mutate(scope=>scope.rack.id='removed');assert.equal(r.session.keep(),false);assert.match(r.session.snapshot().error,/rack changed/);
  assert(r.session.begin('rack-7'));assert.equal(r.read().rack.name,'Unsaved sound');assert.equal(r.session.snapshot().selected,null);
});
test('unchosen or incompatible preset cannot create a publication or partial preview', () => {
  const r=rig(),bad=preset();bad.family='Other';assert.equal(r.session.select(preset()),false);
  r.session.begin('rack-7');assert.equal(r.session.select(bad),false);assert.equal(r.previews(),0);assert.equal(r.session.keep(),false);
});
function uiRig() {
  const r=rig(),events=[],ui=api.createUI({...r.ctx,button:(id,text,cls='',extra='')=>`<button data-action="${id}" ${extra}>${text}</button>`,escape:String,
    render:()=>events.push('render'),focus:id=>events.push(id)});
  return {...r,ui,events};
}
test('touch and encoder focus preview the same rows; repeat focus does not erase a trial control edit', () => {
  const r=uiRig();r.ui.open({rackId:'rack-7',presets:[preset(),preset('Second')]});assert.equal(r.previews(),0);
  r.ui.action('audition:choose:0');assert.equal(r.previews(),1);r.mutate(scope=>scope.rack.modules[0].params[1][1]=.17);
  r.ui.focused('audition:choose:0');assert.equal(r.previews(),1);assert.equal(r.read().rack.modules[0].params[1][1],.17);
  r.ui.focused('audition:choose:1');assert.equal(r.previews(),2);assert.equal(r.read().rack.name,'Second');
  r.ui.action('audition:keep');assert.equal(r.ui.active(),false);assert.equal(r.saved().rack.name,'Second');
});
test('visible bypass and incompatible reasons are retained; Back and navigation cancel exact trial scope', () => {
  for(const exit of ['back','leave','cancel']) {
    const r=uiRig(),bad=preset();bad.family='Other';r.ui.open({rackId:'rack-7',presets:[preset(),bad]});
    assert.match(r.ui.overlay(),/Rack bypassed/);assert.match(r.ui.overlay(),/Choose a preset from this rack family/);
    r.ui.action('audition:choose:0');r.ui[exit]();assert.equal(r.ui.active(),false);assert.deepEqual(r.read(),fixture());
    r.ui.action('audition:keep');r.ui.focused('audition:choose:0');assert.equal(r.attempts().length,0);
  }
});
