// Fresh-demo consistency, without migrating a user's stored session mode.
const {chromium,firefox}=require('playwright'),assert=require('node:assert/strict');
const base=process.env.FX_PROTOTYPE_URL||'http://localhost:8768/fx-ux-prototype.html';
const key='segno-fx-factory-design-2026-09-06-channels';
(async()=>{const failures=[];for(const [kind,type]of [['chrome',chromium],['firefox',firefox]]){
 const browser=await type.launch({headless:true,...(kind==='chrome'&&process.env.ATLAS_CHROME?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const context=await browser.newContext(),p=await context.newPage(),errors=[];p.on('pageerror',error=>errors.push(error.message));await p.goto(base);await p.waitForFunction(()=>window.segnoDemo);const initial=await p.evaluate(()=>segnoDemo.snapshot()),lengths=initial.performance.bounce.tracks.filter(t=>t.parts.length).map(t=>t.length.durationBeats??t.length.audio.length);
  assert.deepEqual(lengths,[8,16,4],'fresh demo retains its intentionally unequal example content');console.log(kind+': fresh mode='+initial.loopSettings.mode+', recorded beats='+JSON.stringify(lengths));
  try{assert.equal(initial.loopSettings.mode,'free','unequal fresh demo tracks must not claim Multi equal-length mode');}catch(error){failures.push(kind+': '+error.message);}
  for(const mode of ['multi','sync','song','band','free']){
   const saved=structuredClone(initial.rig);saved.loopSettings={...initial.loopSettings,mode};saved.recordedParts=initial.recordedParts;
   await p.evaluate(({key,saved})=>localStorage.setItem(key,JSON.stringify(saved)),{key,saved});await p.reload();const loaded=await p.evaluate(()=>segnoDemo.snapshot());assert.equal(loaded.loopSettings.mode,mode,'saved '+mode+' mode is retained');assert.deepEqual(loaded.recordedParts,initial.recordedParts,'loading never rewrites saved content');
  }
  await p.goto(base+'?review=stage-layout-performance');const empty=await p.evaluate(()=>segnoDemo.snapshot());assert.equal(empty.loopSettings.mode,'multi','true empty recording fixture keeps the product default');assert.ok(Object.values(empty.recordedParts).every(parts=>!parts.length));
  await p.goto(base+'?review=performance-multiply-multi');const multi=await p.evaluate(()=>segnoDemo.snapshot());assert.equal(multi.loopSettings.mode,'multi','explicit Multi fixture retains its mode');const recorded=multi.performance.bounce.tracks.filter(t=>t.parts.length);assert.ok(recorded.every(t=>(t.length.durationBeats??t.length.audio.length)===8));
  assert.deepEqual(errors,[]);console.log(kind+': all saved modes, empty Multi default and explicit equal-length Multi fixture preserved');await context.close();
 }finally{await browser.close();}
}if(failures.length){for(const failure of failures)console.error(failure);process.exitCode=1;}})().catch(error=>{console.error(error);process.exitCode=1;});
