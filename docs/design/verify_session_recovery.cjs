// Author browser proof. Media, interface and audio remain simulated.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const base=process.env.FX_PROTOTYPE_URL||'http://127.0.0.1:8768/fx-ux-prototype.html';
const output=path.join(__dirname,'session-recovery-previews');
(async()=>{for(const kind of ['chrome','firefox']){
  const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}:{})});
  try{
    const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
    page.setDefaultTimeout(6000);page.on('pageerror',e=>errors.push(e.message));
    const button=id=>page.locator('[data-action='+JSON.stringify(id)+']'),click=id=>button(id).click();
    const state=()=>page.evaluate(()=>segnoDemo.snapshot()),recovery=async()=>(await state()).sessions.recovery;
    const open=async scene=>{await page.goto(base+'?review='+scene+'&canvas=actual');await page.waitForFunction(()=>window.segnoDemo);await page.evaluate(()=>document.fonts.ready);};
    const shot=async name=>{fs.mkdirSync(output,{recursive:true});if(kind==='chrome')await page.locator('#screen').screenshot({path:path.join(output,name+'.png')});};
    const bounds=async()=>{assert.deepEqual(await page.locator('.recovery-panel button:not([disabled]),.recovery-footer,.recovery-heading').evaluateAll(els=>{const s=document.querySelector('#screen').getBoundingClientRect();return els.filter(e=>{const r=e.getBoundingClientRect();return r.left<s.left+4||r.top<s.top||r.right>s.right-4||r.bottom>s.bottom;}).map(e=>e.textContent);}),[]);};
    const repair=async()=>{await click('recover:choose:missing-loop');await shot('session-recovery-files');await click('recover:file:inside-9');await click('recover:choose:missing-backing');await click('recover:file:inside-1');};
    await open('session-recovery');const before=await state();assert.equal((await recovery()).problems.length,2);assert(await button('recover:open').isDisabled());await bounds();await shot('session-recovery');
    await repair();assert.equal((await recovery()).problems.length,0);assert.deepEqual((await state()).rig,before.rig);assert.deepEqual((await state()).recordedParts,before.recordedParts);await shot('session-recovery-ready');
    await click('recover:cancel');assert.deepEqual((await state()).rig,before.rig);assert.equal((await state()).focusId,'session:load');await click('session:load');assert.equal((await recovery()).problems.length,2);
    await repair();await page.evaluate(()=>segnoDemo.simulateSession({full:true}));await click('recover:open');assert.match((await recovery()).error,/Could not save/);assert.deepEqual((await state()).rig,before.rig);await shot('session-recovery-error');
    await page.evaluate(()=>segnoDemo.simulateSession({full:false}));await click('recover:open');let opened=await state();assert.equal(opened.page,'stage');assert.equal(opened.rig.sessionLibrary.current.name,'Evening set');assert.equal(opened.rig.audioLibrary.trackImports[0].file.id,'inside-9');assert.deepEqual(opened.rig.audioLibrary.prepared,['inside-1']);assert.equal(opened.rig.audioLibrary.backing.id,'inside-1');assert.equal(opened.rig.sessionLibrary.sessions[0].id,before.rig.sessionLibrary.current.id);
    // Persist a defective session then exercise the real storage writer and reload.
    await page.evaluate(rig=>localStorage.setItem('segno-fx-factory-design-2026-09-06-channels',JSON.stringify(rig)),before.rig);
    await page.goto(base+'?canvas=actual');await click('session:library');await click('session:row:session-2');await click('session:load');await repair();
    await page.evaluate(()=>{window.recoveryWriter=Storage.prototype.setItem;Storage.prototype.setItem=()=>{throw new DOMException('Simulated failure','QuotaExceededError');};});await click('recover:open');assert.match((await recovery()).error,/Could not save/);assert.equal((await state()).rig.sessionLibrary.current.id,'session-1');
    await page.evaluate(()=>Storage.prototype.setItem=window.recoveryWriter);await click('recover:open');await page.reload();assert.equal((await state()).rig.sessionLibrary.current.name,'Evening set');assert.equal((await state()).rig.audioLibrary.trackImports[0].file.id,'inside-9');
    // An unavailable interface leads to existing setup and returns to the draft.
    await open('session-recovery-ready');await page.evaluate(()=>segnoDemo.simulateDevice({id:'stage',online:false}));assert(await button('recover:open').isDisabled());await bounds();await shot('session-recovery-device');await click('recover:device');assert.equal((await state()).page,'audio-device');await page.evaluate(()=>segnoDemo.simulateDevice({id:'stage',online:true}));await click('device:apply');await click('back');assert.equal((await state()).page,'sessions');assert.equal((await recovery()).problems.length,0);assert(!(await button('recover:open').isDisabled()));
    // Encoder and Escape use the same controls, preserving all draft edits on picker Back.
    await open('session-recovery');await page.evaluate(()=>{segnoDemo.turn(1);segnoDemo.press();});assert((await recovery()).choosing);await page.keyboard.press('Escape');assert.equal((await recovery()).choosing,null);await page.keyboard.press('Escape');assert.equal((await recovery()).draft,null);
    await open('session-recovery-ready');await click('stage');await click('session:library');assert.equal((await recovery()).draft,null);assert.equal(await button('session:load').count(),1);
    await open('session-recovery');const encoder=async id=>page.evaluate(id=>{for(let n=0;n<40&&segnoDemo.snapshot().focusId!==id;n++)segnoDemo.turn(1);if(segnoDemo.snapshot().focusId!==id)throw Error('Encoder cannot reach '+id);segnoDemo.press();},id);
    for(const id of ['recover:choose:missing-loop','recover:file:inside-9','recover:choose:missing-backing','recover:file:inside-1','recover:open'])await encoder(id);assert.equal((await state()).page,'stage');assert.equal((await state()).rig.sessionLibrary.current.name,'Evening set');assert.deepEqual(errors,[]);
    console.log(kind+': pending repair, exact import duration, Cancel, save failure/retry, reload, device setup/return, encoder and bounds passed.');
  }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
