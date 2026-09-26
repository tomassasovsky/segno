const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict'),path=require('node:path');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
  const page=await browser.newPage({viewport:{width:1920,height:1200}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const a=id=>page.locator(`[data-action=${JSON.stringify(id)}]`),snap=()=>page.evaluate(()=>segnoDemo.snapshot()),inst=()=>page.evaluate(()=>instrumentDemo.snapshot());
  const open=async()=>{await a('settings').click();await a('route:open').click();await a('route:instruments').click();};
  const turnRange=async(key,value)=>page.locator(`[data-range="${key}"]`).evaluate((el,v)=>{el.value=v;el.dispatchEvent(new Event('input',{bubbles:true}));},value);
  await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?simulate=1');
  assert.equal((await snap()).page,'stage');await open();
  assert.equal((await snap()).page,'instruments');
  assert.equal(await page.locator('.instruments-study [data-action="record"],.instruments-study .recorder,.instruments-study .track-grid').count(),0);
  const theme=await page.locator('.instruments-study').evaluate(el=>({font:getComputedStyle(el).fontFamily,host:getComputedStyle(document.querySelector('#screen')).fontFamily,panel:getComputedStyle(el.querySelector('.panel')).backgroundColor,token:getComputedStyle(document.querySelector('#screen')).getPropertyValue('--surface').trim()}));
  assert.equal(theme.font,theme.host);assert.equal(theme.panel,'rgb(32, 39, 53)');
  await a('add').click();assert.equal(await page.locator('.instrument-families button').count(),7);
  let total=0;for(const family of ['Keys','Organs','Synths','Bass','Strings','Drums','Percussion']){await a('family:'+family).click();total+=await page.locator('.instrument-sounds .sound-card').count();}
  assert.equal(total,19);await page.screenshot({path:path.join(__dirname,'virtual-instrument-previews',kind+'-library.png')});
  await a('family:Strings').click();await a('sound-pick:cello').click();await a('sound-use').click();
  const id=(await inst()).state.selected;assert.equal((await inst()).state.instruments.at(-1).type,'cello');
  assert.ok((await snap()).liveInputs.includes(id));
  await a('controller:midi').click();await a('rename').click();await page.getByRole('textbox',{name:'Instrument name'}).fill('Verse cello');await page.keyboard.press('Escape');assert.equal((await inst()).modal.type,'name');await a('name-save').click();
  await turnRange('brightness',36);await a('hear:auto').click();
  assert.equal((await snap()).liveMonitoring[id],'auto');assert.equal((await snap()).monitorResolved[id],false);
  await page.screenshot({path:path.join(__dirname,'virtual-instrument-previews',kind+'-integrated.png')});
  await a('effects').click();assert.equal((await snap()).soundInput,id);assert.equal((await snap()).page,'sounds');
  assert.equal(await a('monitor:auto').getAttribute('aria-pressed'),'true');await a('monitor:off').click();await a('back').click();assert.equal(await a('hear:off').getAttribute('aria-pressed'),'true');
  await a('outputs').click();assert.equal((await snap()).routing.source,id);await a('route:output:Monitor output').click();
  assert.deepEqual((await snap()).routing.outputs[id],['Main output','Monitor output']);
  await a('route:tab:setup').click();assert.equal(await page.locator(`[data-action="input:select:${id}"]`).count(),0,'instruments are not hardware jacks');
  assert.deepEqual((await snap()).routing.setup.members['Guitar'],['Guitar']);
  await a('route:tab:record').click();await a('route:track:Track 4').click();await a('route:input:Guitar').click();await a('route:input:'+id).click();assert.deepEqual((await snap()).recordingInputs['Track 4'],[id]);
  await page.screenshot({path:path.join(__dirname,'virtual-instrument-previews',kind+'-recording-input.png')});
  await a('stage').click();await a('settings').click();await a('loop:page:loop-settings').click();await a('loop:page:loop-mode').click();await a('loop:mode:free').click();await a('stage').click();await a('stage-track:3').click();
  const tap=async()=>{await page.evaluate(()=>segnoDemo.performanceDown(0,'instrument-test'));await page.evaluate(()=>segnoDemo.performanceUp('instrument-test'));};
  await tap();assert.ok(['armed','recording'].includes((await snap()).captureState['Track 4']));
  await page.evaluate(()=>segnoDemo.midiReceive('usb',[144,60,100]));await page.waitForFunction(()=>instrumentDemo.snapshot().voices.some(v=>v.id===instrumentDemo.snapshot().state.selected));await page.waitForFunction(()=>segnoDemo.snapshot().captureState['Track 4']==='recording');await page.waitForTimeout(400);await page.evaluate(()=>segnoDemo.midiReceive('usb',[144,60,0]));
  await tap();assert.equal((await snap()).captureState['Track 4'],'idle');assert.deepEqual((await snap()).recordedParts['Track 4'],[id]);assert.equal((await snap()).trackPlayback['Track 4'],true);
  await page.screenshot({path:path.join(__dirname,'virtual-instrument-previews',kind+'-recorded-track.png')});
  // Session ownership covers the complete instrument definition and normal routing.
  const captured=await page.evaluate(()=>segnoDemo.captureSession());assert.equal(captured.instruments.instruments.at(-1).name,'Verse cello');
  const saved=(await snap()).rig.instruments;await page.reload();assert.equal((await snap()).page,'stage');assert.deepEqual((await snap()).rig.instruments,saved);assert.deepEqual((await snap()).recordingInputs['Track 4'],[id]);
  await a('session:library').click();await a('session:new').click();await a('session:confirm-new').click();assert.deepEqual((await snap()).rig.instruments,saved);assert.deepEqual((await snap()).recordingInputs['Track 4'],[id]);
  assert.ok(Object.values((await snap()).recordedParts).every(v=>!v.length));
  await open();await turnRange('brightness',70);await a('stage').click();await a('session:library').click();await a('session:row:session-1').click();await a('session:load').click();assert.deepEqual((await snap()).rig.instruments,saved);
  await open();await page.setViewportSize({width:1280,height:900});
  const bounds=await page.locator('.instruments-study').evaluate(el=>{const r=document.querySelector('#screen').getBoundingClientRect();return [...el.querySelectorAll('.instrument,.panel')].every(e=>{const b=e.getBoundingClientRect();return b.left>=r.left&&b.right<=r.right+1&&b.bottom<=r.bottom+1;});});assert.ok(bounds);
  await page.evaluate(()=>Storage.prototype.setItem=()=>{throw Error('quota');});const before=(await snap()).rig.instruments;await turnRange('brightness',90);assert.deepEqual((await snap()).rig.instruments,before,'failed save retains original instrument');
  assert.deepEqual(errors,[]);console.log(kind+': integrated navigation, 19 sounds/7 families, shared theme/monitor/FX/output routes, normal track recording, session recall/New Loop, persistence and layout passed');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
