const {chromium,firefox}=require('playwright');
const assert=require('node:assert/strict'),fs=require('node:fs');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{
 const p=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];p.on('pageerror',e=>errors.push(e.message));
 const base='http://127.0.0.1:8768/fx-ux-prototype.html',b=id=>p.locator('[data-action='+JSON.stringify(id)+']'),snap=()=>p.evaluate(()=>segnoDemo.snapshot());
 await p.goto(base+'?review=session-library&canvas=actual');await p.evaluate(()=>document.fonts.ready);
 assert.equal(await p.locator('.session-audio-track').count(),3);
 const paths=await p.locator('.session-audio-clip path').evaluateAll(es=>es.map(e=>e.getAttribute('d')));assert.equal(new Set(paths).size,3);assert.ok(paths.every(s=>s.length>10000));
 assert.deepEqual(await p.locator('.session-audio-clip').evaluateAll(es=>es.map(e=>e.style.width)),['50%','100%','25%']);
 assert.equal(await p.locator('.session-audio-more').isVisible(),false);
 let before=await snap();await b('session:listen').click();await p.waitForTimeout(250);assert.equal((await snap()).sessions.preview.audition,true);
 assert.equal(await p.locator('.session-audio-head:not([hidden])').count(),3);assert.ok(parseFloat(await p.locator('.session-audio-head').first().evaluate(e=>e.style.left))>0);
 let after=await snap();for(const key of ['recordedParts','trackPlayback','rig'])assert.deepEqual(after[key],before[key]);
 await b('session:location:usb').click();assert.equal((await snap()).sessions.preview.audition,false);
 await b('session:location:internal').click();await b('session:listen').click();await b('stage').click();assert.equal((await snap()).sessions.preview.audition,false);
 await b('session:library').click();await b('session:listen').click();await p.evaluate(()=>segnoDemo.setPlayback('Track 1',true));await p.waitForTimeout(180);assert.equal((await snap()).sessions.preview.audition,false);assert.equal(await b('session:listen').isDisabled(),true);
 assert.equal(await p.locator('[data-session-head="0"]').isVisible(),true);assert.equal(await p.locator('[data-session-head="1"]').isVisible(),false);
 await p.evaluate(()=>segnoDemo.setPlayback('Track 1',false));await b('session:new').click();await b('session:confirm-new').click();await b('session:library').click();assert.equal(await p.locator('.session-audio-track').count(),0);assert.equal(await b('session:listen').isDisabled(),true);
 await b('session:row:session-1').click();assert.equal(await p.locator('.session-audio-track').count(),3);assert.match(await p.locator('.session-audio-track').first().textContent(),/2 bar.*4 layer/);
 // Eight recorded tracks, a saved mute and a long title survive recall and scroll.
 await p.evaluate(()=>{const r=segnoDemo.snapshot().rig,s=r.sessionLibrary.sessions[0].snapshot;for(let i=0;i<8;i++){s.recordedParts['Track '+(i+1)]=['Guitar'];s.previewTracks[i]={bars:i+1,layers:i+1};}s.mutedTracks[1]=true;s.trackLabels['Track 2']='Long atmospheric guitar with delay and reverb';localStorage.setItem('segno-fx-factory-design-2026-09-06-channels',JSON.stringify(r));});
 await p.goto(base+'?canvas=actual');await b('stage').click();await b('session:library').click();await b('session:row:session-1').click();await p.waitForTimeout(200);
 assert.equal(await p.locator('.session-audio-track').count(),8);assert.equal(await p.locator('.session-muted[aria-label="Muted"]').count(),1);assert.equal(await p.locator('.session-audio-track.muted').count(),1);
 assert.equal(await p.locator('.session-audio-more').isVisible(),true);assert.equal(await p.locator('.session-audio-more').getAttribute('data-action'),null);
 const area=p.locator('.session-audio-scroll');await area.evaluate(e=>e.scrollTop=e.scrollHeight);await p.waitForTimeout(120);assert.equal(await p.locator('.session-audio-more').isVisible(),false);
 before=await snap();await b('session:listen').click();assert.ok(await area.evaluate(e=>e.scrollTop>0));assert.deepEqual((await snap()).recordedParts,before.recordedParts);
 if(kind==='chrome'){await b('session:listen').click();await area.evaluate(e=>e.scrollTop=0);await p.waitForTimeout(120);await p.locator('#screen').screenshot({path:'docs/design/session-library-previews/session-preview-many.png'});}
 assert.deepEqual(errors,[]);console.log(kind+': waveform recognition, saved metadata and mute, isolated audition, playback guards, empty and scrolling previews passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
