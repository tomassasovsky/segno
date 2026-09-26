const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict');
const path=require('node:path');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await(kind==='chrome'?chromium:firefox).launch(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{});
 try{
 const page=await browser.newPage({viewport:{width:1920,height:1200}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 const a=id=>page.locator(`[data-action=${JSON.stringify(id)}]`),snap=()=>page.evaluate(()=>segnoDemo.snapshot()),inst=()=>page.evaluate(()=>instrumentDemo.snapshot());
 await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?simulate=1');
 const meter=await page.locator('.stage-meter-fill').first().evaluate(el=>{const a=el.getBoundingClientRect(),b=el.parentElement.getBoundingClientRect();return {left:a.left-b.left,width:a.width-b.width};});assert.ok(Math.abs(meter.left)<1&&Math.abs(meter.width)<1,'whole-track meter fills column');
 await a('settings').click();await a('route:open').click();await a('route:instruments').click();
 await a('controller:keys').click();await page.keyboard.press('a');assert.deepEqual((await inst()).activeNotes,[]);
 await a('controller:keys').click();await page.keyboard.down('a');await page.waitForFunction(()=>instrumentDemo.snapshot().activeNotes.length===1);await a('controller:keys').click();assert.deepEqual((await inst()).activeNotes,[]);await page.keyboard.up('a');
 await a('controller:keys').click();await page.keyboard.down('a');
 await page.evaluate(()=>instrumentDemo.receiveMidi({device:'usb',channel:1,kind:'note',number:72,value:100}));
 await page.waitForFunction(()=>instrumentDemo.snapshot().heldNotes.length===2);
 await a('controller:keys').click();assert.deepEqual((await inst()).heldNotes,[72],'disabling computer keys preserves MIDI notes');await page.keyboard.up('a');
 await page.evaluate(()=>instrumentDemo.receiveMidi({device:'usb',channel:1,kind:'note',number:72,value:0}));
 await page.locator('.play-surface [data-note="60"]').focus();await page.keyboard.down('Enter');
 await page.waitForFunction(()=>instrumentDemo.snapshot().heldNotes.includes(60));await page.keyboard.up('Enter');
 await page.evaluate(()=>instrumentDemo.receiveMidi({device:'usb',channel:1,kind:'cc',number:64,value:127}));
 await page.evaluate(()=>instrumentDemo.receiveMidi({device:'usb',channel:1,kind:'note',number:72,value:100}));
 await page.waitForFunction(()=>instrumentDemo.snapshot().heldNotes.includes(72));
 await page.evaluate(()=>instrumentDemo.receiveMidi({device:'usb',channel:1,kind:'note',number:72,value:0}));
 assert.deepEqual((await inst()).sustainedNotes,[72]);
 await page.evaluate(()=>segnoDemo.dispatchMapping('command:cut-sound','instrument-review'));
 assert.deepEqual((await inst()).activeNotes,[],'global Cut sound includes instrument sustain');assert.equal((await inst()).sustainActive,false);
 await a('controller:midi').click();await page.evaluate(()=>instrumentDemo.receiveMidi({device:'usb',channel:1,kind:'note',number:60,value:100}));assert.deepEqual((await inst()).activeNotes,[]);
 assert.equal(await a('controller:foot').count(),0,'foot setup belongs to the shared editor');
 const mappingBefore=(await inst()).state.instruments[0];await page.reload();await a('settings').click();await a('route:open').click();await a('route:instruments').click();assert.deepEqual((await inst()).state.instruments[0],mappingBefore);
 await a('maps').click();assert.equal((await inst()).modal.type,'maps');assert.equal(await page.locator('.mapping-row').count(),13);await a('cancel').click();
 await a('remove').click();await a('cancel').click();assert.equal((await inst()).state.instruments.length,2);
 await a('add').click();await a('sound-use').click();const id=(await inst()).state.selected;
 await a('outputs').click();await a('route:tab:record').click();await a('route:track:Track 4').click();await a('route:input:'+id).click();await a('route:instruments').click();
 await page.evaluate(id=>segnoDemo.setCapture('Track 4','recording'),id);await a('remove').click();await a('remove-confirm').click();assert.ok((await snap()).liveInputs.includes(id));assert.match(await page.locator('.toast').textContent(),/Finish recording/);await a('cancel').click();await page.evaluate(()=>segnoDemo.setCapture('Track 4','idle'));
 const recorded=(await snap()).recordedParts;await a('remove').click();await a('remove-confirm').click();assert.ok(!(await snap()).liveInputs.includes(id));assert.ok(!(await snap()).recordingInputs['Track 4'].includes(id));assert.deepEqual((await snap()).recordedParts,recorded);
 for(let n=0;n<2;n++){await a('remove').click();await a('remove-confirm').click();}
 assert.equal((await inst()).state.instruments.length,0);await page.keyboard.press('a');await page.locator('#instrument-midi-pad').click();assert.deepEqual((await inst()).activeNotes,[]);
 await page.reload();await a('settings').click();await a('route:open').click();await a('route:instruments').click();assert.equal((await inst()).state.instruments.length,0);
 await a('add').click();await a('family:Strings').click();await a('sound-pick:cello').click();await a('sound-use').click();assert.equal((await inst()).state.instruments[0].type,'cello');
 await page.evaluate(()=>Storage.prototype.setItem=()=>{throw Error('quota');});await a('remove').click();await a('remove-confirm').click();assert.equal((await inst()).state.instruments.length,1);await a('cancel').click();
 await page.setViewportSize({width:1280,height:900});await page.screenshot({path:path.join(__dirname,'virtual-instrument-previews',kind+'-managed.png')});
 assert.deepEqual(errors,[]);console.log(kind+': whole-track meter, controller enable/disable, release and persistence, direct mapping editor, removal/cancel/active-capture protection, empty library, add after empty and failed removal passed');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
