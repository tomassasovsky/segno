// Real normal-host actions and localStorage; audio remains a symbolic prototype.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
const storageKey='segno-fx-factory-design-2026-09-06-channels';
const output=process.env.TIMING_COMPLETION_OUTPUT||path.join(__dirname,'timing-completion-previews');
const near=(a,b)=>assert(Math.abs(a-b)<1e-5,`${a} differs from ${b}`);
const layer=(s,i=0)=>s.rig.trackLayers['Track '+(i+1)].layers;
const duration=(s,i=0)=>s.rig.trackLength['Track '+(i+1)].durationBeats;
async function run(kind){
  const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}:{})});
  try{
    const context=await browser.newContext({viewport:{width:1968,height:1124}}),page=await context.newPage(),errors=[];
    page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(6000);
    await page.clock.install({time:new Date('2026-09-09T12:00:00Z')});await page.clock.pauseAt(new Date('2026-09-09T12:00:01Z'));
    const state=()=>page.evaluate(()=>segnoDemo.snapshot()),transport=()=>page.evaluate(()=>segnoDemo.transportState());
    const cmd=key=>page.evaluate(key=>segnoDemo.dispatchMapping(key),key);
    const click=id=>page.locator('[data-action='+JSON.stringify(id)+']').click();
    const down=(id,token)=>page.evaluate(({id,token})=>segnoDemo.performanceDown(id,token),{id,token});
    const up=token=>page.evaluate(token=>segnoDemo.performanceUp(token),token);
    const foot=async id=>{const token='foot-'+id;await down(id,token);await up(token);};
    const saved=()=>page.evaluate(key=>localStorage.getItem(key),storageKey);
    const advance=async ms=>{await page.clock.runFor(ms);await cmd('select-track:'+(await page.evaluate(()=>segnoDemo.displayState().selected)));};
    const open=async()=>{await page.goto(base+'?canvas=actual');await page.waitForFunction(()=>window.segnoDemo);assert(!new URL(page.url()).searchParams.has('review'));};
    await open();const initial=await state();
    async function seed(settings={}){
      await page.evaluate(({initial,storageKey,settings})=>{
        const rig=structuredClone(initial.rig);for(const key of ['recordedParts','trackLayers','trackLength','trackPlayback','trackReverse','trackPitch','trackFade','bounceRecipes'])rig[key]={};
        rig.recordedAudioFiles=[];rig.loopSpeed=1;rig.expressionMix={};
        for(let i=0;i<8;i++){const t='Track '+(i+1);rig.recordedParts[t]=[];rig.trackLayers[t]={layers:[]};rig.trackLength[t]={audio:[],durationBeats:0,note:''};rig.trackPlayback[t]=false;rig.expressionMix[t]={level:1,pan:.5};}
        rig.recordingInputs=structuredClone(initial.recordingInputs);rig.trackLabels=structuredClone(initial.trackLabels);rig.liveMonitoring=structuredClone(initial.liveMonitoring);rig.mutedTracks=Array(8).fill(false);rig.soloTracks=Array(8).fill(false);
        rig.editHistory={serial:0,tracks:Array.from({length:8},()=>({undo:[],redo:[]}))};
        rig.loopSettings={mode:'sync',tempo:120,signature:'4/4',start:'press',recDub:false,click:'always',countIn:0,lengthTiming:{bars:0,quantize:'immediate'},trackLengthTiming:{},playback:{once:false,decay:0},...settings};
        rig.syncSettings={source:'internal'};rig.audioLibrary={...structuredClone(initial.audioLibrary.state),prepared:[],backing:null,trackImports:{}};delete rig.sessionLibrary;delete rig.performanceRecording;
        localStorage.setItem(storageKey,JSON.stringify(rig));
      },{initial,storageKey,settings});await open();
    }
    async function record(i,beats){await cmd('select-track:'+i);await cmd('command:record-play');await advance(beats*500);await cmd('command:record-play');near(duration(await state(),i),beats);}
    async function failStorage(fail){await page.evaluate(({storageKey,fail})=>{if(fail){window.timingWriter=Storage.prototype.setItem;Storage.prototype.setItem=function(k,v){if(k===storageKey)throw new DOMException('Full storage','QuotaExceededError');return window.timingWriter.call(this,k,v);};}else{Storage.prototype.setItem=window.timingWriter;delete window.timingWriter;}},{storageKey,fail});}
    async function shot(name){if(process.env.SKIP_SCREENSHOTS)return;fs.mkdirSync(output,{recursive:true});await page.evaluate(()=>document.fonts.ready);const bounds=await page.locator('#screen').boundingBox();assert(Math.abs(bounds.width-1920)<.01);assert(Math.abs(bounds.height-1080)<.01);await page.locator('#screen').screenshot({path:path.join(output,kind+'-'+name+'.png')});}
    const content=s=>({parts:s.recordedParts,layers:s.rig.trackLayers,length:s.rig.trackLength,history:s.rig.editHistory,primary:s.loopSettings.primaryTrack,tempo:s.loopSettings.tempo});

    // The audible head can change while an Auto capture follows the musical cycle.
    await seed();await record(0,16);await advance(1000);await cmd('select-track:1');await cmd('command:record-play');await advance(2000);
    await cmd('direct:speed:2');await cmd('direct:reverse:0');assert.equal((await state()).rig.loopSpeed,2);assert.equal((await state()).rig.trackReverse['Track 1'],true);
    await cmd('command:record-play');assert.deepEqual((await transport()).pending,[{track:1,action:'Play',timing:'Primary cycle · 10 beats'}]);await shot('musical-cycle');
    await advance(5000);let s=await state();near(duration(s,1),16);near(layer(s,1)[0].seconds,7);assert.equal(layer(s,1)[0].regions.length,1);near(layer(s,1)[0].regions[0].offsetBeats,2);near(layer(s,1)[0].regions[0].beats,14);
    await cmd('view:wave');await shot('musical-cycle-complete');

    // Clearing a source uses the real chooser, survives failed persistence, then reloads.
    await cmd('select-track:0');const before=content(await state()),disk=await saved();await cmd('direct:clear:selected');
    assert.equal((await state()).page,'loop-primary');assert.equal((await state()).primary.clearing,'Track 1');assert.equal(await saved(),disk);await shot('clear-source');
    await click('primary:choose:Track%202');assert.match(await page.locator('.primary-track-dialog').innerText(),/Stop, clear and switch/);
    await failStorage(true);await click('primary:confirm');assert.deepEqual(content(await state()),before);assert.equal(await saved(),disk);assert((await state()).primary.pending);
    await failStorage(false);await click('primary:confirm');s=await state();assert.equal(s.loopSettings.primaryTrack,'Track 2');assert.equal(layer(s).length,0);assert(Object.values(s.trackPlayback).every(v=>!v));
    await open();s=await state();assert.equal(s.loopSettings.primaryTrack,'Track 2');assert.equal(layer(s).length,0);await cmd('select-track:0');await cmd('command:undo');assert.equal((await state()).loopSettings.primaryTrack,'Track 1');near(duration(await state()),16);

    // Bank changes and cancel/reopen invalidate captured foot actions before release.
    await seed();await record(0,8);await record(1,8);await record(4,8);await cmd('select-track:0');await cmd('direct:clear:selected');
    await down(5,'old-choice');await foot(9);await up('old-choice');assert.equal((await state()).primary.pending,null);
    await foot(4);assert.equal((await state()).primary.pending.id,'Track 5');await down(1,'old-confirm');await foot(3);assert.equal((await state()).page,'stage');assert.equal((await transport()).primaryClear,null);
    await cmd('direct:clear:selected');await foot(9);await foot(4);await up('old-confirm');assert.equal((await state()).loopSettings.primaryTrack,'Track 1');assert.equal((await state()).primary.pending.id,'Track 5');
    await foot(1);assert.equal((await state()).page,'stage');assert.equal((await state()).loopSettings.primaryTrack,'Track 5');assert.equal(layer(await state()).length,0);assert(Object.values((await state()).captureState).every(v=>v==='idle'));

    // Inference correction is optional, preserves original material seconds and has Undo.
    await seed({mode:'multi',click:'off'});await cmd('command:record-play');await advance(3500);await cmd('command:record-play');
    assert.equal((await transport()).firstTakeTiming.bars,2);await click('timing-review:open');assert.match(await page.locator('.first-timing-review').innerText(),/3.50 seconds/);await shot('first-take-review');
    const first=content(await state()),firstDisk=await saved();await failStorage(true);await click('timing-review:1');assert.deepEqual(content(await state()),first);assert.equal(await saved(),firstDisk);
    await failStorage(false);await click('timing-review:1');s=await state();near(duration(s),4);near(s.loopSettings.tempo,240/3.5);near(layer(s)[0].seconds,3.5);assert.deepEqual(layer(s)[0].recordedAudio,first.layers['Track 1'].layers[0].recordedAudio);
    const sourceFile=s.rig.recordedAudioFiles.find(f=>f.id===layer(s)[0].recordedAudio.id);assert(sourceFile);near(sourceFile.seconds,3.5);
    await open();s=await state();near(duration(s),4);near(layer(s)[0].seconds,3.5);await cmd('command:undo');near(duration(await state()),8);near((await state()).loopSettings.tempo,480/3.5);
    await click('timing-review:open');await foot(4);assert.equal((await state()).page,'stage');near(duration(await state()),4);

    // Immediate Cut cannot be defeated by quota failure; recovery stays visible until saved.
    await seed({mode:'multi'});await record(0,16);await cmd('command:record-play');await advance(1000);const priorLayerCount=layer(await state()).length;
    await failStorage(true);await cmd('command:cut-sound');assert(Object.values((await state()).trackPlayback).every(v=>!v));assert.equal(layer(await state()).length,priorLayerCount);assert.equal((await transport()).frozenRecoveries.length,1);
    const held=(await transport()).frozenRecoveries[0];await advance(5000);assert.deepEqual((await transport()).frozenRecoveries,[held]);assert.equal(await page.locator('[data-action="timing-recovery:save"]').isVisible(),true);await shot('held-take');
    await failStorage(false);const sessionId=(await state()).rig.sessionLibrary.current.id;await cmd('command:new-loop');assert.equal((await state()).rig.sessionLibrary.current.id,sessionId);assert.deepEqual((await transport()).frozenRecoveries,[held]);
    await cmd('session:next');assert.equal((await state()).rig.sessionLibrary.current.id,sessionId);assert.deepEqual((await transport()).frozenRecoveries,[held]);
    if((await state()).page!=='stage')await click('stage');await failStorage(true);await click('settings');await click('power:open');await click('power:restart');await advance(700);assert.equal((await page.evaluate(()=>segnoDemo.powerState())).phase,'error');assert.deepEqual((await transport()).frozenRecoveries,[held]);await click('power:cancel');await click('stage');
    await failStorage(false);await foot(1);assert.equal((await transport()).frozenRecoveries.length,0);near(layer(await state()).at(-1).seconds,1);assert.equal(layer(await state()).length,priorLayerCount+1);

    // A selected external clock's actual disconnect saves the partial take and does not re-arm it.
    await seed();await record(0,16);await page.evaluate(storageKey=>{const s=segnoDemo.snapshot(),rig=s.rig;rig.recordedParts=s.recordedParts;rig.trackPlayback=s.trackPlayback;rig.loopSettings=s.loopSettings;rig.syncSettings={source:'usb',followTransport:true,loss:'keep'};localStorage.setItem(storageKey,JSON.stringify(rig));},storageKey);await open();
    await page.evaluate(()=>{const at=performance.now();for(let i=7;i>=0;i--)segnoDemo.syncReceive('usb','clock',at-i*60000/(120*24));});assert.equal((await page.evaluate(()=>segnoDemo.syncState())).state,'synced');await page.evaluate(()=>segnoDemo.syncReceive('usb','continue'));assert.equal((await state()).trackPlayback['Track 1'],true);
    await cmd('select-track:1');await cmd('command:record-play');
    for(let i=0;i<4;i++){await advance(500);await page.evaluate(()=>segnoDemo.syncReceive('usb','clock',performance.now()));}
    await page.evaluate(()=>segnoDemo.midiConnect('usb',false));await advance(120);s=await state();assert.equal(s.captureState['Track 2'],'idle');assert.equal(layer(s,1).length,1);near(duration(s,1),16);assert(layer(s,1)[0].seconds>=2&&layer(s,1)[0].seconds<2.15);assert.equal(s.trackPlayback['Track 1'],true);assert.equal(s.trackPlayback['Track 2'],false);await cmd('view:wave');await shot('clock-loss-recovered');
    const recovered=structuredClone(layer(s,1));await advance(2000);assert.deepEqual(layer(await state(),1),recovered);await open();assert.deepEqual(layer(await state(),1),recovered);

    // SPP enters through the selected MIDI receiver; stopped Continue keeps the requested head.
    await cmd('command:stop');await page.evaluate(()=>segnoDemo.midiConnect('usb',true));await page.evaluate(()=>segnoDemo.syncMessage('usb',{kind:'song-position',value:12}));near((await transport()).tracks[0].position,3/16);
    await advance(2000);near((await transport()).timingCycle.position,3/16);await page.evaluate(()=>segnoDemo.syncReceive('usb','continue'));await advance(500);near((await transport()).tracks[0].position,4/16);
    const head=(await transport()).tracks[0].position;await page.evaluate(()=>segnoDemo.syncMessage('usb',{kind:'song-position',value:0}));near((await transport()).tracks[0].position,head);assert.match((await transport()).notice.action,/Stop playback/);
    await page.evaluate(()=>segnoDemo.syncReceive('usb','stop'));await page.evaluate(()=>segnoDemo.syncReceive('usb','start'));near((await transport()).tracks[0].position,0);
    assert.deepEqual(errors,[]);console.log(kind+': timing completion normal-host journeys pass');
  }finally{await browser.close();}
}
(async()=>{for(const kind of ['chrome','firefox'])await run(kind);})().catch(e=>{console.error(e);process.exitCode=1;});
