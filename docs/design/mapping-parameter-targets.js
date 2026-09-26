// Typed Segno controls. Values at the mapping boundary are normalized; stored
// values retain their musical unit and live in the same state as touch controls.
window.createMappingParameterTargets=({read,tracks,trackLabel=id=>id,recording=()=>false,externalClock=()=>false,beforeTempoChange=()=>{}})=>{
  const clamp=n=>Math.max(0,Math.min(1,Number(n))),getPath=(s,path)=>path.reduce((v,k)=>v?.[k],s);
  function put(s,path,value){const key=path.at(-1);for(const part of path.slice(0,-1))s=s[part] ||= {};s[key]=value;}
  const gain=v=>v===0?'−∞ dB':(20*Math.log10(v)).toFixed(1)+' dB';
  const pan=v=>v===.5?'Center':Math.round(Math.abs(v-.5)*200)+'% '+(v<.5?'L':'R');
  const destinations=()=>[{id:'Click',label:'Click',kind:'sources'},{id:'Backing',label:'Backing',kind:'sources'},{id:'Loop',label:'Loop controls',kind:'loop'}];
  function targets(){const list=[];
    function add({path,inheritedPath,fallback,min=0,max=1,step=.01,options,type='continuous',label,destination='Loop',detail=destination,format,enabled=()=>true,unavailableReason='',before=()=>{}}){
      if(options){min=0;max=options.length-1;step=1;type=options.length===2&&options.every(o=>typeof o.value==='boolean')?'switch':'enum';}
      const decode=v=>options?options[Math.round(clamp(v)*max)].value:Math.max(min,Math.min(max,Math.round((min+clamp(v)*(max-min))/step)*step));
      const encode=v=>options?Math.max(0,options.findIndex(o=>o.value===v))/max:clamp((v-min)/(max-min));
      const actual=s=>getPath(s,path)??(inheritedPath?getPath(s,inheritedPath):undefined)??fallback;
      const target={key:JSON.stringify(path),destination,detail,label,type,unit:options?'choice':label==='Fade duration'?'s':label==='Overdub decay'?'%':'',min:0,max:1,step:step/(max-min),options:options?.map((o,i)=>({label:o.label,value:i/max})),defaultValue:encode(fallback),enabled,unavailableReason,
        format:v=>options?options[Math.round(clamp(v)*max)].label:format?format(decode(v)):String(decode(v)),coerce:v=>encode(decode(v)),get:()=>encode(actual(read())),
        set:v=>{if(!Number.isFinite(Number(v))||!enabled())return false;before();put(read(),path,decode(v));if(path[0]==='loopSettings'&&path[1]==='countIn'&&decode(v)>0)put(read(),['loopSettings','start'],'press');return true;},persist:(snapshot,v)=>put(snapshot,path,decode(v))};
      list.push(target);
    }
    for(const id of ['Click','Backing']){
      add({path:['expressionMix',id,'level'],destination:id,detail:id,label:'Volume',fallback:1,format:gain});
      add({path:['expressionMix',id,'pan'],destination:id,detail:id,label:'Pan',fallback:.5,format:pan});
    }
    const unlocked=()=>!recording(),tempoUnlocked=()=>!recording()&&!externalClock();
    add({path:['loopSettings','tempo'],label:'Tempo',fallback:84,min:30,max:300,step:.01,format:v=>v.toFixed(2)+' BPM',enabled:tempoUnlocked,unavailableReason:'Finish recording and use internal clock to set tempo',before:beforeTempoChange});
    add({path:['loopSettings','click'],label:'Hear click',fallback:'first',options:[{value:'off',label:'Off'},{value:'first',label:'First recording'},{value:'rec',label:'Recording'},{value:'always',label:'Play & record'}],enabled:unlocked,unavailableReason:'Finish recording'});
    add({path:['loopSettings','countIn'],label:'Count-in',fallback:1,options:[0,1,2,4].map(value=>({value,label:value?value+' '+(value===1?'bar':'bars'):'Off'})),enabled:unlocked,unavailableReason:'Finish recording'});
    add({path:['fadeSeconds'],label:'Fade duration',fallback:4,min:.5,max:30,step:.5,format:v=>v.toFixed(1)+' s'});
    const quantize=[['immediate','Immediately'],['loop','Loop start'],['bar','1 bar'],['half','1/2 note'],['quarter','1/4 note'],['eighth','1/8 note'],['sixteenth','1/16 note']].map(([value,label])=>({value,label}));
    for(const id of [null,...tracks()]){
      const destination=id||'Loop',detail=id?trackLabel(id):'Loop defaults';
      const setting=(group,field)=>['loopSettings',...(id?['track'+group[0].toUpperCase()+group.slice(1),id]:[group]),field];
      const addSetting=(group,field,rest)=>add({path:setting(group,field),inheritedPath:id?['loopSettings',group,field]:undefined,destination,detail,...rest});
      addSetting('playback','decay',{label:'Overdub decay',fallback:0,min:0,max:100,step:1,format:v=>v===0?'Off · Keep layers':v+'% decay'});
      addSetting('playback','once',{label:'Playback',fallback:false,options:[{value:false,label:'Loop'},{value:true,label:'Once'}]});
      addSetting('audioTempo','follow',{label:'Follow tempo',fallback:true,options:[{value:false,label:'Off'},{value:true,label:'On'}]});
      addSetting('audioTempo','keepPitch',{label:'Preserve pitch',fallback:true,options:[{value:false,label:'Follows speed'},{value:true,label:'Unchanged'}]});
      addSetting('lengthTiming','bars',{label:'Record length',fallback:0,min:0,max:64,step:1,format:v=>v===0?'Auto':v+' '+(v===1?'bar':'bars'),enabled:()=>unlocked()&&(!id||read().loopSettings?.mode!=='multi'),unavailableReason:id?'Multi shares the default length; finish recording before editing':'Finish recording'});
      addSetting('lengthTiming','quantize',{label:'Record timing',fallback:'immediate',options:quantize,enabled:unlocked,unavailableReason:'Finish recording'});
      if(id)add({path:['trackFadeSeconds',id],inheritedPath:['fadeSeconds'],destination,detail,label:'Fade duration',fallback:4,min:.5,max:30,step:.5,format:v=>v.toFixed(1)+' s'});
    }
    return list;
  }
  return {targets,destinations};
};
