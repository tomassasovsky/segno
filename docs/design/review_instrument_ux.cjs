const {chromium}=require('playwright');
const fs=require('node:fs');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.ATLAS_CHROME});
 try {
  const page=await browser.newPage({viewport:{width:1920,height:1200}});
  const a=id=>page.locator(`[data-action=${JSON.stringify(id)}]`);
  const snap=()=>page.evaluate(()=>instrumentDemo.snapshot());
  await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review=instruments');
  const result={};
  await a('midi').click(); await page.screenshot({path:'/tmp/segno-instrument-midi-review.png'});
  await a('map-midi').click();await a('map-learn').click();
  await page.locator('#instrument-midi-pad').click();
  await page.locator('.mapping-target [data-note="60"]').click({position:{x:12,y:110}});
  await a('map-keep').click();await a('maps-save').click();await a('cancel').click();
  result.midiMappingsAfterOuterCancel=(await snap()).state.instruments[0].mappings.length;
  await a('controller:keys').click();
  await page.locator('.play-surface [data-note="60"]').focus();await page.keyboard.down('Enter');await page.waitForTimeout(150);
  result.onscreenKeyboardWithComputerKeysOff=(await snap()).heldNotes;await page.keyboard.up('Enter');
  await a('rename').click();await page.getByRole('textbox',{name:'Instrument name'}).fill('Long layered electric piano for verse');await a('name-save').click();
  result.instrumentHeader=await page.locator('.instrument-head').evaluate(el=>{const r=el.getBoundingClientRect();return [...el.children].map(e=>{const b=e.getBoundingClientRect();return {text:e.textContent,rightOverflow:b.right>r.right+1,height:b.height,width:b.width};});});
  await page.screenshot({path:'/tmp/segno-instrument-long-name-review.png'});
  await a('button').click();for(let n=0;n<85;n++)await a('note:1').click();result.highestFootNote=(await snap()).modal.note;await a('cancel').click();
  fs.writeFileSync('/tmp/segno-instrument-ux-observations.json',JSON.stringify(result,null,2));console.log(JSON.stringify(result,null,2));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
