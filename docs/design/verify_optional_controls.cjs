const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const midi=require('./midi-protocol-study.js'),copy=v=>structuredClone(v),plain=v=>JSON.parse(JSON.stringify(v));
const wire=(number,value,channel=1,kind='cc')=>({kind,number,value,channel});
test('14-bit CC emits only complete fresh pairs and isolates device, channel and controller',()=>{
 let now=0;const d=midi.decoder({now:()=>now});assert.equal(d.feed('a',wire(21,64),'cc14'),null);assert.equal(d.feed('b',wire(53,1),'cc14'),null);assert.equal(d.feed('a',wire(53,1,2),'cc14'),null);
 const e=d.feed('a',wire(53,1),'cc14');assert.equal(e.value,8193);assert.equal(e.maximum,16383);assert.deepEqual(e.source,{kind:'cc',number:21,channel:1,protocol:'cc14'});
 assert.equal(d.feed('a',wire(53,5),'cc14'),null);now=101;assert.equal(d.feed('a',wire(21,1),'cc14'),null);assert.equal(d.feed('a',wire(53,2),'cc14').value,130);
 d.feed('a',wire(21,3),'cc14');d.reset('a');assert.equal(d.feed('a',wire(53,2),'cc14'),null);
});
test('NRPN requires complete parameter and value, resets on RPN/null selection and never learns partial data',()=>{
 const d=midi.decoder({now:()=>0}),f=(n,v,ch=1)=>d.feed('a',wire(n,v,ch),'nrpn');assert.equal(f(6,12),null);f(99,2);assert.equal(f(6,15),null);f(98,3);f(6,64);assert.equal(f(38,7,2),null);const e=f(38,7);assert.equal(e.source.parameter,259);assert.equal(e.value,8199);
 f(99,3);assert.equal(f(38,2),null);f(98,4);f(6,2);assert.equal(f(38,1).source.parameter,388);
 f(100,0);f(6,127);assert.equal(f(38,127),null);f(99,127);f(98,127);f(6,127);assert.equal(f(38,127),null);
});
test('Bank select waits for both bank bytes then binds Program identity, not bank CC as a trigger',()=>{
 const d=midi.decoder({now:()=>0}),f=(n,v,kind='cc',ch=1)=>d.feed('a',wire(n,v,ch,kind),'bank-program');assert.equal(f(8,127,'program'),null);f(0,2);assert.equal(f(8,127,'program'),null);f(32,4);const e=f(8,0,'program');assert.deepEqual(e.source,{kind:'program',number:8,channel:1,protocol:'bank-program',bank:260});assert.equal(e.value,127);assert.equal(f(8,127,'program',2),null);f(0,3);assert.equal(f(8,127,'program'),null);
});
test('relative decoding is explicit two’s complement, while ordinary CC retains its absolute value',()=>{
 const d=midi.decoder();for(const [value,delta]of [[0,0],[1,1],[63,63],[64,-64],[127,-1]])assert.equal(d.feed('a',wire(21,value),'relative').delta,delta);
 assert.equal(d.feed('a',wire(21,127)).delta,undefined);assert.equal(d.feed('a',wire(21,127)).value,127);for(const message of [wire(21,128),wire(21,.5),wire(21,0,0),wire(21,0,1,'sysex')])assert.equal(d.feed('a',message),null);
});
test('source matching and collisions preserve distinct NRPN/bank identities and reject raw protocol overlap',()=>{
 const nrpn={kind:'cc',number:6,channel:1,protocol:'nrpn',parameter:300},other={...nrpn,parameter:301};assert(!midi.same(nrpn,other));assert(!midi.overlaps(nrpn,other));assert(midi.overlaps(nrpn,{kind:'cc',number:38,channel:'omni'}));
 const cc={kind:'cc',number:21,channel:1,protocol:'cc14'};assert(midi.overlaps(cc,{kind:'cc',number:53,channel:1}));assert(!midi.overlaps(cc,{kind:'cc',number:53,channel:2}));assert(midi.overlaps({...cc,protocol:'relative'},{kind:'cc',number:21,channel:1}));assert(!midi.validSource({...nrpn,parameter:16383}));assert(!midi.validSource({...cc,number:32}));
});
function world(files){let now=0,serial=0;const timers=new Map(),w={window:{},structuredClone,Map,Set,performance:{now:()=>now},crypto:{randomUUID:()=>String(++serial)},setTimeout:(fn,ms)=>{const id=++serial;timers.set(id,{fn,at:now+ms});return id;},clearTimeout:id=>timers.delete(id)};vm.createContext(w);for(const file of files)vm.runInContext(fs.readFileSync(path.join(__dirname,file),'utf8'),w,{filename:file});return {w,advance:ms=>{const end=now+ms;while(true){const next=[...timers].sort((a,b)=>a[1].at-b[1].at)[0];if(!next||next[1].at>end)break;now=next[1].at;timers.delete(next[0]);next[1].fn();}now=end;}};}
function controls(dispatch=()=>{throw Error('No action should fire');}){const h=world(['midi-protocol-study.js','pedal-action-catalogue.js','midi-controls-study.js']);let saved=[],value=.5,fail=false;const api=h.w.window.createMidiControlsStudy({read:()=>saved,write:v=>{if(fail)return false;saved=plain(v);return true;},readSettings:()=>({enabled:true}),writeSettings:()=>true,targets:()=>[{key:'volume',label:'Volume',detail:'Track 1',destination:'Track 1',step:.01,format:String,get:()=>value,set:v=>value=v,coerce:v=>Math.max(0,Math.min(1,v)),persist:()=>{}}],destinations:()=>[{id:'Track 1',label:'Track 1'}],dispatch,changed:()=>{},render:()=>{},focus:()=>{},icon:()=>'',escape:String});return {...h,api,saved:()=>saved,seed:v=>saved=copy(v),value:()=>value,fail:v=>fail=v};}
function learn(h,mode='cc14'){h.api.action('midi:add');h.api.action('midi:protocol:'+mode);}
function target(h){h.api.action('midi:choose');h.api.action('midi:destination:Track%201');h.api.action('midi:target:volume');}
test('Learn shows the exact 14-bit value, cancels without publishing, retains failed save and controls through pickup after retry',()=>{
 const h=controls();learn(h);h.api.receive('usb',wire(21,64));assert(h.api.snapshot().learn);h.api.receive('usb',wire(53,0));assert.equal(h.api.snapshot().learnValue.value,8192);assert.match(h.api.body(),/8192 \/ 16383/);target(h);h.api.action('midi:cancel');assert.deepEqual(h.saved(),[]);
 learn(h);h.api.receive('usb',wire(21,64));h.api.receive('usb',wire(53,0));target(h);h.fail(true);h.api.action('midi:save');assert.deepEqual(h.saved(),[]);assert.equal(h.api.snapshot().view,'edit');h.fail(false);h.api.action('midi:save');assert.equal(h.saved()[0].source.protocol,'cc14');h.api.receive('usb',wire(21,64));h.api.receive('usb',wire(53,0));h.api.receive('usb',wire(21,127));h.api.receive('usb',wire(53,127));assert.equal(h.value(),1);
});
test('relative controls apply signed steps inside their saved range and disconnect clears unfinished high-resolution assembly',()=>{
 const h=controls();h.seed([{id:'relative',device:'usb',source:{kind:'cc',number:21,channel:1,protocol:'relative'},enabled:true,behavior:'continuous',controls:[{kind:'parameter',key:'volume',low:.8,high:.2}]}]);h.api.receive('usb',wire(21,1));assert.equal(h.value(),.49);h.api.receive('usb',wire(21,127));assert.equal(h.value(),.5);h.api.receive('usb',wire(21,63));assert.equal(h.value(),.2);
 learn(h);h.api.receive('usb',wire(22,64));h.api.connect('usb',false);h.api.connect('usb',true);h.api.receive('usb',wire(54,0));assert(h.api.snapshot().learn);
});
test('protocol overlap and changes after Learn are refused without overwriting a saved mapping',()=>{
 const h=controls();learn(h);h.api.receive('usb',wire(21,64));h.api.receive('usb',wire(53,0));target(h);const other={id:'other',device:'usb',source:{kind:'cc',channel:1,number:53},controls:[],enabled:true,behavior:'continuous'};h.seed([other]);h.api.action('midi:save');assert.equal(h.api.snapshot().conflict,'other');assert.deepEqual(h.saved(),[other]);
});
test('expanded identities survive controller replacement and missing-target repair with endpoints unchanged',()=>{
 const connection=require('./session-connection-repair.js'),repair=require('./session-target-repair.js'),source={kind:'cc',channel:1,number:6,protocol:'nrpn',parameter:500},snapshot={midiMappings:[{id:'x',device:'old',source,behavior:'continuous',controls:[{kind:'parameter',key:'missing',low:.8,high:.2}]}]},before=copy(snapshot),available={midiPorts:[{id:'new',online:true}]};
 const moved=connection.repair(snapshot,{},available,{kind:'midi',id:'old'},'new');assert.equal(moved.snapshot.midiMappings[0].device,'new');assert.deepEqual(moved.snapshot.midiMappings[0].source,source);const fixed=repair.repair(moved.snapshot,[{key:'new-target',label:'Volume',detail:'Track 1',destination:'Track 1',coerce:v=>v,format:v=>v*100+'%'}],'missing','new-target');assert(!fixed.error);assert.deepEqual(fixed.snapshot.midiMappings[0].source,source);assert.equal(fixed.snapshot.midiMappings[0].controls[0].low,.8);assert.deepEqual(snapshot,before);
});
function pedals(capturing=false){const h=world(['pedal-performance-study.js']);let bank=0;const events=[],solo=Array(8).fill(false),settings={mode:{press:'Mute',hold:'Custom'},recordHold:'Undo recording',trackHold:'Arm overdub',trackDoubleSolo:false};const w=h.w.window,stub=()=>({controls:{cancel(){}},snapshot:()=>({}),enter(){},role:()=>({enabled:true})});for(const name of ['Transpose','Tuner','Backing','Bounce','Peel','Length','Speed','Fade','Mixer','Reverse'])w['create'+name+'PerformanceStudy']=stub;w.SegnoAssignableActions=[];w.SegnoDirectActions=[];w.SegnoPerformanceActions=[];w.createSpeedPerformanceStudy=()=>({...stub(),set:value=>{events.push(['Speed',value]);return true;}});w.createReversePerformanceStudy=()=>({...stub(),toggle:i=>events.push(['Reverse',i])});
 const api=w.createPedalPerformanceStudy({getSettings:()=>settings,onChange:()=>{},backingState:{changed:()=>{}},trackNames:Array.from({length:8},(_,i)=>'Track '+(i+1)),currentTrack:()=>0,bankState:{get:()=>bank,set:v=>bank=v},soloState:{get:i=>solo[i],any:()=>solo.some(Boolean),toggle:i=>{solo[i]=!solo[i];events.push(['Solo',i]);}},reverseState:{hasAudio:()=>true,get:()=>false},trackTransport:{command:(...args)=>events.push(args),snapshot:()=>({tracks:Array.from({length:8},()=>({playing:false,capturing})),pending:[]})},fx:{get:()=>({})},muteState:{get:()=>false},icon:()=>''});return {...h,api,events,settings,bank:v=>bank=v};}
