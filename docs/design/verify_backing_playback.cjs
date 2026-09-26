const {chromium,firefox}=require('playwright');const assert=require('node:assert/strict');
(async()=>{for(const kind of ['chrome','firefox']){
 const browser=await(kind==='chrome'?chromium:firefox).launch({headless:true,...(kind==='chrome'?{executablePath:process.env.ATLAS_CHROME}:{})});
 try{const p=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(6000);
 await p.clock.install({time:new Date('2026-09-08T02:00:00Z')});await p.clock.pauseAt(new Date('2026-09-08T02:00:01Z'));
 const base='http://127.0.0.1:8768/fx-ux-prototype.html',b=id=>p.locator('[data-action='+JSON.stringify(id)+']'),foot=id=>b('perform:'+id),snap=()=>p.evaluate(()=>segnoDemo.snapshot()),state=async()=>(await snap()).performance.backing;
 const seek=async n=>{await b('backing:seek').fill(String(n));await p.clock.runFor(80);};
 const hold=async(id,cancel=false)=>{await p.evaluate(id=>segnoDemo.performanceDown(id,'test'),id);await p.clock.runFor(cancel?100:850);await p.evaluate(cancel=>segnoDemo.performanceUp('test',cancel),cancel);};
 await p.goto(base+'?review=performance-backing&canvas=actual');const untouched=(await snap()).trackPlayback;assert.equal((await state()).end,'stop');
 await seek(60);assert.equal((await state()).position,60);assert.equal((await state()).playing,false);
 await hold(2);assert.equal((await state()).position,50);assert.equal((await state()).selected,'inside-1');
 await hold(8);assert.equal((await state()).position,60);assert.equal((await state()).selected,'inside-1');
 await hold(8,true);assert.equal((await state()).position,60);
 await hold(9);assert.equal((await state()).end,'repeat');assert.equal((await state()).page,0,'hold does not also page');
 // Encoder edits preview a position; Back cancels and press commits, retaining focus.
 await b('backing:seek').focus();await p.keyboard.press('Enter');await p.evaluate(()=>segnoDemo.turn(12));assert.equal((await state()).position,60);assert.equal((await snap()).focusId,'backing:seek');await b('back').click();assert.equal((await state()).position,60);assert.equal((await snap()).page,'stage');
 await b('backing:seek').focus();await p.keyboard.press('Enter');await p.evaluate(()=>segnoDemo.turn(12));await p.evaluate(()=>segnoDemo.press());assert.equal((await state()).position,72);
 await seek(221);await foot(0).click();await p.clock.runFor(1600);assert.equal((await state()).loaded.id,'inside-1');assert.equal((await state()).playing,true);assert.ok((await state()).position<1);
 await foot(0).click();await b('backing:end:next').click();await seek(221);await foot(0).click();await foot(6).click();await p.clock.runFor(1600);assert.equal((await state()).loaded.id,'inside-2');assert.equal((await state()).selected,'inside-3','pending manual selection is preserved');assert.equal((await state()).playing,true);
 await foot(1).click();await foot(9).click();await foot(9).click();await foot(4).click();await foot(0).click();assert.equal((await state()).loaded.id,'inside-9');await seek(23);await p.clock.runFor(1600);assert.equal((await state()).playing,false);assert.equal((await state()).loaded.id,'inside-9','Next stops at the end of the prepared list');
 assert.deepEqual((await snap()).trackPlayback,untouched);
 // Auto-next uses prepared order and moves the visible page when following loaded audio.
 await p.goto(base+'?review=performance-backing&canvas=actual');await foot(7).click();await foot(0).click();await b('backing:end:next').click();await seek(205);await p.clock.runFor(1600);assert.equal((await state()).loaded.id,'inside-5');assert.equal((await state()).selected,'inside-5');assert.equal((await state()).page,1);
 // Save/reload and session recall retain the end setting, with playback stopped.
 await p.evaluate(()=>localStorage.setItem('segno-fx-factory-design-2026-09-06-channels',JSON.stringify(segnoDemo.snapshot().rig)));await p.goto(base+'?canvas=actual');assert.equal((await state()).end,'next');assert.equal((await state()).playing,false);
 await b('stage').click();await b('session:library').click();await b('session:new').click();await b('session:confirm-new').click();await b('session:library').click();await b('session:row:session-1').click();assert.equal((await snap()).sessions.state.sessions[0].snapshot.audioLibrary.backingEnd,'next');await b('session:load').click();assert.equal((await state()).end,'next');
 // A failed setting write leaves the previous choice in place.
 await p.evaluate(()=>{segnoDemo.performanceDown(3,'custom')});await p.clock.runFor(850);await p.evaluate(()=>segnoDemo.performanceUp('custom'));await foot(1).click();
 await p.evaluate(()=>Storage.prototype.setItem=()=>{throw Error('full')});await b('backing:end:repeat').click();assert.equal((await state()).end,'next');assert.match((await state()).error,/could not be saved/);
 assert.deepEqual(errors,[]);console.log(kind+': seek, tap/hold isolation, encoder cancel/commit, repeat/next boundaries, pending selection, session recall and failed setting writes passed.');
 }finally{await browser.close();}
}})().catch(e=>{console.error(e);process.exitCode=1;});
