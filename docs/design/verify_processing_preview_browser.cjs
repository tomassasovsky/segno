// Standalone packet preview consumes the same render policy as the main host.
const {chromium,firefox}=require('playwright'),assert=require('node:assert/strict');
const base=process.env.DESIGN_BASE_URL||'http://127.0.0.1:8768/';
(async()=>{for(const kind of ['chrome','firefox']){const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});try{
 const p=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[];p.setDefaultTimeout(7000);p.on('pageerror',e=>errors.push(e.message));await p.goto(base+'processing-behavior-preview.html');
 const click=id=>p.locator('[data-action='+JSON.stringify(id)+']').click();
 assert.match(await p.locator('#cycle-result').textContent(),/^6 bars/);await click('tab:capture');await click('cut-tails');assert.match(await p.locator('#cycle-result').textContent(),/tails end at boundary/);
 await click('level:0');assert.match(await p.locator('#before-signal').textContent(),/receives signal/);assert.match(await p.locator('#after-signal').textContent(),/receives silence/);
 await click('level:1');assert.match(await p.locator('#after-signal').textContent(),/receives signal/);await click('tab:tails');await click('stop');let s=await p.evaluate(()=>processingReview.snapshot());assert.equal(s.state.frame.tracks.Guitar.feed,false);assert.equal(s.state.frame.inputs.Voice.feed,true);
 await click('cut');s=await p.evaluate(()=>processingReview.snapshot());assert.deepEqual(s.state.buffers,{});assert.deepEqual(s.state.frame.outputs.Main.audible,[]);await click('reset');assert.equal((await p.evaluate(()=>processingReview.snapshot())).state.frame.tracks.Guitar.feed,true);
 assert.deepEqual(errors,[]);console.log(kind+': standalone preview loads shared render policy, retains six-bar/tails result, output tap comparisons and packet lifecycle.');
 }finally{await browser.close();}}})().catch(e=>{console.error(e);process.exitCode=1;});
