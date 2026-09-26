// Isolated browser verification using the current prototype's shared styles.
const {chromium}=require('playwright');
const fs=require('node:fs');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.SEGNO_CHROME_EXECUTABLE||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 const main=fs.readFileSync(__dirname+'/fx-ux-prototype.html','utf8'),style=main.match(/<style>([\s\S]*?)<\/style>/)[1];
 await page.setContent('<style>'+style+fs.readFileSync(__dirname+'/midi-sync-study.css','utf8')+fs.readFileSync(__dirname+'/appliance-parity-study.css','utf8')+'</style><div class="screen"><header class="topbar">SETTINGS</header><main class="main sync-study"></main></div>');
 for(const f of ['midi-sync-study.js','appliance-reference-notices.js','appliance-parity-study.js'])await page.addScriptTag({content:fs.readFileSync(__dirname+'/'+f,'utf8')});
 await page.evaluate(()=>{
  const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const b=(id,text,cls='quiet',extra='')=>`<button data-action="${id}" class="${cls}" ${extra}>${text}</button>`;
  window.mode='sync';window.syncSettings={};window.clock=0;
  window.draw=()=>{const main=document.querySelector('main');main.className='main '+(mode==='sync'?'sync-study':'appliance-study');main.innerHTML=(mode==='sync'?sync:appliance).body();};
  window.sync=window.createMidiSyncStudy({read:()=>syncSettings,write:s=>{syncSettings=s;return true;},ports:()=>[{id:'din',name:'MIDI DIN',connection:'DIN',online:true},{id:'usb',name:'USB controller',connection:'USB',online:true},{id:'usb2',name:'USB keyboard',connection:'USB',online:true}],tempo:()=>120,setTempo:()=>{},capturing:()=>false,transport:()=>{},running:()=>false,clockReady:()=>{},render:draw,focus:()=>{},button:b,escape:esc,now:()=>clock});
  window.appliance=window.createApplianceParityStudy({button:b,header:t=>`<div class="titlebar"><h1>${t}</h1></div>`,escape:esc,render:draw,focus:()=>{},open:()=>{mode='appliance';},facts:()=>({name:'Segno preview',appVersion:'1.0.0 simulated'}),readController:()=>({connected:true,target:'simulated-console',updateSupported:true,installed:'1.0.0',protocol:3,versionSource:'last-flashed',pending:{version:'1.1.0',protocol:4,target:'simulated-console',verified:true}}),writeController:()=>true,restart:r=>r.onRestart(),active:()=>mode==='appliance',now:()=>clock});
  document.addEventListener('click',e=>{const t=e.target.closest('[data-action]');if(t){if(mode==='sync')sync.action(t.dataset.action);else appliance.action(t.dataset.action);}});
  document.addEventListener('input',e=>{if(e.target.matches('input[type=range]'))sync.input(e.target.dataset.action,e.target.value,document);});draw();
 });
 await page.locator('[data-action="sync:output-clock:din"]').click();
 await page.locator('[data-action="sync:offset:din"]').evaluate(e=>{e.value=-7;e.dispatchEvent(new Event('input',{bubbles:true}));});
 assert.equal(await page.locator('[data-sync-offset="din"]').textContent(),'-7 ms');
 await page.locator('[data-action="sync:thru"]').click();assert.ok(await page.locator('[data-action="sync:output-clock:din"]').isDisabled());assert.equal(await page.locator('[data-action="sync:thru"]').textContent(),'On');
 assert.equal(await page.evaluate(()=>sync.receiveMessage('din',{kind:'note',note:60,value:100},20)),true);
 await page.locator('[data-action="sync:source:usb"]').click();assert.ok(await page.locator('[data-action="sync:offset:usb2"]').isDisabled());
 assert.ok(await page.getByText('Timing simulation · no MIDI messages are sent to hardware.').isVisible());
 const overflow=await page.locator('main').evaluate(e=>({scroll:e.scrollHeight,client:e.clientHeight}));assert.ok(overflow.scroll<=overflow.client+2,JSON.stringify(overflow));
 if(process.env.SEGNO_APPLIANCE_SCREENSHOT)await page.screenshot({path:process.env.SEGNO_APPLIANCE_SCREENSHOT+'-sync.png'});
 await page.evaluate(()=>{mode='appliance';draw();});assert.ok(await page.getByText('Last flashed by this console').isVisible());
 await page.getByRole('button',{name:'Open-source notices'}).click();await page.getByRole('button',{name:'Segno Read'}).click();assert.ok(await page.getByText('GNU GENERAL PUBLIC LICENSE',{exact:false}).isVisible());
 await page.evaluate(()=>{appliance.enter('controller');draw();});await page.getByRole('button',{name:'Restart to finish update'}).click();assert.ok(await page.getByRole('progressbar').isVisible());assert.equal(await page.evaluate(()=>appliance.busy()),true);
 await page.evaluate(()=>{clock=4300;appliance.tick();});assert.ok(await page.getByRole('heading',{name:'Controller updated'}).isVisible());assert.equal(await page.evaluate(()=>appliance.snapshot().controller.installed),'1.1.0');
 if(process.env.SEGNO_APPLIANCE_SCREENSHOT)await page.screenshot({path:process.env.SEGNO_APPLIANCE_SCREENSHOT+'-controller.png'});
 assert.deepEqual(errors,[]);process.stdout.write('PASS: clock-offset touch, DIN Thru ownership, external-offset guard, sync canvas bounds, About source label, exact license text, controller restart/progress/verified completion; no browser errors.\n');await browser.close();
})().catch(e=>{process.stderr.write(e.stack+'\n');process.exit(1);});
