const {chromium,firefox}=require('playwright'),assert=require('node:assert/strict'),fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const p=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(7000);
  const open=review=>p.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review='+review+'&canvas=actual');
  const color=locator=>locator.evaluate(e=>({fill:getComputedStyle(e).backgroundColor,text:getComputedStyle(e).color}));
  const shot=async name=>{if(kind==='chrome'){await p.evaluate(()=>Promise.all([...document.images].map(i=>i.decode())));await p.screenshot({path:'docs/design/consistency-previews/'+name+'.png'});}};
  await open('updates-usb');assert.deepEqual(await color(p.locator('.updates-package').first()),{fill:'rgb(32, 39, 53)',text:'rgb(231, 237, 246)'});await shot('update-package-colors');
  await open('device-calibration');await p.locator('.device-test-cable').waitFor();assert.equal((await color(p.locator('.device-calibration'))).fill,'rgb(32, 39, 53)');await shot('latency-colors');
  await open('family');assert.equal((await color(p.locator('.row').first())).fill,'rgb(32, 39, 53)');await shot('rack-preset-colors');
  await open('rack-options');assert.equal((await color(p.locator('.dialog'))).fill,'rgb(32, 39, 53)');await shot('rack-options-colors');
  await open('add-effects');assert.equal(await p.locator('.my-presets-entry img').count(),1);assert.ok(await p.locator('.my-presets-entry img').evaluate(e=>e.complete&&e.naturalWidth>1000));await shot('add-effects');
  await open('parameter-scroll');assert.equal(await p.locator('.parameter-navigation,[data-action^="scroll-parameters:"]').count(),0);
  const panel=p.locator('.pedal-parameters.scrollable').first(),fields=panel.locator('.inline-fields'),bar=panel.locator('.parameter-scrollbar'),thumb=bar.locator('.parameter-scroll-thumb');
  await bar.waitFor({state:'visible'});const a=await fields.boundingBox(),b=await bar.boundingBox();assert.ok(b.x>=a.x+a.width+12,'scrollbar has its own gap');
  const first=await thumb.boundingBox();await bar.click({position:{x:b.width/2,y:b.height-4}});await p.waitForTimeout(100);assert.ok(await fields.evaluate(e=>e.scrollTop>0));assert.ok((await thumb.boundingBox()).y>first.y);assert.ok(await bar.isVisible());
  const end=await thumb.boundingBox();await p.mouse.move(end.x+end.width/2,end.y+end.height/2);await p.mouse.down();await p.mouse.move(b.x+b.width/2,b.y);await p.mouse.up();assert.equal(await fields.evaluate(e=>e.scrollTop),0);
  const last=fields.locator('[data-action]').last();await last.focus();await p.waitForTimeout(100);assert.ok(await fields.evaluate(e=>e.scrollTop>0),'encoder focus reveals lower controls');
  assert.ok(!(await p.evaluate(()=>segnoDemo.snapshot().focusId)).includes('scroll'),'scrollbar is not an encoder target');await shot('parameter-scrollbar');
  assert.deepEqual(errors,[]);console.log(kind+': picker contrast, shared FX surfaces, My presets artwork, persistent separated scrollbar, drag and focus scrolling passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
