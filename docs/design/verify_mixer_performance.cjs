// Silent UI behavior checks; audio and appliance verification remain separate.
const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await (kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const p=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
  p.on('pageerror',e=>errors.push(e.message));
  const base='http://127.0.0.1:8768/fx-ux-prototype.html';
  const button=id=>p.locator('[data-action='+JSON.stringify(id)+']'),foot=id=>button('perform:'+id);
  const snap=()=>p.evaluate(()=>segnoDemo.snapshot()),mix=async()=>(await snap()).performance.mixer;
  const channel=async id=>(await mix()).channels.find(c=>c.id===id);
  const hold=async id=>{await foot(id).focus();await p.keyboard.down(' ');await p.waitForTimeout(850);await p.waitForFunction(()=>document.querySelectorAll('.hold-pending').length===0,{},{timeout:2000});};
  await p.goto(base+'?review=performance-custom&canvas=actual');await foot(7).click();assert.equal((await snap()).performance.view,'mixer');assert.equal((await mix()).selected,'Track 1');
  await p.goto(base+'?review=performance-mixer&canvas=actual');
  await foot(5).click();await foot(8).click();assert.equal((await channel('Track 1')).level,80);assert.equal((await channel('Track 2')).level,70);assert.equal((await channel('Track 2')).muted,true,'level does not unmute');
  await foot(5).click();assert.equal((await mix()).selected,'Track 2','selecting again does not deselect');
  await hold(5);await p.keyboard.up(' ');assert.equal((await channel('Track 2')).muted,false);assert.equal((await mix()).selected,'Track 2','hold does not change selection');assert.equal((await channel('Track 2')).level,70);
  await foot(9).click();assert.equal((await mix()).selected,'Track 5');assert.equal((await mix()).page,1);await foot(2).click();assert.equal((await channel('Track 5')).level,85);
  await hold(8);await p.keyboard.up(' ');assert.equal((await channel('Track 5')).level,100);assert.equal((await channel('Track 2')).level,70,'reset only selected channel');
  await foot(4).focus();await p.keyboard.down(' ');await foot(9).click();await p.waitForTimeout(850);await p.keyboard.up(' ');assert.equal((await channel('Track 1')).muted,true,'pending hold follows new bank');assert.equal((await channel('Track 5')).muted,false);
  await foot(8).focus();await p.keyboard.down(' ');await p.evaluate(()=>dispatchEvent(new Event('blur')));await p.keyboard.up(' ');assert.equal((await channel('Track 1')).level,80);
  await foot(2).click();await foot(8).focus();await p.keyboard.down(' ');await foot(3).click();await p.waitForTimeout(850);await p.keyboard.up(' ');assert.equal((await snap()).performance.view,'tracks');assert.equal((await channel('Track 1')).level,75);
  await foot(3).click();assert.equal((await snap()).performance.view,'mute');assert.equal((await snap()).performance.muted[0],true);await foot(4).click();assert.equal((await channel('Track 1')).muted,false);
  await p.goto(base+'?review=performance-mixer-empty&canvas=actual');assert.equal((await mix()).selected,null);assert.equal(await foot(2).isDisabled(),true);assert.equal(await foot(8).isDisabled(),true);assert.equal(await foot(7).isDisabled(),true);await hold(9);await p.keyboard.up(' ');assert.equal((await mix()).kind,'inputs','inputs available with empty recordings');
  await p.goto(base+'?review=performance-mixer-limit&canvas=actual');await foot(8).click();assert.equal((await channel('Track 1')).level,200);await hold(2);await p.keyboard.up(' ');assert.equal((await channel('Track 1')).level,100);
  await p.evaluate(()=>{segnoDemo.setPlayback('Track 1',true);segnoDemo.setPlayback('Track 2',true);});await foot(1).click();assert.equal((await snap()).trackPlayback['Track 1'],false);await foot(0).click();assert.equal((await snap()).rig.lastTrackPedalEvent.track,'Track 1');
  // Input level and mute affect the live monitor, not capture, track playback or FX settings.
  await p.goto(base+'?review=performance-mixer-inputs&canvas=actual');await p.evaluate(()=>{segnoDemo.setCapture('Track 1','recording');segnoDemo.setPlayback('Track 2',true);});const before=await snap();await foot(2).click();await hold(4);await p.keyboard.up(' ');assert.equal((await channel('Guitar')).level,70);assert.equal((await channel('Guitar')).muted,true);const after=await snap();assert.deepEqual(after.captureState,before.captureState);assert.deepEqual(after.trackPlayback,before.trackPlayback);assert.deepEqual(after.rig.racks,before.rig.racks);assert.equal(after.rig.expressionMix['Track 1'].level,.8);assert.equal(after.monitorResolved.Guitar,false);
  await hold(9);await p.keyboard.up(' ');assert.equal((await mix()).kind,'tracks');assert.equal((await mix()).page,0,'held bank only switches source kind');await button('mixer:inputs').click();assert.equal((await channel('Guitar')).muted,true);
  await hold(4);await p.keyboard.up(' ');assert.equal((await snap()).monitorResolved.Guitar,true);assert.equal((await channel('Guitar')).level,70);
  await p.goto(base+'?review=performance-mixer-auto&canvas=actual');assert.equal((await channel('Guitar')).status,'Auto · Live off');await p.evaluate(()=>segnoDemo.setCapture('Track 1','armed'));assert.equal((await channel('Guitar')).status,'');await hold(4);await p.keyboard.up(' ');assert.equal((await snap()).monitorResolved.Guitar,false);await p.evaluate(()=>segnoDemo.setCapture('Track 1','idle'));await hold(4);await p.keyboard.up(' ');assert.equal((await channel('Guitar')).status,'Auto · Live off','unmute preserves Auto policy');
  await p.goto(base+'?review=performance-mixer-many-inputs&canvas=actual');assert.equal((await mix()).page,4);assert.equal((await mix()).selected,'Input 17');assert.equal(await foot(6).isDisabled(),true);await foot(5).click();await foot(2).click();assert.equal((await channel('Input 18')).level,95);await foot(9).click();assert.equal((await mix()).page,0);
  await foot(4).focus();await p.keyboard.down(' ');await button('mixer:tracks').click();await p.waitForTimeout(850);await p.keyboard.up(' ');assert.equal((await channel('Track 1')).muted,false,'switching source type cancels a pending hold');
  // Expression and Mixer share the existing gain owner.
  await p.goto(base+'?review=expression&canvas=actual');await button('expr:add').click();await button('expr:kind:tracks').click();await button('expr:destination:Track%201').click();await p.locator('[data-action^="expr:target:"]').filter({hasText:'Volume'}).first().click();await button('expr:save').click();await p.evaluate(()=>segnoDemo.expressionInput(0,.4));assert.equal((await channel('Track 1')).level,80);
  await button('stage').click();await hold(3);await p.keyboard.up(' ');await foot(7).click();await foot(8).click();assert.equal((await channel('Track 1')).level,85);await p.evaluate(()=>segnoDemo.expressionInput(0,.5));assert.equal((await channel('Track 1')).level,100);
  await p.goto(base+'?canvas=actual');await p.evaluate(()=>localStorage.clear());await p.reload();await button('stage').click();await hold(3);await p.keyboard.up(' ');await foot(7).click();await foot(2).click();await hold(4);await p.keyboard.up(' ');await button('mixer:inputs').click();await foot(2).click();await hold(4);await p.keyboard.up(' ');await p.reload();assert.equal((await channel('Track 1')).level,95);assert.equal((await channel('Track 1')).muted,true);assert.equal((await snap()).rig.expressionMix.Guitar.level,.95);assert.equal((await snap()).rig.mutedInputs.Guitar,true);assert.equal((await snap()).performance.view,'tracks');
  for(const review of ['performance-mixer','performance-mixer-bank','performance-mixer-empty','performance-mixer-inputs','performance-mixer-many-inputs','performance-mixer-auto']){
   await p.goto(base+'?review='+review+'&canvas=actual');await p.evaluate(()=>document.fonts.ready);
   const bad=await p.evaluate(()=>[...document.querySelectorAll('#screen button,.mixer-overview')].filter(e=>{const r=e.getBoundingClientRect();return r.x<0||r.y<0||r.right>1921||r.bottom>1081||e.scrollWidth>e.clientWidth+2||e.scrollHeight>e.clientHeight+2;}).map(e=>e.textContent));assert.deepEqual(bad,[]);
   if(kind==='chrome'){fs.mkdirSync('docs/design/mixer-previews',{recursive:true});await p.locator('#screen').screenshot({path:'docs/design/mixer-previews/'+review+'.png'});}
  }
  assert.deepEqual(errors,[]);console.log(kind+': Mixer single selection, input/track scope, level/mute, banks, gestures, Auto monitor, expression gain, persistence and layout passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