test('optional double press selects immediately once and toggles Solo only on the second short release',()=>{
 const h=pedals();h.settings.trackDoubleSolo=true;h.api.press(4,'a');assert.deepEqual(h.events,[['Select',0]]);h.advance(30);h.api.release('a');h.advance(100);h.api.press(4,'b');assert.deepEqual(h.events,[['Select',0]]);h.advance(30);h.api.release('b');assert.deepEqual(h.events,[['Select',0],['Solo',0]]);
});
test('default off retains immediate actions; hold, cancellation, bank and intervening controls retire double candidates',()=>{
 const h=pedals();h.api.press(4,'a');h.api.release('a');h.api.press(4,'b');h.api.release('b');assert.deepEqual(h.events,[['Select',0],['Select',0]]);
 for(const scenario of ['hold','cancel','bank','other']){const h=pedals();h.settings.trackDoubleSolo=true;h.api.press(4,'a');h.api.release('a');if(scenario==='bank')h.bank(1);if(scenario==='other'){h.api.press(1,'stop');h.api.release('stop');}h.api.press(4,'b');if(scenario==='hold')h.advance(800);h.api.release('b',scenario==='cancel');assert(!h.events.some(e=>e[0]==='Solo'),scenario);if(scenario==='hold')assert.equal(h.events.filter(e=>e[0]==='Arm overdub').length,1);}
 const fast=pedals();fast.settings.trackDoubleSolo=true;fast.api.press(0,'rec');assert.deepEqual(fast.events,[['Record / Play',0]]);
});
test('double Solo option follows existing draft Save, failure retry and Cancel semantics',()=>{
 const h=world(['pedal-action-catalogue.js','pedal-color-editor.js','pedal-ux-study.js']);h.w.createPedalColorEditor=h.w.window.createPedalColorEditor;h.w.SegnoPedalWidget={indicator:()=>'',face:()=>''};let saved=null,fail=false;const p=h.w.window.createPedalStudy({read:()=>saved,write:v=>{if(fail)return false;saved=plain(v);return true;},render:()=>{},setFocus:()=>{},indicatorState:()=>false});p.action('setup:double-solo');assert.equal(p.snapshot().saved.trackDoubleSolo,false);p.action('setup:cancel');assert.equal(p.snapshot().draft.trackDoubleSolo,false);p.action('setup:double-solo');fail=true;p.action('setup:save');assert.equal(saved,null);assert.equal(p.snapshot().draft.trackDoubleSolo,true);fail=false;p.action('setup:save');assert.equal(saved.trackDoubleSolo,true);
});
test('touch lock blocks screen events, preserves encoder action path and requires a deliberate stationary hold',()=>{
 const h=world(['touch-lock-study.js']);let canceled=0;const lock=h.w.window.createTouchLockStudy({button:(id,text)=>'<button data-action="'+id+'">'+text+'</button>',render:()=>{},focus:()=>{},cancelTouch:()=>canceled++});assert.equal(lock.locked(),false);lock.lock();assert.equal(canceled,1);
 const event=(type,unlock=false,x=0)=>({type,pointerId:1,isPrimary:true,clientX:x,clientY:0,target:{closest:()=>unlock?{}:null},preventDefault(){this.prevented=true;},stopImmediatePropagation(){this.stopped=true;}});
 for(const type of ['pointerdown','click','wheel','input']){const e=event(type);assert(lock.filter(e));assert(e.prevented&&e.stopped);}assert(lock.action('touch-lock:unlock'));assert.equal(lock.locked(),false);assert.equal(lock.filter(event('click')),false,'encoder unlock does not consume a later intended touch');
 lock.lock();lock.filter(event('pointerdown',true));h.advance(1499);assert(lock.locked());lock.filter(event('pointerup',true));h.advance(20);assert(lock.locked());lock.filter(event('pointerdown',true));lock.filter(event('pointermove',true,30));h.advance(1500);assert(lock.locked());lock.filter(event('pointerdown',true));h.advance(1500);assert.equal(lock.locked(),false);assert(lock.filter(event('click')),true,'unlock release cannot activate content underneath');lock.lock();lock.filter(event('pointerdown',true));h.advance(1500);lock.filter(event('pointerup',true));assert.equal(lock.filter(event('pointerdown')),false);assert.equal(lock.filter(event('click')),false,'a fresh touch is not swallowed when rerender removed the unlock release click');
});

