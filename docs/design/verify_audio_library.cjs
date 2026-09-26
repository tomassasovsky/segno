const {chromium, firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{
 for(const kind of ['chrome','firefox']){
  const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
  try{
   const p=await browser.newPage({viewport:{width:1920,height:1080}}), errors=[];
   p.setDefaultTimeout(7000);p.on('pageerror',e=>errors.push(e.message));
   await p.clock.install({time:new Date('2026-09-07T18:00:00Z')});await p.clock.pauseAt(new Date('2026-09-07T18:00:01Z'));
   const base='http://127.0.0.1:8768/fx-ux-prototype.html', b=id=>p.locator('[data-action='+JSON.stringify(id)+']');
   const open=review=>p.goto(base+'?review='+review+'&canvas=actual'), snap=()=>p.evaluate(()=>segnoDemo.snapshot()), audio=async()=>(await snap()).audioLibrary;
   await open('audio-library');assert.equal(await p.locator('h1').textContent(),'Audio library');
   assert.equal((await audio()).preview,false);assert.equal((await audio()).state.backing,null);
   await b('audio:preview').click();assert.equal((await audio()).preview,true);
   await b('audio:file:inside-8').click();assert.equal((await audio()).preview,false);assert.equal((await audio()).selected,'inside-8');
   const scroll=await p.locator('.audio-scroll').evaluate(e=>e.scrollTop);assert(scroll>0);
   await b('audio:preview').click();assert.equal(await p.locator('.audio-scroll').evaluate(e=>e.scrollTop),scroll,'audition preserves browse position');
   await b('audio:load').click();assert.equal((await audio()).view,'backing');assert.equal((await audio()).playing,false);
   await b('audio:play').click();assert.equal((await audio()).playing,true);await b('audio:browse').click();await b('audio:file:inside-2').click();await b('audio:load').click();assert.equal((await audio()).dialog.type,'load');await b('audio:dialog-cancel').click();assert.equal((await audio()).state.backing.id,'inside-8');
   await b('audio:load').click();await b('audio:load-confirm').click();assert.equal((await audio()).state.backing.id,'inside-2');assert.equal((await audio()).playing,false);
   await open('audio-usb');let before=(await audio()).state;
   await b('audio:load').click();assert.equal((await audio()).view,'progress');await b('audio:cancel-job').click();await p.clock.runFor(1600);assert.deepEqual((await audio()).state,before,'canceled import writes no partial file');
   await b('audio:load').click();await p.evaluate(()=>segnoDemo.simulateAudio({usbConnected:false}));await p.clock.runFor(1600);assert.deepEqual((await audio()).state,before);assert.match((await audio()).error,/disconnected/);
   await p.evaluate(()=>segnoDemo.simulateAudio({usbConnected:true}));await b('audio:load').click();await p.clock.runFor(1600);let a=await audio();assert.equal(a.view,'backing');assert.equal(a.state.files.length,before.files.length+1);assert.equal(a.state.backing.importedFrom,'usb-1');assert.equal(a.playing,false);
   await p.evaluate(()=>segnoDemo.simulateAudio({usbConnected:false}));assert.equal((await audio()).state.backing.name,'Evening lights — live version.wav');await b('audio:play').click();assert.equal((await audio()).playing,true,'internal copy no longer depends on USB');
   await open('audio-save');await b('audio:name').click();await p.keyboard.type('Test mix');await b('audio:name-done').click();assert.equal((await audio()).draft.name,'Test mix');
   await b('audio:track:1').click();await b('audio:track:2').click();assert.deepEqual((await audio()).draft.tracks,[0]);
   await b('audio:commit-save').click();await p.clock.runFor(1600);a=await audio();assert.equal(a.view,'saved');assert.equal(a.lastSaved.name,'Test mix.wav');assert.deepEqual(a.lastSaved.recipe.tracks.map(t=>t.track),[0]);
   await b('audio:show-saved').click();assert.equal((await audio()).folder,'Saved audio');assert.equal((await audio()).selected,a.lastSaved.id);
   await b('audio:save').click();await b('audio:name').click();await p.keyboard.type('Test mix');await b('audio:name-done').click();before=(await audio()).state;await b('audio:commit-save').click();assert.equal((await audio()).dialog.type,'replace');await b('audio:dialog-cancel').click();assert.deepEqual((await audio()).state,before,'replacement requires an explicit action');
   await b('audio:commit-save').click();await b('audio:replace').click();await p.clock.runFor(1600);a=await audio();assert.equal(a.state.files.length,before.files.length);assert.equal(a.lastSaved.recipe.tracks.length,3);
   await open('audio-save');await p.evaluate(()=>segnoDemo.simulateAudio({full:true}));before=(await audio()).state;await b('audio:commit-save').click();await p.clock.runFor(1600);assert.equal((await audio()).view,'save');assert.match((await audio()).error,/space/);assert.deepEqual((await audio()).state,before);
   await p.evaluate(()=>segnoDemo.simulateAudio({full:false}));await b('audio:commit-save').click();await p.evaluate(()=>segnoDemo.setCapture('Track 1','recording'));await p.clock.runFor(1600);assert.match((await audio()).error,/changed/);assert.deepEqual((await audio()).state,before);assert.equal(await b('audio:commit-save').isDisabled(),true);
   await open('audio-save-usb');await b('audio:commit-save').click();await b('stage').click();await p.clock.runFor(1600);assert.equal((await snap()).page,'stage');assert.equal((await audio()).lastSaved,null,'leaving cancels pending save');
   await open('audio-library');await b('audio:location:internal').click();assert.equal((await audio()).folder,'');await b('audio:folder:Saved%20audio').click();assert.equal((await audio()).folder,'Saved audio');await b('audio:up').click();assert.equal((await audio()).folder,'');
   assert.equal((await snap()).focusId,'audio:folder:Saved%20audio');await p.evaluate(()=>segnoDemo.turn(-1));assert.equal((await snap()).focusId,'audio:folder:Backing%20tracks');await p.evaluate(()=>segnoDemo.press());assert.equal((await audio()).folder,'Backing tracks','encoder enters folders');
   await open('audio-file-error');assert.equal(await b('audio:preview').isDisabled(),true);assert.equal(await b('audio:load').isDisabled(),true);
   await open('audio-usb-missing');assert.match(await p.locator('.audio-no-drive').textContent(),/Connect a USB drive/);await b('audio:location:internal').click();assert.equal((await audio()).location,'internal');
   await open('audio-save-name');await b('audio:key:clear').click();assert.equal(await b('audio:name-done').isDisabled(),true);await b('audio:dialog-cancel').click();assert.equal((await audio()).draft.name,'Evening loop');
   await p.goto(base+'?canvas=actual');await p.evaluate(()=>localStorage.clear());await p.reload();await b('stage').click();await b('session:library').click();await b('audio-library').click();await b('audio:load').click();const loaded=(await audio()).state.backing;await p.reload();assert.deepEqual((await audio()).state.backing,loaded,'prepared audio is recalled');assert.equal((await audio()).playing,false);
   await b('stage').click();await b('session:library').click();await b('audio-library').click();await b('audio:save').click();await b('audio:commit-save').click();await p.clock.runFor(1600);const saved=(await audio()).state.files;await p.reload();assert.deepEqual((await audio()).state.files,saved,'saved audio catalogue is recalled');
   await b('stage').click();await b('session:library').click();await b('audio-library').click();await b('audio:save').click();await b('audio:name').click();await p.keyboard.type('Failed write');await b('audio:name-done').click();const quotaBefore=(await audio()).state;await p.evaluate(()=>{Storage.prototype.setItem=function(){throw new Error('quota');};});await b('audio:commit-save').click();await p.clock.runFor(1600);assert.equal((await audio()).view,'save');assert.deepEqual((await audio()).state,quotaBefore);assert.match((await audio()).error,/could not be saved/);
   for(const review of ['audio-library','audio-usb','audio-save','audio-save-usb','audio-save-name','audio-backing','audio-usb-missing','audio-file-error']){
    await open(review);await p.evaluate(()=>document.fonts.ready);
    const bad=await p.evaluate(()=>[...document.querySelectorAll('#screen button')].filter(e=>{if(e.closest('.audio-scroll'))return false;const r=e.getBoundingClientRect();return r.x<0||r.y<0||r.right>1921||r.bottom>1081||e.scrollWidth>e.clientWidth+2||e.scrollHeight>e.clientHeight+2;}).map(e=>e.textContent));assert.deepEqual(bad,[],review);
    if(kind==='chrome'){fs.mkdirSync('docs/design/audio-library-previews',{recursive:true});await p.locator('#screen').screenshot({path:'docs/design/audio-library-previews/'+review+'.png'});}
   }
   assert.deepEqual(errors,[]);console.log(kind+': browse, scroll, preview, load, USB copy/cancel/disconnect, named save/replace, errors, recording guard, encoder, reload and layout passed.');
  }finally{await browser.close();}
 }
})().catch(e=>{console.error(e);process.exitCode=1;});
