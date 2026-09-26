// Accidental-touch protection. This is not authentication or a physical driver.
window.createTouchLockStudy=ctx=>{
 let locked=false,hold=null,consumeClick=false;
 const holdMs=1500;
 function cancelHold(){if(hold)clearTimeout(hold.timer);hold=null;}
 function unlock(){if(!locked)return false;consumeClick=!!hold;cancelHold();locked=false;ctx.render();ctx.focus('touch-lock:lock');return true;}
 function lock(){if(locked)return false;ctx.cancelTouch();locked=true;ctx.render();ctx.focus('touch-lock:unlock');return true;}
 function action(id){if(id==='touch-lock:lock'){lock();return true;}if(id==='touch-lock:unlock'){unlock();return true;}return false;}
 function filter(event){
  if(!locked&&event.type==='pointerdown')consumeClick=false;
  if(event.type==='click'&&consumeClick){consumeClick=false;event.preventDefault();event.stopImmediatePropagation();return true;}
  if(!locked)return false;
  if(event.type==='pointerdown'){
   cancelHold();if(event.target.closest?.('[data-action="touch-lock:unlock"]')&&event.isPrimary!==false)hold={id:event.pointerId,x:event.clientX,y:event.clientY,timer:setTimeout(unlock,holdMs)};
  }else if(event.type==='pointermove'&&hold&&event.pointerId===hold.id&&Math.hypot(event.clientX-hold.x,event.clientY-hold.y)>24)cancelHold();
  else if(['pointerup','pointercancel','lostpointercapture'].includes(event.type))cancelHold();
  event.preventDefault();event.stopImmediatePropagation();return true;
 }
 function attach(surface){for(const type of ['pointerdown','pointermove','pointerup','pointercancel','lostpointercapture','click','dblclick','contextmenu','wheel','input','change'])surface.addEventListener(type,filter,{capture:true,passive:false});surface.addEventListener('pointerleave',cancelHold);window.addEventListener?.('blur',cancelHold);}
 const overlay=()=>locked?`<aside class="touch-lock-banner" role="status"><div><strong>Touch locked</strong><span>Pedals, MIDI and encoder remain active.</span></div>${ctx.button('touch-lock:unlock','Unlock touch','quiet','data-touch-unlock="true"')}<small>Use the encoder, or hold Unlock touch for 1.5 seconds.</small></aside>`:'';
 return {action,lock,unlock,filter,attach,overlay,locked:()=>locked,cancelHold,snapshot:()=>({locked,holding:!!hold,holdMs})};
};
