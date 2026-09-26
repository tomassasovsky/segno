const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const fx = require('./fx-parameter-descriptors.js');
const controls = require('./fx-parameter-controls.js');
const library = require('./fx-preset-library.js');
const copy = value => JSON.parse(JSON.stringify(value));
const context = {window:{}};
vm.runInNewContext(fs.readFileSync(path.join(__dirname,'looperx-factory/catalog.js'),'utf8'),context);
const factory = copy(context.window.LOOPERX_FACTORY);
// Exercise the prototype's real factory conversion, using actual source data.
const html = fs.readFileSync(path.join(__dirname,'fx-ux-prototype.html'),'utf8');
const start = html.indexOf('  const moduleGroup='), end = html.indexOf('  function seed(){',start);
assert.ok(start>=0 && end>start,'Factory conversion must be available for the fixture.');
const conversion = new Function('factory','copy','window',html.slice(start,end)+';return {presets,modulesFromPreset};')(factory,copy,{SegnoFxParameters:fx});
const presets = conversion.presets;
const sample = name => copy(presets.find(p=>p.name===name));
function personal(p) {return {name:p.name,family:p.family,artwork:p.artwork,original:copy(p.raw),modules:copy(p.modules),channels:{input:'stereo',output:'stereo',pan:['Pan',0.5,'',0.5]},kind:'Your saved sound'};}
function fixture(initial=[personal(sample('Clean Rhythm'))]) {
  let state=copy(initial), fail=false;
  return {store:library.store({read:()=>state,write:next=>{if(fail)return false;state=next;return true;}}),read:()=>copy(state),fail:value=>{fail=value;}};
}

test('all 159 real presets and 300 family parameters remain exactly represented',()=>{
  assert.equal(presets.length,159);
  let count=0;const before=JSON.stringify(factory);
  for(const family of factory.families){
    const p=presets.find(p=>p.family===family.name), source=family.presets[0];
    const entries=p.modules.flatMap(m=>m.params.map(param=>({m,param,d:fx.describe(m,param)})));
    assert.deepEqual(Object.fromEntries(entries.map(({param})=>[param[0],param[1]])),source.parameters);
    count+=entries.length;
    for(const {m,param,d} of entries){assert.equal(d.defaultValue,param[1]);assert.ok(['switch','continuous','unresolved'].includes(d.type));assert.ok(controls.render(m,0,param,0));}
  }
  assert.equal(count,300);assert.equal(JSON.stringify(factory),before);
  for(const p of presets) assert.deepEqual(JSON.parse(p.raw.content),{...p.parameters,_version:p.version});
});

test('actual factory-disabled module keys control bypass and survive round-trip enable',()=>{
  let checks=0;
  for(const preset of presets) for(const m of preset.modules){
    const p=fx.powerParameter(m);if(!p)continue;
    assert.ok(p[1]===0||p[1]===1,`${preset.family}/${p[0]} is not a source switch`);
    assert.equal(fx.enabled(m),p[1]===1);const prior=p[1];
    fx.setEnabled(m,!prior);assert.equal(fx.enabled(m),!prior);assert.equal(p[1],1-prior);
    fx.setEnabled(m,!!prior);assert.equal(p[1],prior);checks++;
  }
  assert.ok(checks>800);
  const chorus=presets.find(p=>p.family==="Ed's Rack").modules.find(m=>m.name==='Chorus');
  assert.equal(fx.powerParameter(chorus)[0],'Chor');assert.equal(fx.enabled(chorus),false);
  chorus.bypass=true;fx.setEnabled(chorus,true);assert.equal(fx.enabled(chorus),true);
});

test('hidden controls stay visible without inventing native options or units',()=>{
  const names=['Amp Modern','Del Mode','Oct High Mode','Rev Mode','Mod Mode','Slic Patt','Slic Step Len','Mode'];
  for(const name of names){const module=presets.flatMap(p=>p.modules).find(m=>m.params.some(p=>p[0]===name));const p=module.params.find(p=>p[0]===name);const d=fx.describe(module,p);
    assert.equal(d.type,'unresolved');assert.equal(d.unit,null);assert.deepEqual(d.options,[]);assert.equal(d.factoryDefault,null);assert.equal(d.defaultKind,'loaded-preset');
    assert.ok(fx.format(d,p[1]).startsWith('Source '));assert.ok(controls.render(module,1,p,2).includes('Scale unverified'));
  }
});

test('touch, encoder, parsing and shared mappings use the same switch and raw-value contract',()=>{
  const p=sample('Clean Rhythm'), rig={racks:[{...p,id:'test-rack',source:'Guitar'}]};
  const targets=fx.targets(rig), count=p.modules.reduce((n,m)=>n+m.params.length,0);assert.equal(targets.length,count);
  const toggle=targets.find(t=>t.type==='switch');toggle.set(.1);assert.equal(toggle.get(),0);toggle.set(.6);assert.equal(toggle.get(),1);
  assert.equal(toggle.parse('Off'),0);assert.throws(()=>toggle.parse('0.4'));assert.equal(toggle.format(toggle.get()),'On');
  const raw=targets.find(t=>t.type==='unresolved');const original=raw.get();raw.set(original);assert.equal(raw.get(),original);
  assert.equal(raw.parse('Source '+original),original);assert.throws(()=>raw.parse('20 ms'));assert.throws(()=>raw.set(NaN));
  assert.equal(fx.turn(raw.descriptor,1,1),1);assert.equal(fx.turn(toggle.descriptor,0,1),1);
  const snapshot=copy(rig);toggle.persist(snapshot,0);assert.equal(toggle.get(),1);
  const [,,id,key]=JSON.parse(toggle.key);assert.equal(snapshot.racks[0].modules.find(m=>m.expressionId===id).params.find(p=>p[0]===key)[1],0);
  const missing=copy(snapshot);missing.racks=[];assert.doesNotThrow(()=>toggle.persist(missing,1));
});