test('Cut all sound uses its own guarded callback and is explicitly assignable to a MIDI button',()=>{
 const h=world(['pedal-action-catalogue.js','mapping-action-dispatch.js']),events=[],feedback=[];let ready=true;
 const dispatch=h.w.window.createMappingActionDispatch({available:()=>ready,cutSound:()=>{events.push('cut');return {reason:'Could not save'};},transport:v=>events.push(v),invoke:v=>events.push(v),feedback:v=>feedback.push(v)}).dispatch;
 dispatch('command:stop');dispatch('command:clear-all');assert.deepEqual(events,['Stop','Clear all']);dispatch('command:cut-sound');assert.deepEqual(events,['Stop','Clear all','cut']);assert.deepEqual(feedback,['Could not save']);ready=false;dispatch('command:cut-sound');assert.equal(events.length,3);
 const m=controls((key)=>events.push(key));m.api.action('midi:add');m.api.receive('usb',wire(60,127,1,'note'));m.api.action('midi:choose');m.api.action('midi:actions');m.api.action('midi:action-group:transport');assert.match(m.api.body(),/Cut all sound/);m.api.action('midi:target:command%3Acut-sound');m.api.action('midi:save');m.api.receive('usb',wire(60,127,1,'note'));m.api.receive('usb',wire(60,127,1,'note'));m.api.receive('usb',wire(60,0,1,'note'));assert.equal(events.filter(v=>v==='command:cut-sound').length,1);
});
test('locking touch retires only touch gestures while physical holds and double presses continue',()=>{
 const h=pedals();h.settings.trackDoubleSolo=true;h.api.press(4,1);h.api.press(5,'hardware');h.api.cancelTouch();h.advance(800);assert.deepEqual(h.events.filter(e=>e[0]==='Arm overdub'),[['Arm overdub',1]]);h.api.release('hardware');
 const p=pedals();p.settings.trackDoubleSolo=true;p.api.press(4,'one');p.api.release('one');p.api.cancelTouch();p.api.press(4,'two');p.api.release('two');assert.equal(p.events.filter(e=>e[0]==='Solo').length,1);
 const t=pedals();t.settings.trackDoubleSolo=true;t.api.press(4,1);t.api.release(1);t.api.cancelTouch();t.api.press(4,2);t.api.release(2);assert(!t.events.some(e=>e[0]==='Solo'));
});

