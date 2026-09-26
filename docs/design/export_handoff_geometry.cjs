// Refresh accepted display references without changing prototype state or assets.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path');
const geometry=require('./prototype-geometry.cjs');
async function capture(page,name){
  await page.evaluate(()=>document.fonts.ready);
  const nodes=await geometry(page);
  fs.writeFileSync(path.join(__dirname,'primary-crown-previews',name+'.json'),JSON.stringify(nodes));
  await page.locator('#screen').screenshot({path:path.join(__dirname,'primary-crown-previews',name+'.png')});
  console.log(name,nodes.length);
}
(async()=>{
  const browser=await chromium.launch({executablePath:process.env.ATLAS_CHROME});
  try {
    const page=await browser.newPage({viewport:{width:1920,height:1080}});
    for(const [name,scene] of [['track','stage-layout'],['wave','stage-layout-wave'],['mixer','stage-layout-mixer']]){
      await page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review='+scene+'&canvas=actual');
      await page.waitForFunction(()=>window.segnoDemo?.displayState());
      await capture(page,name);
    }
    await page.goto('http://127.0.0.1:8768/stage-two-screen-preview.html?canvas=small');
    await page.waitForFunction(()=>!document.querySelector('#track-primary').hidden);
    await page.evaluate(()=>{document.querySelector('#screen').style.transform='none';});
    await capture(page,'selected-track');
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
