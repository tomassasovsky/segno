// Independent host regression: imported descriptors follow recorded-content history.
// Use fresh contexts; neither media decoding nor physical USB is exercised.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const base=process.env.FX_PROTOTYPE_URL||'http://localhost:8768/fx-ux-prototype.html';
(async()=>{for(const [kind,type] of [['chrome',chromium],['firefox',firefox]]){
 const browser=await type.launch({headless:true,...(kind==='chrome'&&process.env.ATLAS_CHROME?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const context=await browser.newContext({viewport:{width:1920,height:1080}}),p=await context.newPage(),errors=[];p.setDefaultTimeout(6000);p.on('pageerror',e=>errors.push(e.message));
  await p.clock.install({time:new Date('2026-09-08T12:00:00Z')});await p.clock.pauseAt(new Date('2026-09-08T12:00:01Z'));
  const b=id=>p.locator('[data-action='+JSON.stringify(id)+']'),click=id=>b(id).click(),snap=()=>p.evaluate(()=>segnoDemo.snapshot()),command=key=>p.evaluate(key=>segnoDemo.dispatchMapping(key,'import-history-review'),key),foot=id=>p.evaluate(id=>{segnoDemo.performanceDown(id,'import-review-foot');segnoDemo.performanceUp('import-review-foot');},id);
  const track=async i=>(await snap()).performance.bounce.tracks[i];
  async function importPlan(i){
   if((await snap()).page!=='stage')await click('stage');await command('mode:tracks');if((await snap()).bank!==Math.floor(i/4))await click('stage-bank');await click('stage-track:'+i);await click('stage-load-audio');await click('audio:up');await click('audio:folder:Saved%20audio');await click('audio:file:inside-9');await click('audio:load-track');await click('audio:timing:adapt');assert.equal((await snap()).audioLibrary.trackImport.target,i);
  }
  await p.goto(base);await p.waitForFunction(()=>window.segnoDemo);
  await click('settings');await click('loop:page:loop-settings');await click('loop:page:loop-mode');await click('loop:mode:free');if(await b('loop:mode-confirm:free').count())await click('loop:mode-confirm:free');await click('stage');
  await importPlan(3);const sourceFiles=(await snap()).audioLibrary.state.files;await click('audio:commit-track-import');await p.clock.runFor(1600);assert.equal((await snap()).audioLibrary.view,'imported');const descriptor=(await snap()).audioLibrary.state.trackImports[3],imported=await track(3);assert.deepEqual(imported.imported,descriptor);
  await p.reload();assert.deepEqual((await track(3)).imported,descriptor,'saved import metadata survives reload');await command('select-track:3');await command('command:undo');assert.deepEqual((await track(3)).parts,[]);assert.equal((await snap()).audioLibrary.state.trackImports[3],undefined,'general Undo releases the Library destination');assert.equal(await b('stage-load-audio').count(),1,'empty destination can import again');
  await command('command:redo');assert.deepEqual(await track(3),imported,'general Redo restores the exact content and import descriptor');
  await command('direct:clear:3');assert.deepEqual((await track(3)).parts,[]);assert.equal((await snap()).audioLibrary.state.trackImports[3],undefined,'Clear removes the import descriptor');await command('direct:undo:3');assert.deepEqual(await track(3),imported,'Clear Undo restores exact imported content');
  await command('direct:redo:3');assert.equal((await snap()).audioLibrary.state.trackImports[3],undefined);await command('direct:undo:3');
  // Replace an imported destination with a bounce, then recover its descriptor.
  await command('mode:bounce');await foot(4);await foot(0);await foot(7);await foot(0);assert.equal((await snap()).performance.bounce.step,'done');assert.deepEqual((await track(3)).parts,['Bounce']);assert.equal((await snap()).audioLibrary.state.trackImports[3],undefined,'Bounce destination stops claiming an unrelated import');await command('direct:undo:3');assert.deepEqual(await track(3),imported,'Bounce Undo restores overwritten import');
  // Bounce the imported source with Clear sources and recover the whole group.
  await command('mode:bounce');await foot(7);await foot(0);await foot(4);await foot(8);await foot(0);assert.equal((await snap()).performance.bounce.step,'done');assert.deepEqual((await track(3)).parts,[]);assert.equal((await snap()).audioLibrary.state.trackImports[3],undefined,'cleared bounce source releases its descriptor');await command('direct:undo:0');assert.deepEqual(await track(3),imported,'group Undo restores imported source metadata');
  // A failed second import preserves the existing import, empty target and history.
  await importPlan(7);const before=await snap();await p.evaluate(()=>{window.importReviewWriter=Storage.prototype.setItem;Storage.prototype.setItem=function(){throw new DOMException('Simulated save failure','QuotaExceededError');};});await click('audio:commit-track-import');await p.clock.runFor(1600);let s=await snap();assert.equal(s.audioLibrary.view,'track-import');assert.match(s.audioLibrary.error,/could not be loaded/i);assert.deepEqual(s.audioLibrary.state.trackImports,before.audioLibrary.state.trackImports);assert.deepEqual(s.recordedParts,before.recordedParts);assert.deepEqual(s.rig.editHistory,before.rig.editHistory,'failed import adds no history');assert.deepEqual(s.performance.bounce.tracks,before.performance.bounce.tracks,'failed import preserves all recorded content');await p.evaluate(()=>{Storage.prototype.setItem=window.importReviewWriter;delete window.importReviewWriter;});
  assert.deepEqual(s.audioLibrary.state.files,sourceFiles,'history never deletes source library files');await p.reload();s=await snap();assert.deepEqual(s.audioLibrary.state.trackImports,before.audioLibrary.state.trackImports,'failed import left saved descriptors intact');assert.deepEqual(s.recordedParts,before.recordedParts);assert.deepEqual(errors,[]);
  console.log(kind+': Import Undo/Redo, destination reuse, Clear and Bounce metadata recovery, source retention and failed-save rollback passed');await context.close();
 }finally{await browser.close();}
}})().catch(error=>{console.error(error);process.exitCode=1;});