test('playback-only Speed and Reverse reach the host during capture while destructive length edits stay blocked',()=>{
 const h=pedals(true);assert.equal(h.api.direct({operation:'speed',tracks:[0,1],value:2}).changed,true);assert.equal(h.api.direct({operation:'reverse',tracks:[1]}).changed,true);assert.deepEqual(h.events,[['Speed',2],['Reverse',1]]);assert.equal(h.api.direct({operation:'multiply',tracks:[1]}).reason,'Finish recording');assert.equal(h.events.length,2);
});

test('relative destination coercion happens after normalized range clamping',()=>{
 const h=world(['midi-protocol-study.js','pedal-action-catalogue.js','midi-controls-study.js']);let value=.5;
 const source={kind:'cc',number:22,channel:1,protocol:'relative'},mappings=[{id:'typed',device:'usb',source,enabled:true,behavior:'continuous',controls:[{kind:'parameter',key:'choice',low:.1,high:.9}]}];
 const api=h.w.window.createMidiControlsStudy({read:()=>mappings,readSettings:()=>({enabled:true}),targets:()=>[{key:'choice',get:()=>value,set:v=>value=v,step:.5,coerce:v=>Math.round(v*2)/2}],changed:()=>{},render:()=>{}});
 api.receive('usb',wire(22,63));assert.equal(value,1,'destination receives a valid discrete value, not an uncoerced endpoint');api.receive('usb',wire(22,127));assert.equal(value,.5);
});
