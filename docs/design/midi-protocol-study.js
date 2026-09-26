// Explicit MIDI 1.0 control decoding for the silent prototype.
(function(root){
 'use strict';
 const protocols=[{id:'standard',label:'CC, Note or Program',detail:'Ordinary 7-bit messages'},{id:'cc14',label:'14-bit CC',detail:'Fresh MSB + LSB pairs'},{id:'nrpn',label:'NRPN',detail:'Parameter selection + 14-bit Data Entry'},{id:'bank-program',label:'Bank + Program',detail:'Bank MSB + LSB, then Program Change'},{id:'relative',label:'Relative CC',detail:'Two’s complement · 1 up, 127 down'}];
 const byte=n=>Number.isInteger(n)&&n>=0&&n<=127,channel=n=>n==='omni'||Number.isInteger(n)&&n>=1&&n<=16,word=n=>Number.isInteger(n)&&n>=0&&n<=16383;
 const protocol=s=>s?.protocol||'standard';
 function validSource(s){
  if(!s||!channel(s.channel)||!byte(s.number)||!['cc','note','program'].includes(s.kind))return false;
  const p=protocol(s);if(!protocols.some(v=>v.id===p))return false;
  if(p==='cc14')return s.kind==='cc'&&s.number<=31;
  if(p==='nrpn')return s.kind==='cc'&&s.number===6&&word(s.parameter)&&s.parameter!==16383;
  if(p==='bank-program')return s.kind==='program'&&word(s.bank);
  if(p==='relative')return s.kind==='cc';
  return true;
 }
 function same(a,b){return validSource(a)&&validSource(b)&&a.kind===b.kind&&a.number===b.number&&protocol(a)===protocol(b)&&(a.channel===b.channel||a.channel==='omni'||b.channel==='omni')&&(protocol(a)!=='nrpn'||a.parameter===b.parameter)&&(protocol(a)!=='bank-program'||a.bank===b.bank);}
 function footprint(s){const p=protocol(s);return p==='nrpn'?['cc:6','cc:38','cc:98','cc:99']:p==='cc14'?['cc:'+s.number,'cc:'+(s.number+32)]:p==='bank-program'?['cc:0','cc:32','program:'+s.number]:[s.kind+':'+s.number];}
 function overlaps(a,b){
  if(!validSource(a)||!validSource(b)||a.channel!==b.channel&&a.channel!=='omni'&&b.channel!=='omni')return false;
  if(protocol(a)===protocol(b))return same(a,b);
  const used=footprint(a);return footprint(b).some(v=>used.includes(v));
 }
 function name(s){if(!validSource(s))return 'No control selected';const p=protocol(s),label=p==='cc14'?'CC '+s.number+' / '+(s.number+32)+' · 14-bit':p==='nrpn'?'NRPN '+s.parameter:p==='relative'?'CC '+s.number+' · Relative':p==='bank-program'?'Bank '+s.bank+' · Program '+s.number:({cc:'CC',note:'Note',program:'Program'})[s.kind]+' '+s.number;return label+' · '+(s.channel==='omni'?'Omni':'Ch '+s.channel);}
 function decoder({now=()=>performance.now()}={}){
  const states=new Map();
  function pair(state,key,part,value){
   const at=now();let p=state[key];if(!p||at-p.at>100)p=state[key]={at};p[part]=value;
   if(p.high===undefined||p.low===undefined)return null;const result=p.high*128+p.low;delete state[key];return result;
  }
  function feed(device,message,mode='standard'){
   if(typeof device!=='string'||!message||!Number.isInteger(message.channel)||message.channel<1||message.channel>16||!byte(message.number)||!byte(message.value)||!['cc','note','program'].includes(message.kind)||!protocols.some(v=>v.id===mode))return null;
   const {kind,number,value,channel}=message,source={kind,number,channel};
   if(mode==='standard')return {source,value,maximum:127};
   if(mode==='relative')return kind==='cc'?{source:{...source,protocol:mode},value,maximum:127,delta:value<64?value:value-128}:null;
   const key=device+':'+channel+':'+mode;let state=states.get(key);if(!state){state={};states.set(key,state);}
   if(mode==='cc14'){
    if(kind!=='cc'||number>63)return null;const msb=number%32,result=pair(state,'cc:'+msb,number<32?'high':'low',value);
    return result===null?null:{source:{kind:'cc',number:msb,channel,protocol:mode},value:result,maximum:16383};
   }
   if(mode==='bank-program'){
    if(kind==='cc'&&(number===0||number===32)){const result=pair(state,'bankPair',number===0?'high':'low',value);state.ready=false;if(result!==null){state.bank=result;state.ready=true;}return null;}
    return kind==='program'&&state.ready?{source:{...source,protocol:mode,bank:state.bank},value:127,maximum:127}:null;
   }
   if(kind!=='cc')return null;
   if(number===100||number===101){delete state.parameter;delete state.select;delete state.data;return null;}
   if(number===99||number===98){delete state.parameter;delete state.data;const result=pair(state,'select',number===99?'high':'low',value);if(result!==null&&result!==16383)state.parameter=result;return null;}
   if(number===96||number===97){delete state.data;return null;}
   if(state.parameter===undefined||number!==6&&number!==38)return null;
   const result=pair(state,'data',number===6?'high':'low',value);return result===null?null:{source:{kind:'cc',number:6,channel,protocol:mode,parameter:state.parameter},value:result,maximum:16383};
  }
  return {feed,reset:device=>{for(const key of states.keys())if(device===undefined||key.startsWith(device+':'))states.delete(key);}};
 }
 const api={protocols,protocol,validSource,same,overlaps,name,decoder};root.SegnoMidiProtocol=api;if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof window==='undefined'?globalThis:window);
