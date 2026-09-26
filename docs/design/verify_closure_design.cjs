const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await (kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
 const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.clock.install({time:new Date('2026-09-08T08:00:00Z')});await page.clock.pauseAt(new Date('2026-09-08T08:00:01Z'));
 const button=id=>page.locator('[data-action='+JSON.stringify(id)+']');
 const state=()=>page.evaluate(()=>segnoDemo.snapshot());
 const display=()=>page.evaluate(()=>segnoDemo.displayState());
 const screen=()=>page.locator('#screen');
 await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review=stage-layout-mixer&canvas=actual');
 await page.evaluate(()=>document.fonts.ready);
 const before=await state();await button('stage-track:2').click();assert.equal((await display()).selected,2);await button('stage-bank').click();await button('stage-rename:4').click();
 assert.equal(await page.locator('.keyboard-sheet').count(),1);await button('key:clear').click();for(const c of 'CHORUS')await button('key:'+c).click();
 await button('cancel-modal').click();assert.equal((await display()).tracks[4].name,'Chorus harmonies');
 await button('stage-rename:4').click();await button('key:clear').click();for(const c of 'CHORUS')await button('key:'+c).click();await button('track-rename-done').click();
 assert.equal((await display()).tracks[4].name,'CHORUS');assert.deepEqual((await state()).trackPlayback,before.trackPlayback);
 await button('stage-rename:4').click();await button('key:clear').click();await button('track-rename-done').click();assert.equal((await display()).tracks[4].name,'Track 5','empty names retain stable track identity');
 await button('stage-aux').click();assert.equal(await page.getByRole('dialog',{name:'Backing & click'}).count(),1);
 await button('stage-mix:Backing:level').fill('0.35');assert.equal((await state()).rig.expressionMix.Backing.level,.35);assert.equal(await button('stage-mix:Backing:level').evaluate(e=>e.style.getPropertyValue('--amount')),'35%','touch fill matches the auxiliary range');await button('stage-aux-done').click();await button('stage-aux').click();assert.equal(await button('stage-mix:Backing:level').evaluate(e=>e.style.getPropertyValue('--amount')),'35%','reopening preserves the same visual level');
 await button('stage-mix:Click:pan').fill('0.25');assert.equal((await state()).rig.expressionMix.Click.pan,.25);
 await button('stage-mix:Click:pan').focus();await page.evaluate(()=>segnoDemo.press());await page.evaluate(()=>segnoDemo.turn(4));assert.equal((await state()).rig.expressionMix.Click.pan,.29);
 await page.keyboard.press('Escape');assert.equal((await state()).rig.expressionMix.Click.pan,.25);
 await button('stage-mix:Click:pan').dblclick();assert.equal((await state()).rig.expressionMix.Click.pan,.5);
 if(kind==='chrome'){fs.mkdirSync('docs/design/closure-previews',{recursive:true});await screen().screenshot({path:'docs/design/closure-previews/mixer-sources.png'});}
 await button('stage-aux-done').click();assert.equal((await display()).bank,1);
 await button('stage-bank').click();await button('stage-fx:0').click();await button('stage-solo:0').click();assert.equal((await display()).tracks[0].solo,true);
 const rack=page.locator('[data-action^="rack:"]').first();await rack.click();assert.equal(await button('stage-solo:0').count(),1);await button('stage-solo:0').click();assert.equal((await display()).tracks[0].solo,false);
 assert.deepEqual((await state()).trackPlayback,before.trackPlayback);await button('back').click();await button('back').click();assert.equal((await display()).displayView,'mixer');
 await page.evaluate(()=>localStorage.setItem('segno-fx-factory-design-2026-09-06-channels',JSON.stringify({...segnoDemo.snapshot().rig,trackLabels:segnoDemo.snapshot().trackLabels})));
 await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?canvas=actual');assert.equal((await state()).rig.expressionMix.Backing.level,.35);
 await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review=loop-timing&canvas=actual');
 await button('loop:tempo-step:fine').click();await button('loop:tempo').focus();await page.evaluate(()=>segnoDemo.press());const bpm=(await state()).rig.loopSettings.tempo;await page.evaluate(()=>segnoDemo.turn(3));assert.equal((await state()).rig.loopSettings.tempo,Math.round((bpm+.03)*100)/100);await page.keyboard.press('Escape');assert.equal((await state()).rig.loopSettings.tempo,bpm);
 await button('loop:tempo').fill('93.27');assert.equal((await state()).rig.loopSettings.tempo,93.27);
 if(kind==='chrome')await screen().screenshot({path:'docs/design/closure-previews/fine-tempo.png'});
 assert.deepEqual(errors,[]);console.log(kind+': heading rename/cancel/fallback, shared backing/click, encoder rollback/default, FX Solo/return and fine BPM pass.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
