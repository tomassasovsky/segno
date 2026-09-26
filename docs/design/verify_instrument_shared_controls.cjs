// Shared controller integration contracts. This does not claim physical MIDI/audio proof.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
let nextTimer=0,uid=0,checks=0;
const timers=new Map();
const noop=()=>{};
const context={window:{},console,performance:{now:()=>1000},crypto:{randomUUID:()=>String(++uid)},setTimeout:callback=>{timers.set(++nextTimer,callback);return nextTimer;},clearTimeout:id=>timers.delete(id)};
vm.createContext(context);
for(const file of ['pedal-action-catalogue.js','mapping-action-dispatch.js','pedal-ux-study.js','pedal-performance-study.js','external-switch-study.js','expression-ux-study.js','midi-protocol-study.js','midi-controls-study.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,file),'utf8'),context,{filename:file});
const w=context.window,plain=value=>JSON.parse(JSON.stringify(value));
const test=(name,run)=>{run();checks++;console.log('PASS '+name);};
const notes='instrument:keys-1:notes:held',latch='instrument:keys-1:notes:latch',sustain='instrument:keys-1:sustain:held';
const instrument=()=>w.setSegnoInstrumentActions([{id:'keys-1',name:'Studio Keys'}]);
context.createPedalColorEditor=()=>({active:()=>false,snapshot:()=>({}),overlay:()=>'',discard:noop,finish:()=>false});
context.SegnoPedalWidget={indicator:()=>'',face:()=>''};
const retired=[];const releaseControl=source=>retired.push(source);
let pedalSettings;
const pedal=w.createPedalStudy({read:()=>pedalSettings,write:value=>{pedalSettings=plain(value);},render:noop,setFocus:noop,indicatorState:()=>false,releaseControl});
pedalSettings=plain(pedal.state());
let externalSettings={nextId:1,ports:[{type:'single',switches:[{hardware:'momentary',press:'none',hold:'none',change:'none',mappings:[]}],mappings:[]}]};
let externalLatched=[[false,false],[false,false]];
const dispatchEvents=[];
const dispatch=w.createMappingActionDispatch({instrument:(action,token)=>{dispatchEvents.push(['down',action.instrument,action.kind,action.behavior,token]);return()=>dispatchEvents.push(['up',token]);},feedback:value=>dispatchEvents.push(['feedback',value])});
const external=w.createExternalSwitchStudy({config:()=>externalSettings.ports[0],saved:()=>externalSettings,currentPort:()=>0,connected:()=>[true,false],render:noop,setFocus:noop,dispatch:dispatch.dispatch,readLatched:()=>externalLatched,writeLatched:value=>{externalLatched=plain(value);},bindings:()=>[],destinations:()=>[],parameterTargets:()=>[],controlsChanged:noop,releaseControl,escape:String,icon:()=>''});

test('Dynamic catalogue preserves stable IDs, refreshes labels and removes stale targets',()=>{
 const direct=w.SegnoDirectActions,assignable=w.SegnoAssignableActions;
 instrument();assert.equal(direct.filter(a=>a.operation==='instrument').length,4);assert.equal(assignable.filter(a=>a.operation==='instrument').length,4);
 w.setSegnoInstrumentActions([{id:'keys-1',name:'Renamed Keys'},{id:'pads-2',name:'Drum Pads'}]);
 assert.equal(w.SegnoDirectActions,direct);assert.equal(w.SegnoAssignableActions,assignable);assert.match(direct.find(a=>a.key===notes).label,/Renamed Keys/);
 assert.equal(new Set(assignable.map(a=>a.key)).size,assignable.length);
 w.setSegnoInstrumentActions([{id:'keys-1',name:'Studio Keys'}]);assert.equal(assignable.some(a=>a.instrument==='pads-2'),false);
});

test('Existing editors discover new instrument actions and persist keys through rename',()=>{
 pedal.action('setup:context:custom');pedal.action('setup:edit:4:hold');pedal.action('setup:choose:None');pedal.action('setup:edit:4:press');pedal.action('setup:action-group:instruments');assert.match(pedal.overlay(),/Studio Keys/);
 pedal.action('setup:choose:'+notes);pedal.action('setup:save');assert.equal(pedalSettings.custom[4].press,notes);
 external.action('expr:switch:edit:press');external.action('expr:switch:action-group:instruments');assert.match(external.body(),/Studio Keys/);
 external.action('expr:switch:choose:'+sustain);assert.equal(externalSettings.ports[0].switches[0].press,sustain);
 w.setSegnoInstrumentActions([{id:'keys-1',name:'Renamed Keys'}]);assert.match(pedal.body(),/Renamed Keys/);assert.match(external.body(),/Renamed Keys/);
 w.setSegnoInstrumentActions([]);assert.match(pedal.body(),/Unavailable instrument/);assert.match(external.body(),/Unavailable action/);
 external.action('expr:switch:edit:press');external.action('expr:switch:action-group:instruments');assert.doesNotThrow(()=>external.body());instrument();
});

test('Dispatcher forwards stable target and source token, including release and stale guard',()=>{
 dispatchEvents.length=0;const release=dispatch.dispatch(notes,'external:0:0');assert.deepEqual(dispatchEvents,[['down','keys-1','notes','held','external:0:0']]);release();assert.deepEqual(dispatchEvents.at(-1),['up','external:0:0']);
 w.setSegnoInstrumentActions([]);assert.equal(dispatch.dispatch(notes,'external:0:0'),undefined);assert.deepEqual(dispatchEvents.at(-1),['feedback','Unavailable action']);instrument();
});

const studyStub=()=>({controls:{cancel:noop},snapshot:()=>({})});
for(const name of ['Transpose','Tuner','Backing','Bounce','Peel','Length','Speed','Fade','Mixer','Reverse'])w['create'+name+'PerformanceStudy']=studyStub;
const performanceUI=w.createPedalPerformanceStudy({getSettings:()=>pedalSettings,onChange:noop,backingState:{changed:noop},bankState:{get:()=>0},fx:{},initialView:'custom',assignedAction:dispatch.dispatch});

test('Built-in held Press begins on down, Hold stays exclusive, cancellation releases',()=>{
 pedalSettings.custom[4]={press:notes,hold:'None'};dispatchEvents.length=0;
 performanceUI.press(4,'foot');assert.deepEqual(dispatchEvents,[['down','keys-1','notes','held','custom:0:4']]);performanceUI.release('foot');assert.deepEqual(dispatchEvents.at(-1),['up','custom:0:4']);
 pedalSettings.custom[4]={press:latch,hold:sustain};dispatchEvents.length=0;performanceUI.press(4,'hold');assert.equal(dispatchEvents.length,0);
 for(const [id,callback]of [...timers]){timers.delete(id);callback();}
 assert.deepEqual(dispatchEvents,[['down','keys-1','sustain','held','custom:0:4']]);performanceUI.release('hold');assert.equal(dispatchEvents.length,2);
 pedalSettings.custom[4]={press:notes,hold:'None'};performanceUI.press(4,'cancel');performanceUI.cancel();assert.deepEqual(dispatchEvents.at(-1),['up','custom:0:4']);
 pedalSettings.custom[4]={press:latch,hold:'None'};dispatchEvents.length=0;performanceUI.press(4,91);performanceUI.release(91);performanceUI.press(4,'Enter');performanceUI.release('Enter');assert.equal(dispatchEvents[0][4],dispatchEvents[2][4],'one physical assignment has one latch identity across input methods');
 w.setSegnoInstrumentActions([]);dispatchEvents.length=0;performanceUI.press(4,'stale');assert.equal(dispatchEvents.length,0);instrument();
});

test('External held actions release the same source on up and disconnect cancellation',()=>{
 externalSettings.ports[0].switches[0].press=sustain;dispatchEvents.length=0;
 external.input(0,0,true);assert.deepEqual(dispatchEvents,[['down','keys-1','sustain','held','external:0:0']]);external.input(0,0,false);assert.deepEqual(dispatchEvents.at(-1),['up','external:0:0']);
 external.input(0,0,true);external.cancel(0);assert.deepEqual(dispatchEvents.at(-1),['up','external:0:0']);external.input(0,0,false);
 const physical=externalSettings.ports[0].switches[0];physical.hardware='latching';physical.change=sustain;dispatchEvents.length=0;external.input(0,0,true);assert.equal(dispatchEvents.length,1,'latching switch contact holds the instrument gate');external.input(0,0,false);assert.deepEqual(dispatchEvents.at(-1),['up','external:0:0']);physical.hardware='momentary';
});

let mappings=[],settings={enabled:true};
const received=[],connections=[],suspended=[];
const midi=w.createMidiControlsStudy({read:()=>mappings,write:value=>{mappings=plain(value);},readSettings:()=>settings,writeSettings:value=>{settings=value;},targets:()=>[],destinations:()=>[],dispatch:dispatch.dispatch,changed:noop,render:noop,focus:noop,icon:()=>'',escape:String,onMidi:(device,message)=>received.push([device,plain(message)]),onConnection:(id,online)=>connections.push([id,online]),onSuspend:id=>suspended.push(id),releaseControl});
const note={kind:'note',channel:3,number:103,value:117};

test('Shared MIDI delivers original notes, CC, bend and pressure with independent Remote enable',()=>{
 for(const message of [note,{kind:'cc',channel:3,number:64,value:127},{kind:'pitchbend',channel:3,value:12000},{kind:'pressure',channel:3,value:92}]){midi.receive('usb',message);assert.deepEqual(received.at(-1),['usb',message]);}
 midi.action('midi:global-enabled');assert.equal(settings.enabled,false);midi.receive('usb',note);assert.deepEqual(received.at(-1),['usb',note]);midi.action('midi:global-enabled');
 const inventory=midi.inventory();inventory[0].online=false;assert.equal(midi.inventory()[0].online,true);
});

test('MIDI Learn and editor consume one device, suspend its voices and preserve other ports',()=>{
 received.length=0;midi.action('midi:add');assert.deepEqual(suspended,['usb']);midi.receive('usb',note);assert.equal(received.length,0);assert.equal(midi.snapshot().draft.source.number,103);
 midi.receive('usb',{...note,value:0});assert.equal(received.length,0);midi.receive('din',note);assert.deepEqual(received,[['din',note]]);
 midi.action('midi:cancel');midi.receive('usb',note);assert.deepEqual(received.at(-1),['usb',note]);
 midi.connect('usb',false);assert.deepEqual(connections,[['usb',false]]);assert.equal(midi.inventory()[0].online,false);const count=received.length;midi.receive('usb',note);assert.equal(received.length,count);
 midi.connect('usb',true);midi.receive('usb',note);assert.equal(received.length,count+1);assert.deepEqual(connections.at(-1),['usb',true]);
});

test('MIDI button instrument assignment dispatches through shared mapping and releases',()=>{
 mappings=[{id:'sustain',device:'usb',source:{kind:'cc',number:64,channel:3},behavior:'momentary',enabled:true,controls:[{kind:'action',key:sustain,trigger:'press'}]}];
 dispatchEvents.length=0;midi.receive('usb',{kind:'cc',channel:3,number:64,value:127});assert.deepEqual(dispatchEvents,[['down','keys-1','sustain','held','midi:usb:sustain:'+sustain]]);
 midi.receive('usb',{kind:'cc',channel:3,number:64,value:0});assert.deepEqual(dispatchEvents.at(-1),['up','midi:usb:sustain:'+sustain]);
});

test('Expression and external control pickers include dynamic instrument destinations',()=>{
 let value=.5,expressionSettings,latched=[[false,false],[false,false]];
 const expression=w.createExpressionStudy({read:()=>expressionSettings,write:next=>{expressionSettings=plain(next);},targets:()=>[{key:'instrument-tone',destination:'keys-1',detail:'Studio Keys',label:'Tone',get:()=>value,set:next=>{value=next;},format:String}],destinations:()=>[{id:'keys-1',label:'Studio Keys',kind:'instruments'}],render:noop,setFocus:noop,dispatchSwitch:dispatch.dispatch,readLatched:()=>latched,writeLatched:next=>{latched=plain(next);},switchBindings:()=>[],controlsChanged:noop,icon:()=>'',escape:String});
 expressionSettings=plain(expression.state());expression.action('expr:add');expression.action('expr:kind:instruments');assert.match(expression.body(),/Studio Keys/);expression.action('expr:destination:keys-1');assert.match(expression.body(),/Tone/);expression.action('expr:target:instrument-tone');expression.action('expr:save');
 expressionSettings.ports[0].calibration={heel:0,toe:1};expression.receive(0,.8);assert.equal(value,.8);
 expression.action('expr:type:single');expression.action('expr:switch:panel:controls');expression.action('expr:switch:add-control');expression.action('expr:switch:control-kind:instruments');assert.match(expression.body(),/Studio Keys/);expression.action('expr:switch:control-destination:keys-1');assert.match(expression.body(),/Tone/);
});
test('Mapping lifecycle retires latch sources; ordinary release preserves the latch',()=>{
 retired.length=0;midi.receive('usb',{kind:'cc',channel:3,number:64,value:127});midi.receive('usb',{kind:'cc',channel:3,number:64,value:0});assert.deepEqual(retired,[]);
 midi.action('midi:enabled:sustain');assert.deepEqual(retired,['midi:usb:sustain:']);midi.action('midi:enabled:sustain');retired.length=0;
 midi.action('midi:edit:sustain');assert.deepEqual(retired,['midi:usb:sustain:']);midi.action('midi:cancel');retired.length=0;midi.action('midi:global-enabled');assert.deepEqual(retired,['midi:usb:sustain:']);midi.action('midi:global-enabled');
 midi.action('midi:edit:sustain');retired.length=0;midi.action('midi:delete');assert.deepEqual(retired,['midi:usb:sustain:']);
 retired.length=0;external.input(0,0,true);external.input(0,0,false);assert.deepEqual(retired,[]);external.cancel(0);assert.deepEqual(retired,['external:0:0']);retired.length=0;external.action('expr:switch:edit:press');assert.deepEqual(retired,['external:0:0']);
 retired.length=0;pedal.action('setup:edit:4:press');assert.deepEqual(retired,['custom:0:4']);pedal.action('setup:choose:'+sustain);pedal.action('setup:save');assert.deepEqual(retired,['custom:0:4','custom:0:4']);
});
test('Built-in editor disables incompatible held Press / Hold pairs and repairs saved invalid pairs',()=>{
 let saved=plain(pedalSettings),writes=0; saved.custom[4]={press:'Transpose',hold:'Reverse'};
 const editor=w.createPedalStudy({read:()=>saved,write:next=>{saved=plain(next);writes++;},render:noop,setFocus:noop,indicatorState:()=>false});
 const disabled=(html,id)=>new RegExp('<button[^>]*data-action="'+id+'"[^>]*disabled').test(html);
 editor.action('setup:context:custom');editor.action('setup:edit:4:press');editor.action('setup:action-group:instruments');assert.equal(disabled(editor.overlay(),'setup:choose:'+notes),true);assert.match(editor.overlay(),/Set Hold to None/);
 editor.action('setup:choose:'+notes);assert.equal(editor.snapshot().draft.custom[4].press,'Transpose');editor.action('setup:close');editor.action('setup:edit:4:hold');editor.action('setup:choose:None');editor.action('setup:edit:4:press');editor.action('setup:action-group:instruments');assert.equal(disabled(editor.overlay(),'setup:choose:'+notes),false);editor.action('setup:choose:'+notes);editor.action('setup:save');assert.equal(saved.custom[4].press,notes);assert.equal(saved.custom[4].hold,'None');
 editor.action('setup:edit:4:hold');assert.match(editor.overlay(),/Press uses Held/);assert.equal(disabled(editor.overlay(),'setup:choose:Stop'),true);editor.action('setup:choose:Stop');assert.equal(editor.snapshot().draft.custom[4].hold,'None');editor.action('setup:close');
 saved.custom[4]={press:notes,hold:'Stop'};editor.discard();assert.equal(disabled(editor.body(),'setup:save'),true);assert.match(editor.body(),/held Press needs Hold set to None/);const before=writes;editor.action('setup:save');assert.equal(writes,before);editor.action('setup:context:custom');editor.action('setup:edit:4:hold');editor.action('setup:choose:None');assert.equal(disabled(editor.body(),'setup:save'),false);editor.action('setup:save');assert.equal(saved.custom[4].hold,'None');
 editor.action('setup:edit:4:press');editor.action('setup:choose:Stop');editor.action('setup:edit:4:hold');editor.action('setup:action-group:instruments');assert.equal(disabled(editor.overlay(),'setup:choose:'+sustain),false);editor.action('setup:choose:'+sustain);editor.action('setup:save');assert.equal(saved.custom[4].hold,sustain);
});

test('External editor refuses invalid pairs at choices and Save, then allows Hold None or held Hold',()=>{
 let saved,writes=0,latched=[[false,false],[false,false]];
 const editor=w.createExpressionStudy({read:()=>saved,write:next=>{saved=plain(next);writes++;},targets:()=>[],destinations:()=>[],render:noop,setFocus:noop,dispatchSwitch:noop,readLatched:()=>latched,writeLatched:next=>{latched=plain(next);},switchBindings:()=>[],controlsChanged:noop,icon:()=>'',escape:String});
 saved=plain(editor.state());saved.ports[0].type='single';saved.ports[0].switches[0]={hardware:'momentary',press:'command:stop',hold:'command:undo',change:'none',mappings:[]};
 const disabled=(html,id)=>new RegExp('<button[^>]*data-action="'+id+'"[^>]*disabled').test(html);
 editor.openSwitchActions();editor.action('expr:switch:edit:press');editor.action('expr:switch:action-group:instruments');assert.equal(disabled(editor.body(),'expr:switch:choose:'+notes),true);assert.match(editor.body(),/Set Hold to None/);editor.action('expr:switch:choose:'+notes);assert.equal(editor.snapshot().draft.ports[0].switches[0].press,'command:stop');editor.action('expr:switch:close');editor.action('expr:switch:edit:hold');editor.action('expr:switch:choose:none');editor.action('expr:switch:edit:press');editor.action('expr:switch:action-group:instruments');assert.equal(disabled(editor.body(),'expr:switch:choose:'+notes),false);editor.action('expr:switch:choose:'+notes);editor.action('expr:save');assert.equal(saved.ports[0].switches[0].press,notes);
 editor.action('expr:switch:edit:hold');assert.match(editor.body(),/Press uses Held/);assert.equal(disabled(editor.body(),'expr:switch:choose:command:stop'),true);editor.action('expr:switch:choose:command:stop');assert.equal(editor.snapshot().draft.ports[0].switches[0].hold,'none');editor.action('expr:switch:close');
 saved.ports[0].switches[0].hold='command:stop';editor.discard();assert.equal(disabled(editor.body(),'expr:save'),true);assert.match(editor.body(),/held Press needs Hold set to None/);const before=writes;editor.action('expr:save');assert.equal(writes,before);editor.action('expr:switch:edit:hold');editor.action('expr:switch:choose:none');assert.equal(disabled(editor.body(),'expr:save'),false);editor.action('expr:save');assert.equal(saved.ports[0].switches[0].hold,'none');
 editor.action('expr:switch:edit:press');editor.action('expr:switch:choose:command:stop');editor.action('expr:switch:edit:hold');editor.action('expr:switch:action-group:instruments');assert.equal(disabled(editor.body(),'expr:switch:choose:'+sustain),false);editor.action('expr:switch:choose:'+sustain);editor.action('expr:save');assert.equal(saved.ports[0].switches[0].hold,sustain);
});
console.log(checks+' instrument shared control contracts passed');
