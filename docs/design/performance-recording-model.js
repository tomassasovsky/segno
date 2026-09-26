// Symbolic PCM take allocation. No audio bytes, filesystem or native recorder.
(function(root){
 'use strict';
 const copy=v=>structuredClone(v),integer=n=>Number.isSafeInteger(n)&&n>0;
 const headerBytes=44;
 function format(value){
  if(!value||!integer(value.sampleRate)||!integer(value.channels)||![16,24,32].includes(value.bitDepth)||!integer(value.partBytes))return null;
  const frameBytes=value.channels*value.bitDepth/8,partFrames=Math.floor((value.partBytes-headerBytes)/frameBytes);
  return integer(partFrames)?{sampleRate:value.sampleRate,channels:value.channels,bitDepth:value.bitDepth,partBytes:value.partBytes,frameBytes,partFrames,headerBytes}:null;
 }
 function capacity(value){return value&&Number.isFinite(value.freeBytes)&&value.freeBytes>=0&&Number.isFinite(value.reserveBytes)&&value.reserveBytes>=0?Math.max(0,Math.floor(value.freeBytes-value.reserveBytes)):null;}
 function create(identity,settings){
  const f=format(settings);if(!f||typeof identity?.id!=='string'||!identity.id||typeof identity.name!=='string')return {error:'The recording format or take identity is unavailable.'};
  return {take:{...copy(identity),format:f,frames:0,seconds:0,bytes:0,parts:[]}};
 }
 function valid(t){
  if(!t||!format(t.format)||!Number.isSafeInteger(t.frames)||t.frames<0||!Array.isArray(t.parts))return false;
  const canonical=format(t.format);if(['frameBytes','partFrames','headerBytes'].some(k=>canonical[k]!==t.format[k]))return false;
  let frames=0,bytes=0;
  for(const [i,p] of t.parts.entries()){
   if(!p||p.unreadable||p.index!==i+1||!integer(p.frames)||p.frames>t.format.partFrames||p.bytes!==headerBytes+p.frames*t.format.frameBytes||p.seconds!==p.frames/t.format.sampleRate||p.id!==t.id+'-part-'+(i+1)||(i<t.parts.length-1&&p.frames!==t.format.partFrames))return false;
   frames+=p.frames;bytes+=p.bytes;
  }
  return frames===t.frames&&bytes===t.bytes&&t.seconds===frames/t.format.sampleRate;
 }
 function remaining(t,space){
  const budget=capacity(space);if(budget===null||!valid(t))return null;
  const f=t.format,last=t.parts.at(-1),room=last?f.partFrames-last.frames:0;
  let free=budget,frames=Math.min(room,Math.floor(free/f.frameBytes));free-=frames*f.frameBytes;
  const fullBytes=headerBytes+f.partFrames*f.frameBytes,full=Math.floor(free/fullBytes);
  frames+=full*f.partFrames;free-=full*fullBytes;
  frames+=Math.min(f.partFrames,Math.max(0,Math.floor((free-headerBytes)/f.frameBytes)));
  return frames/f.sampleRate;
 }
 function advance(t,requestedFrames,space){
  if(!valid(t)||!Number.isSafeInteger(requestedFrames)||requestedFrames<0)return {error:'The recording checkpoint is unreadable.'};
  let budget=capacity(space);if(budget===null)return {error:'Storage capacity is unavailable. The last saved checkpoint is kept.'};
  const take=copy(t),f=take.format;let left=requestedFrames,bytesUsed=0;
  while(left>0){
   let part=take.parts.at(-1);
   if(!part||part.frames===f.partFrames){
    if(budget<headerBytes+f.frameBytes)break;
    const index=take.parts.length+1;part={id:take.id+'-part-'+index,index,name:take.name.replace(/\.wav$/i,'')+' · Part '+String(index).padStart(3,'0')+'.wav',frames:0,seconds:0,bytes:headerBytes};
    take.parts.push(part);budget-=headerBytes;bytesUsed+=headerBytes;
   }
   const frames=Math.min(left,f.partFrames-part.frames,Math.floor(budget/f.frameBytes));if(!frames)break;
   const bytes=frames*f.frameBytes;part.frames+=frames;part.seconds=part.frames/f.sampleRate;part.bytes+=bytes;
   take.frames+=frames;left-=frames;budget-=bytes;bytesUsed+=bytes;
  }
  take.seconds=take.frames/f.sampleRate;take.bytes+=bytesUsed;
  return {take,bytesUsed,stopped:left>0,reason:left>0?'Storage reserve reached. The recorded part of this take is kept.':'',remaining:remaining(take,{freeBytes:budget,reserveBytes:0})};
 }
 function asset(t,recovered=false){
  if(!valid(t)||!t.frames)return null;
  return {id:t.id,name:t.name,folder:'Performances',seconds:t.seconds,frames:t.frames,bytes:t.bytes,format:'WAV',storage:copy(t.storage||{location:'internal'}),parts:copy(t.parts),performance:{takeId:t.id,sessionId:t.sessionId,sessionName:t.sessionName,output:t.output,captureTap:t.captureTap||'before-final-controls',recovered,startedAt:t.startedAt,recordingFormat:copy(t.format)}};
 }
 function manifest(file){
  const f=file?.performance?.recordingFormat,t={...file,id:file?.performance?.takeId,format:f};
  if(typeof t.id!=='string'||!valid(t))return {error:'The performance parts are incomplete, unreadable or out of order.'};
  let offset=0;const parts=file.parts.map(p=>{const result={...copy(p),offsetFrames:offset};offset+=p.frames;return result;});
  return {takeId:t.id,name:file.name,frames:file.frames,seconds:file.seconds,sampleRate:f.sampleRate,parts};
 }
 function locate(file,seconds){
  const plan=manifest(file);if(plan.error)return plan;
  if(!Number.isFinite(seconds)||seconds<0||seconds>=plan.seconds)return {ended:true};
  const frame=Math.floor(seconds*plan.sampleRate),part=plan.parts.find(p=>frame<p.offsetFrames+p.frames);
  return {id:part.id,index:part.index,offsetFrames:frame-part.offsetFrames,offsetSeconds:(frame-part.offsetFrames)/plan.sampleRate};
 }
 const api={format,create,valid,remaining,advance,asset,manifest,locate};root.SegnoPerformanceRecording=api;if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof window==='undefined'?globalThis:window);