test('Segno channel balance has an explicit independent scale',()=>{
  const d=fx.describe({name:'Rack',params:[]},['Pan',.5,'',.5]);assert.equal(d.type,'continuous');
  assert.equal(fx.format(d,.5),'Centre');assert.equal(fx.parse(d,'L 100'),0);assert.equal(fx.parse(d,'R 20'),.6);assert.throws(()=>fx.parse(d,'L 101'));
  const m={name:'Harmonize',sourceValues:true,params:[]};assert.equal(fx.describe(m,['Voice 1 Pan',.5,'',.5]).type,'unresolved');
});

test('rename/delete/undo affect only My presets, and failed persistence is atomic',()=>{
  const preset=personal(sample('Clean Rhythm')), running=copy(preset), f=fixture([preset]);
  f.store.rename(0,'Clean verse');assert.equal(f.read()[0].name,'Clean verse');assert.equal(running.name,'Clean Rhythm');
  f.fail(true);assert.throws(()=>f.store.rename(0,'Failure'));assert.equal(f.read()[0].name,'Clean verse');
  assert.throws(()=>f.store.remove(0));assert.equal(f.read().length,1);f.fail(false);
  f.store.remove(0);assert.equal(f.read().length,0);assert.ok(f.store.canUndo());assert.ok(f.store.undo());assert.equal(f.read()[0].name,'Clean verse');
  assert.throws(()=>f.store.rename(0,''));assert.throws(()=>f.store.rename(0,'x'.repeat(33)));
  const readOnly=fixture([{...preset,factory:true}]);assert.throws(()=>readOnly.store.remove(0));assert.throws(()=>readOnly.store.rename(0,'Changed'));
});

test('portable import/export preserves raw source, edited values and independent channels',()=>{
  const p=personal(sample('Clean Rhythm'));p.modules[0].params[0][1]=.8123456789;p.modules[0].expressionId='shared-runtime-id';
  const f=fixture([p]), serialized=f.store.export(0), parsed=library.decode(serialized);assert.deepEqual(parsed[0].original,p.original);
  assert.equal(parsed[0].modules[0].params[0][1],.8123456789);assert.equal(parsed[0].modules[0].expressionId,undefined);
  const added=f.store.import(f.store.preview(serialized));assert.equal(added[0].name,'Clean Rhythm (2)');assert.equal(f.read().length,2);
  added[0].channels.pan[1]=0;parsed[0].modules[0].params[0][1]=0;assert.equal(f.read()[1].channels.pan[1],.5);assert.equal(f.read()[1].modules[0].params[0][1],.8123456789);
  assert.deepEqual(library.decode(library.encode(parsed))[0],parsed[0]);
});

test('imports validate the whole package and never overwrite or partially save',()=>{
  const f=fixture(), p=personal(sample('Clean Rhythm')), before=f.read();
  const invalid=copy(p);invalid.modules[0].params[0][1]=12;
  assert.throws(()=>f.store.import([p,invalid]));assert.deepEqual(f.read(),before);
  assert.throws(()=>f.store.preview('{'));assert.throws(()=>library.decode(JSON.stringify({format:library.format,version:2,presets:[p]})));
  const attack=copy(p);attack.modules[0].icon='../../anything.png';assert.throws(()=>library.encode([attack]));
  f.fail(true);assert.throws(()=>f.store.import([p]));assert.deepEqual(f.read(),before);
  const long={...p,name:'a'.repeat(32)}, names=library.importedNames([long,long],[long]).map(p=>p.name);assert.equal(new Set(names).size,2);assert.ok(names.every(n=>n.length<=32));
});

test('preset UI preserves the fixed naming keyboard and defers import until review',()=>{
  let state=[personal(sample('Clean Rhythm'))], loaded, exported;
  const ui=library.createUI({read:()=>state,write:next=>{state=next;return true;},button:(id,text)=>`<button data-action="${id}">${text}</button>`,escape:s=>String(s),header:()=>'',artwork:()=>'',render:()=>{},focus:()=>{},notice:()=>{},icon:()=>'',load:p=>{loaded=p;},media:{active:()=>false,action:()=>false,back:()=>false,leave:()=>{},key:()=>false,export:text=>{exported=text;}}});
  ui.action('fxpresets:load:0');loaded.name='Independent';assert.equal(state[0].name,'Clean Rhythm');
  ui.action('fxpresets:rename:0');assert.ok(ui.overlay().includes('keyboard-overlay'));ui.action('fxpresets:key:X');ui.action('fxpresets:rename-save');assert.equal(state[0].name,'X');
  ui.action('fxpresets:export:0');assert.equal(library.decode(exported)[0].name,'X');
  ui.receive(exported);assert.equal(state.length,1);assert.equal(ui.snapshot().modal.type,'import');ui.action('fxpresets:cancel');assert.equal(state.length,1);
  ui.receive(exported);ui.action('fxpresets:import-confirm');assert.equal(state.length,2);assert.equal(state[1].name,'X (2)');
});
