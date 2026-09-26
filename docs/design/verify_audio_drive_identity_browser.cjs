// Normal-host drive identity regressions. Audio samples and drives are simulated.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const p=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];p.setDefaultTimeout(8000);p.on('pageerror',e=>errors.push(e.message));await p.clock.install();
  const b=id=>p.locator('[data-action='+JSON.stringify(id)+']'),click=id=>b(id).click(),snap=()=>p.evaluate(()=>segnoDemo.snapshot());
  const drive=id=>p.evaluate(id=>segnoDemo.simulateRecordingDrive({id,label:id,connected:true}),id);
  const finish=()=>p.clock.runFor(1500);
  await p.goto(base+'?canvas=actual');await p.evaluate(()=>localStorage.clear());await p.reload();
  await click('session:library');await click('audio-library');await click('recorder:open');await click('recorder:destination:usb');await click('recorder:start');await p.clock.runFor(5400);await click('recorder:stop');await p.clock.runFor(850);await click('recorder:view');
  const original=(await snap()).recorder.last,originalParts=original.parts,takeId=original.performance.takeId;
  assert.equal(original.storage.mediaId,'segno-usb-1');
  // A multipart take becomes a managed Internal copy, then a copy belonging to B.
  await click('audio:load');await finish();let s=await snap(),inside=s.audioLibrary.state.backing;
  assert.deepEqual(inside.storage,{location:'internal'});assert.deepEqual(inside.parts,originalParts);assert.equal(inside.performance.takeId,takeId);
  await click('audio:browse');await drive('drive-b');await click('audio:export-usb');await finish();s=await snap();const exported=s.audioLibrary.lastExport;
  assert.equal(s.audioLibrary.view,'exported');assert.deepEqual(exported.storage,{location:'usb',mediaId:'drive-b'});assert.deepEqual(exported.parts,originalParts);assert.equal(exported.performance.takeId,takeId);
  await click('audio:show-export');assert.equal(await b('audio:file:'+exported.id).count(),1);await drive('segno-usb-1');assert.equal(await b('audio:file:'+exported.id).count(),0);await drive('drive-b');await click('audio:preview');assert.equal((await snap()).audioLibrary.preview,true);await drive('segno-usb-1');await p.clock.runFor(100);assert.equal((await snap()).audioLibrary.preview,false);assert.match((await snap()).audioLibrary.error,/original USB/);await drive('drive-b');
  await p.reload();s=await snap();assert.deepEqual(s.audioLibrary.state.files.find(f=>f.id===inside.id).storage,{location:'internal'});assert.deepEqual(s.audioLibrary.state.usbFiles.find(f=>f.id===exported.id).storage,{location:'usb',mediaId:'drive-b'});
  await click('session:library');await click('audio-library');
  const internalSource=async()=>{await click('audio:location:internal');await click('audio:folder:Backing%20tracks');await click('audio:file:'+inside.id);};
  const usbSource=async()=>{await drive('segno-usb-1');await click('audio:location:usb');await click('audio:folder:'+encodeURIComponent(original.folder));await click('audio:file:'+original.id);};
  // Same name on B does not collide on C. A name review for B cannot apply to C.
  await internalSource();await drive('drive-b');await click('audio:export-usb');assert.equal((await snap()).audioLibrary.dialog.type,'export-replace');const beforeChoice=(await snap()).audioLibrary.state;
  await drive('drive-c');await click('audio:export-replace');assert.equal((await snap()).audioLibrary.job,null);assert.deepEqual((await snap()).audioLibrary.state,beforeChoice);assert.match((await snap()).audioLibrary.error,/drive changed/);
  await click('audio:export-usb');assert.equal((await snap()).audioLibrary.view,'progress');await finish();const cExport=(await snap()).audioLibrary.lastExport;assert.equal(cExport.name,inside.name);assert.equal(cExport.storage.mediaId,'drive-c');assert.notEqual(cExport.id,exported.id);await click('audio:export-done');
  // Each operation freezes its drive and refuses publication if it changes.
  await drive('drive-d');let before=(await snap()).audioLibrary.state;await click('audio:export-usb');await drive('drive-e');await finish();assert.deepEqual((await snap()).audioLibrary.state,before);assert.match((await snap()).audioLibrary.error,/drive changed/);
  await usbSource();before=(await snap()).audioLibrary.state;await click('audio:load');await drive('drive-b');await finish();assert.deepEqual((await snap()).audioLibrary.state,before);
  await usbSource();await click('audio:load-track');await p.locator('[data-action^="audio:import-target:"]:not([disabled])').first().click();before=(await snap()).audioLibrary.state;
  await drive('drive-b');assert.equal(await b('audio:commit-track-import').isDisabled(),true);assert.equal((await snap()).audioLibrary.job,null);assert.deepEqual((await snap()).audioLibrary.state,before);assert.match((await snap()).audioLibrary.importPlan.reason,/original USB/);
  await drive('segno-usb-1');await click('audio:commit-track-import');await drive('drive-b');await finish();assert.deepEqual((await snap()).audioLibrary.state,before);
  await drive('segno-usb-1');await click('audio:commit-track-import');await finish();s=await snap();assert.deepEqual(s.audioLibrary.lastImport.file.storage,{location:'internal'});assert.deepEqual(s.audioLibrary.lastImport.file.parts,originalParts);assert.equal(s.audioLibrary.lastImport.file.performance.takeId,takeId);
  await click('audio:import-more');await click('audio:save');await click('audio:render:longer');await click('audio:save-location:usb');await drive('drive-save');before=(await snap()).audioLibrary.state;await click('audio:commit-save');await drive('drive-b');await finish();assert.deepEqual((await snap()).audioLibrary.state,before);
  // Failed persistence keeps both drive catalogues intact. Retry commits once to B.
  await p.evaluate(()=>{window.identityOriginalSet=Storage.prototype.setItem;Storage.prototype.setItem=function(){throw Error('simulated writer failure');};});
  await click('audio:commit-save');await finish();assert.deepEqual((await snap()).audioLibrary.state,before);assert.match((await snap()).audioLibrary.error,/could not be saved/);
  await p.evaluate(()=>{Storage.prototype.setItem=window.identityOriginalSet;delete window.identityOriginalSet;});await click('audio:commit-save');await finish();s=await snap();assert.deepEqual(s.audioLibrary.lastSaved.storage,{location:'usb',mediaId:'drive-b'});assert.equal(s.audioLibrary.state.usbFiles.filter(f=>f.id===s.audioLibrary.lastSaved.id).length,1);
  await click('audio:show-saved');await click('audio:save');await click('audio:render:longer');await click('audio:save-location:usb');await click('audio:commit-save');assert.equal((await snap()).audioLibrary.dialog.type,'replace');before=(await snap()).audioLibrary.state;await drive('drive-c');await click('audio:replace');assert.equal((await snap()).audioLibrary.job,null);assert.deepEqual((await snap()).audioLibrary.state,before);
  assert.deepEqual(errors,[]);console.log(kind+': USB A → Internal → USB B, multipart identity, per-drive collision review, copy/import/render races, writer rollback and reload passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
