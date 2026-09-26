const {chromium,firefox}=require('playwright'),assert=require('node:assert/strict'),fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];page.on('pageerror',e=>errors.push(e.message));await page.clock.install({time:new Date('2026-09-07T18:00:00Z')});await page.clock.pauseAt(new Date('2026-09-07T18:00:01Z'));
 for(const review of ['stage-layout','stage-layout-wave','stage-layout-mixer','stage-layout-recording','stage-layout-overdub','stage-layout-queued','stage-layout-clipping','stage-layout-bank']){
  await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review='+review+'&canvas=actual');await page.evaluate(()=>document.fonts.ready);
  assert.equal(await page.locator('.stage-track').count(),4);assert.equal(await page.locator('.stage-track.bank-active').count(),4);
  const trackText=await page.locator('.stage-tracks').innerText();
  assert.doesNotMatch(trackText,/dBFS|BPM|Playing|Empty|Recording|Overdubbing/,'routine state and duplicate readings stay off the track faces');
  const queued=page.locator('.stage-queued');assert.equal(await queued.count(),review==='stage-layout-queued'?1:0);
  if(review==='stage-layout-queued'){
   assert.equal(await queued.locator('strong').textContent(),'Record');assert.equal(await queued.locator('span').textContent(),'Next bar');
   assert.equal(await page.locator('[data-action="stage-track:3"] .stage-queued').count(),1);
   const q=await queued.boundingBox(),m=await page.locator('[data-action="stage-track:3"] .stage-meter').boundingBox();
   assert.ok(Math.abs(q.x+q.width/2-m.x-m.width/2)<1);assert.ok(Math.abs(q.y+q.height/2-m.y-m.height/2)<1);
   assert.equal(await queued.locator('button,input,[tabindex]').count(),0);
  }
  if(review==='stage-layout-mixer'){
   assert.equal(await page.locator('.stage-mixer-view .stage-track-info').count(),4);
   assert.equal(await page.locator('.stage-mixer-view [data-stage-bars]').count(),4);
   assert.equal(await page.locator('.stage-mixer-view [data-stage-layers]').count(),4);
   assert.equal(await page.locator('.stage-mixer-view .stage-meter').count(),4);
   assert.equal(await page.locator('.stage-mixer-view [data-stage-progress]').count(),4);
   const ranges=await page.locator('.stage-meter-fader').evaluateAll(es=>es.map(e=>{const f=e.querySelector('input').getBoundingClientRect(),m=e.getBoundingClientRect();return {x:Math.abs(m.x-f.x),y:Math.abs(m.y-f.y),width:Math.abs(m.width-f.width),height:Math.abs(m.height-f.height)};}));
   assert.ok(ranges.every(r=>Object.values(r).every(v=>v<1)),'gain controls share the stereo meter surface');
  }
  if(review==='stage-layout-wave'){
   const gaps=await page.locator('.stage-wave-meta').evaluateAll(es=>es.map(e=>{const [bars,layers,fx]=[...e.children].map(c=>c.getBoundingClientRect());return [layers.x-bars.right,fx.x-layers.right];}));
   for(const g of gaps)assert.ok(g.every(n=>n>=30),'Bars, layers and FX have separate space');
   const shapes=await page.locator('.wave-envelope path').evaluateAll(es=>es.map(e=>({d:e.getAttribute('d'),w:e.getBBox().width,h:e.getBBox().height})));
   assert.equal(new Set(shapes.map(s=>s.d)).size,3,'Different source recordings produce different contours');
   for(const s of shapes){assert.ok(s.w>1022);assert.ok(s.h>20&&s.h<100,'Recorded peaks fit the shared amplitude scale');}
  }
  if(review==='stage-layout-clipping'){assert.equal(await page.locator('.clipped-meter').count(),1);assert.equal(await page.locator('.stage-output').textContent(),'OUT CLIP');}if(review==='stage-layout'){const boxes=await page.locator('.stage-db-scale,.stage-meter').evaluateAll(es=>es.map(e=>({y:e.getBoundingClientRect().y,h:e.getBoundingClientRect().height})));for(const b of boxes){assert.ok(Math.abs(b.y-boxes[0].y)<2);assert.ok(Math.abs(b.h-boxes[0].h)<2);}}const bad=await page.evaluate(()=>[...document.querySelectorAll('#screen button,#screen input')].filter(e=>{const r=e.getBoundingClientRect();return r.x<0||r.y<0||r.right>1921||r.bottom>1081;}).map(e=>e.textContent));assert.deepEqual(bad,[],review);
  if(kind==='chrome'){fs.mkdirSync('docs/design/stage-display-previews',{recursive:true});await page.locator('#screen').screenshot({path:'docs/design/stage-display-previews/'+review+'.png'});}
 }
 await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review=stage-layout&canvas=actual');const before=await page.evaluate(()=>segnoDemo.snapshot());await page.locator('[data-action="stage-track:1"]').click();await page.locator('[data-action="stage-bank"]').click();assert.deepEqual(await page.locator('.stage-track-number').allTextContents(),['5','6','7','8']);await page.locator('[data-action="stage-bank"]').click();
 assert.equal((await page.evaluate(()=>segnoDemo.displayState())).selected,1);
 for(const v of ['wave','mixer','track']){await page.locator('[data-action="stage-view-menu"]').click();await page.locator('[data-action="stage-view:'+v+'"]').click();assert.equal((await page.evaluate(()=>segnoDemo.displayState())).selected,1);}
 const after=await page.evaluate(()=>segnoDemo.snapshot());for(const k of ['captureState','trackPlayback','recordedParts'])assert.deepEqual(after[k],before[k]);assert.deepEqual(after.rig.racks,before.rig.racks);
 await page.locator('[data-action="stage-view-menu"]').click();await page.locator('[data-action="stage-view:mixer"]').click();const slider=page.locator('[data-action="stage-mix:1:level"]');await slider.fill('-2.5');assert.ok(Math.abs((await page.evaluate(()=>segnoDemo.snapshot())).rig.expressionMix['Track 2'].level-10**(-2.5/20))<1e-9);
 await slider.focus();await page.evaluate(()=>segnoDemo.press());await page.evaluate(()=>segnoDemo.turn(5));assert.ok(Math.abs((await page.evaluate(()=>segnoDemo.displayState())).tracks[1].level-1)<1e-9);await page.keyboard.press('Escape');assert.ok(Math.abs((await page.evaluate(()=>segnoDemo.displayState())).tracks[1].level-10**(-2.5/20))<1e-9);
 await page.locator('[data-action="stage-mute:1"]').click();assert.equal((await page.evaluate(()=>segnoDemo.snapshot())).rig.mutedTracks[1],true);
 await page.locator('[data-action="stage-mix:1:pan"]').fill('0.2');assert.equal((await page.evaluate(()=>segnoDemo.displayState())).tracks[1].pan,.2);
 await slider.dblclick();assert.equal((await page.evaluate(()=>segnoDemo.displayState())).tracks[1].level,1,'double tap restores unity');
 await page.goto('http://127.0.0.1:8768/stage-two-screen-preview.html?review=stage-layout');const main=page.frameLocator('#main');await main.locator('.stage-track').first().waitFor();await page.clock.runFor(100);
 await main.locator('[data-action="stage-track:2"]').click();await page.clock.runFor(100);assert.match(await page.locator('#track').textContent(),/Percussive guitar/);assert.equal(await page.locator('.close-wave path').count(),1);
 const shape=await page.locator('.close-wave path').getAttribute('d');await main.locator('[data-action="stage-bank"]').click();await page.clock.runFor(100);assert.equal(await page.locator('#bank').textContent(),'Bank B');assert.deepEqual(await page.locator('.close-wave path').getAttribute('d'),shape);
 await main.locator('[data-action="stage-view-menu"]').click();await main.locator('[data-action="stage-view:wave"]').click();await page.clock.runFor(100);assert.equal(await page.locator('#track-number').textContent(),'3');
 await main.locator('[data-action="stage-track:5"]').click();await page.clock.runFor(100);assert.equal(await page.locator('.empty-label').textContent(),'Empty track');assert.equal(await page.locator('.close-wave path').count(),0);
 await main.locator('[data-action="settings"]').click();await page.clock.runFor(100);assert.equal(await page.locator('#track-number').textContent(),'6');await main.locator('[data-action="effects"]').click();await page.clock.runFor(100);assert.equal(await page.locator('#track-number').textContent(),'6');
 await page.locator('#scenario').selectOption('stage-layout-recording');await main.locator('.stage-track.recording').waitFor();await page.clock.runFor(100);assert.equal(await page.locator('#state').textContent(),'Recording');
 if(kind==='chrome'){await page.screenshot({path:'docs/design/stage-display-previews/two-displays.png'});await page.goto('http://127.0.0.1:8768/stage-two-screen-preview.html?canvas=small');await page.frameLocator('#main').locator('.stage-track').first().waitFor({state:'attached'});await page.clock.runFor(100);await page.locator('#screen').screenshot({path:'docs/design/stage-display-previews/selected-track.png'});}
 assert.deepEqual(errors,[]);console.log(kind+': Track/Wave/Mixer, shared selection and mix, encoder cancel, double-tap reset, bank retention, selected waveform, empty/capture states and Settings/FX continuity passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
