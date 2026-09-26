// Isolated browser behavior checks, using the existing prototype styles.
const {chromium}=require('playwright');
const fs=require('node:fs');
const assert=require('node:assert/strict');
const root=__dirname;
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.SEGNO_CHROME_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 const page=await browser.newPage({viewport:{width:1920,height:1080}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 const main=fs.readFileSync(root+'/fx-ux-prototype.html','utf8');const styles=main.match(/<style>([\s\S]*?)<\/style>/)[1];
 await page.setContent('<style>'+styles+'\n'+fs.readFileSync(root+'/fx-parity.css','utf8')+'\n'+fs.readFileSync(root+'/media-closure-study.css','utf8')+'</style><div class="screen" style="width:1920px;height:1080px;position:relative"><main class="main"></main><div id="overlay"></div></div>');
 for(const file of ['looperx-factory/catalog.js','fx-parameter-descriptors.js','fx-parameter-controls.js','fx-preset-library.js','media-closure-study.js'])await page.addScriptTag({content:fs.readFileSync(root+'/'+file,'utf8')});
 await page.evaluate(()=>{
  const p=window.LOOPERX_FACTORY.families.find(f=>f.name==='Guitar Rack').presets[0];
  window.saved=[{name:p.name,family:'Guitar Rack',artwork:'guitar',original:p.raw,modules:[{name:'Amp',sourceValues:true,sourceFamily:'Guitar Rack',params:Object.entries(p.parameters).filter(([k])=>k.startsWith('Amp')).map(([k,v])=>[k,v,'',v])}],channels:{input:'stereo',output:'stereo',pan:['Pan',.5,'',.5]}}];
  const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const b=(id,text,cls='quiet',extra='')=>`<button data-action="${id}" class="${cls}" ${extra}>${text}</button>`;
  const render=()=>{document.querySelector('main').innerHTML=window.ui.body();document.querySelector('#overlay').innerHTML=window.ui.overlay();};
  window.media=SegnoMediaClosure.createPresetInterchange({button:b,escape:esc,render,focus:()=>{},media:()=>({usbConnected:true,job:null})});
  window.ui=window.createFxPresetLibraryStudy({media:window.media,read:()=>saved,write:n=>{saved=n;return true;},button:b,escape:esc,header:(title,detail,actions)=>`<div class="titlebar"><h1>${title}</h1>${actions}</div>`,artwork:()=>'',render,focus:()=>{},notice:()=>{},icon:()=>'',load:()=>{}});
  document.addEventListener('click',e=>{const a=e.target.closest('[data-action]');if(a)ui.action(a.dataset.action);});render();
 });
 await page.getByRole('button',{name:'Rename',exact:true}).click();
 const box=await page.locator('.keyboard-sheet').boundingBox();assert.equal(Math.round(box.y+box.height),1080);
 await page.locator('[data-action="fxpresets:key:clear"]').click();await page.locator('[data-action="fxpresets:key:V"]').click();await page.getByRole('button',{name:'Save name'}).click();assert.equal(await page.evaluate(()=>saved[0].name),'V');
 await page.getByRole('button',{name:'Export',exact:true}).click();await page.locator('[data-action="mediafx:location:usb"]').click();await page.locator('[data-action="mediafx:transfer"]').click();await page.waitForFunction(()=>media.snapshot().files.length===1);
 const exported=await page.evaluate(()=>media.snapshot().files[0]);assert.equal(JSON.parse(exported.text).presets[0].name,'V');assert.equal(exported.location,'usb');
 await page.getByRole('button',{name:'Import presets',exact:true}).click();await page.locator('[data-action="mediafx:location:usb"]').click();await page.locator('[data-action="mediafx:file:'+exported.id+'"]').click();await page.locator('[data-action="mediafx:transfer"]').click();await page.waitForFunction(()=>ui.snapshot().modal?.type==='import');
 await page.getByRole('dialog',{name:'Import presets'}).waitFor();assert.equal(await page.evaluate(()=>saved.length),1);
 await page.getByRole('dialog').getByRole('button',{name:'Import presets'}).click();assert.equal(await page.evaluate(()=>saved.length),2);assert.equal(await page.evaluate(()=>saved[1].name),'V (2)');
 await page.locator('[data-action="fxpresets:delete:0"]').click();await page.getByRole('button',{name:'Delete preset'}).click();assert.equal(await page.evaluate(()=>saved.length),1);await page.getByRole('button',{name:'Undo delete'}).click();assert.equal(await page.evaluate(()=>saved.length),2);
 await page.evaluate(()=>{const m=saved[0].modules[0];document.querySelector('main').innerHTML='<div class="single-effect-fields">'+m.params.map((p,i)=>SegnoFxControls.render(m,0,p,i)).join('')+'</div>';document.querySelector('#overlay').innerHTML='';});
 assert.equal(await page.locator('[data-fx-type="switch"]').count(),1);assert.equal(await page.locator('[data-fx-type="unresolved"]').count(),4);assert.ok(await page.getByText('Amp Modern',{exact:true}).isVisible());
 if(process.env.SEGNO_FX_SCREENSHOT)await page.screenshot({path:process.env.SEGNO_FX_SCREENSHOT});assert.deepEqual(errors,[]);process.stdout.write('PASS: appliance USB preset chooser/export, review before import, keyboard anchoring, rename, delete/undo, Amp Modern visibility, switch/source controls; no browser errors.\n');await browser.close();
})().catch(e=>{process.stderr.write(e.stack+'\n');process.exit(1);});
