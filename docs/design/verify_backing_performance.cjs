const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const p=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
  p.setDefaultTimeout(7000);p.on('pageerror',e=>errors.push(e.message));
  await p.clock.install({time:new Date('2026-09-07T18:00:00Z')});await p.clock.pauseAt(new Date('2026-09-07T18:00:01Z'));
  const base='http://127.0.0.1:8768/fx-ux-prototype.html',b=id=>p.locator('[data-action='+JSON.stringify(id)+']'),foot=id=>b('perform:'+id),snap=()=>p.evaluate(()=>segnoDemo.snapshot()),state=async()=>(await snap()).performance.backing;
  const open=review=>p.goto(base+'?review='+review+'&canvas=actual');
  await open('performance-backing');const untouched=(await snap()).trackPlayback;
  assert.equal((await state()).files.length,9);assert.equal((await state()).playing,false);
  await foot(0).click();await p.clock.runFor(3500);assert.equal((await state()).playing,true);assert((await state()).position>=3.5);
  await foot(5).click();assert.equal((await state()).selected,'inside-2');assert.equal((await state()).loaded.id,'inside-1');assert.equal((await state()).playing,true,'selection does not replace playing audio');
  await foot(0).click();assert.equal((await state()).loaded.id,'inside-2');assert.equal((await state()).position,0);
  await p.clock.runFor(2500);await foot(0).click();const paused=(await state()).position;await p.clock.runFor(2000);assert.equal((await state()).position,paused);assert.equal((await state()).playing,false);
  await foot(0).click();await p.clock.runFor(1000);assert.equal((await state()).position,paused+1);await foot(1).click();assert.equal((await state()).position,0);assert.deepEqual((await snap()).trackPlayback,untouched,'backing Stop does not stop loops');
  await foot(9).click();assert.equal((await state()).page,1);assert.equal((await snap()).bank,0,'backing page is independent of track bank');await foot(7).click();assert.equal((await state()).selected,'inside-8');await foot(8).click();assert.equal((await state()).selected,'inside-9');assert.equal((await state()).page,2);assert.equal(await foot(5).isDisabled(),true);assert.equal(await foot(8).isEnabled(),true,'last item still permits hold-to-seek');
  await foot(2).click();assert.equal((await state()).selected,'inside-8');assert.equal((await state()).page,1);
  await foot(0).click();await foot(3).click();assert.equal((await snap()).performance.view,'tracks');assert.equal((await state()).playing,true,'Exit preserves playback');
  await foot(3).focus();await p.keyboard.down(' ');await p.clock.runFor(850);await p.keyboard.up(' ');assert.equal((await snap()).performance.view,'custom');await foot(1).click();assert.equal((await snap()).performance.view,'backing','assigned foot entry works');
  await p.clock.runFor(200000);assert.equal((await state()).playing,false,'end of file stops without auto-next');assert.equal((await state()).position,0);
  await open('performance-backing-empty');for(const id of [0,1,2,4,5,6,7,8,9])assert.equal(await foot(id).isDisabled(),true);assert.equal(await foot(3).isEnabled(),true);
  await open('audio-library');await b('audio:prepare').click();await b('audio:file:inside-2').click();await b('audio:prepare').click();await b('audio:prepared').click();assert.equal((await state()).files.length,2);
  await b('audio:file:inside-2').click();await b('audio:earlier').click();assert.deepEqual((await state()).files.map(f=>f.id),['inside-2','inside-1']);await b('audio:unprepare').click();assert.equal((await snap()).audioLibrary.state.files.length,9,'remove from prepared preserves file');
  await b('audio:perform').click();assert.equal((await snap()).performance.view,'backing');assert.equal((await state()).playing,false);await foot(0).click();assert.equal((await state()).loaded.id,'inside-1');
  await open('audio-prepared');await b('audio:file:inside-5').click();
  assert.equal(await p.locator('.audio-path [data-action="audio:earlier"]').count(),1,'move controls are attached to the list');
  await b('audio:earlier').focus();await p.keyboard.press('Enter');
  assert.equal((await state()).files[3].id,'inside-5');assert.equal((await snap()).focusId,'audio:earlier','encoder focus stays on the move action');
  assert.equal(await b('audio:file:inside-5').locator('.audio-order-number').textContent(),'4');
  await b('audio:perform').click();await foot(7).click();assert.equal((await state()).selected,'inside-5','reordered item is on the first performance page');
  await foot(9).click();await foot(4).click();assert.equal((await state()).selected,'inside-4','displaced item is on the next page');
  await open('audio-prepared');await b('audio:file:inside-8').click();await b('audio:later').click();
  assert.equal((await snap()).focusId,'audio:earlier','boundary moves preserve an enabled focus target');
  assert.equal(await b('audio:later').isDisabled(),true);
  assert.equal(await b('audio:file:inside-8').evaluate(e=>{const r=e.getBoundingClientRect(),box=e.closest('.audio-scroll').getBoundingClientRect();return r.top>=box.top-1&&r.bottom<=box.bottom+1;}),true,'moved row stays visible');
  await open('performance-backing-bank');await foot(7).click();await foot(3).click();await b('session:library').click();await b('audio-library').click();await b('audio:prepared').click();await b('audio:file:inside-8').click();for(let i=0;i<5;i++)await b('audio:earlier').click();await b('audio:perform').click();assert.equal((await state()).selected,'inside-8');assert.equal((await state()).page,0,'re-entering reveals the selected file after it moves across pages');
  await open('audio-usb');await b('audio:prepare').click();await p.clock.runFor(1600);assert.equal((await state()).loaded,null,'preparing does not load');assert.equal((await state()).files.length,1);await p.evaluate(()=>segnoDemo.simulateAudio({usbConnected:false}));await b('audio:prepared').click();await b('audio:perform').click();await foot(0).click();assert.equal((await state()).playing,true);
  await p.goto(base+'?canvas=actual');await p.evaluate(()=>localStorage.clear());await p.reload();await b('stage').click();await b('session:library').click();await b('audio-library').click();await b('audio:prepare').click();await b('audio:prepared').click();await b('audio:perform').click();await foot(0).click();const prepared=(await state()).files;await p.reload();assert.deepEqual((await state()).files,prepared);assert.equal((await state()).playing,false,'reload starts stopped');
  for(const review of ['performance-backing','performance-backing-queued','performance-backing-bank','performance-backing-empty','audio-prepared']){await open(review);await p.evaluate(()=>document.fonts.ready);const bad=await p.evaluate(()=>[...document.querySelectorAll('#screen button,.backing-overview')].filter(e=>{if(e.closest('.audio-scroll'))return false;const r=e.getBoundingClientRect();return r.x<0||r.y<0||r.right>1921||r.bottom>1081||e.scrollWidth>e.clientWidth+2||e.scrollHeight>e.clientHeight+2;}).map(e=>e.textContent));assert.deepEqual(bad,[],review);if(kind==='chrome'){fs.mkdirSync('docs/design/audio-library-previews',{recursive:true});await p.locator('#screen').screenshot({path:'docs/design/audio-library-previews/'+review+'.png'});}}
  assert.deepEqual(errors,[]);console.log(kind+': Backing preparation, order, removal, USB copy, foot entry, queue/play/pause/stop, independent paging, Exit, end-of-file, reload and layout passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
