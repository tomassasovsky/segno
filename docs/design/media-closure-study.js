// Appliance media and mapping recovery design study. Files and transfers are
// simulated; no native filesystem, storage measurement or audio engine is used.
(function (root) {
  'use strict';
  const copy = value => JSON.parse(JSON.stringify(value));
  const bytes = text => new TextEncoder().encode(text).length;
  const finite = value => typeof value === 'number' && Number.isFinite(value);

  function recordingEstimate({freeBytes, reserveBytes, sampleRate, bytesPerSample, channels, streams = 1} = {}) {
    if (![freeBytes,reserveBytes,sampleRate,bytesPerSample,channels,streams].every(finite) || freeBytes < 0 || reserveBytes < 0 || sampleRate <= 0 || ![2,3,4,8].includes(bytesPerSample) || !Number.isInteger(channels) || channels < 1 || !Number.isInteger(streams) || streams < 1) return {available:false, label:'Recording time unavailable'};
    const bytesPerSecond = sampleRate * bytesPerSample * channels * streams;
    const usableBytes = Math.max(0, freeBytes - reserveBytes);
    const seconds = Math.floor(usableBytes / bytesPerSecond);
    const minutes = Math.floor(seconds / 60), hours = Math.floor(minutes / 60);
    return {available:true, seconds, usableBytes, bytesPerSecond, label:seconds === 0 ? 'No recording space' : minutes === 0 ? 'Under 1 min recording' : (hours ? hours + ' hr ' : '') + (minutes % 60 || !hours ? minutes % 60 + ' min ' : '') + 'recording', sampleRate, bytesPerSample, channels, streams, reserveBytes};
  }
  function estimateBody(options) {
    const estimate = recordingEstimate(options);
    if (!estimate.available) return '<div class="storage-recording-time"><strong>Recording time unavailable</strong><span>Check the recording format and free space.</span></div>';
    const format = `${estimate.sampleRate / 1000} kHz · ${estimate.bytesPerSample * 8}-bit · ${estimate.channels === 1 ? 'Mono' : estimate.channels === 2 ? 'Stereo' : estimate.channels + ' channels'}${estimate.streams > 1 ? ' · ' + estimate.streams + ' simultaneous recordings' : ''}`;
    return `<div class="storage-recording-time"><strong>${estimate.label}${estimate.seconds ? ' remaining · estimated' : ''}</strong><span>${format}</span><small>Internal storage · ${(estimate.reserveBytes / 1e9).toFixed(1)} GB reserved. Extra recordings and Undo audio use more space.</small></div>`;
  }

  function createPresetInterchange(ctx) {
    const {button,escape:esc} = ctx;
    const codec = ctx.codec || root.SegnoFxPresetLibrary;
    let files = [], nextId = 1, state = null, job = null, error = '', failure = '', generation = 0;
    const read = () => copy(ctx.read ? ctx.read() : files);
    const media = () => ctx.media();
    const show = focus => {ctx.render();if(focus)ctx.focus(focus);};
    const list = () => read().filter(file => file.location === state?.location);
    const available = () => state?.location !== 'usb' || !!media().usbConnected;
    const busyElsewhere = () => !!media().job;
    function close(cancel = true) {
      if (!state) return false;
      clearTimeout(job);job = null;
      const prior = state; state = null;error = '';
      if (cancel) prior.cancel?.();
      show(prior.opener);
      return true;
    }
    function start(mode, options) {
      close(false);state = {mode, location:'internal', selected:null, name:options.filename?.replace(/\.segno-fx\.json$/i,'') || 'My presets', keyboard:false, replace:true, ...options};error='';show('mediafx:location:internal');
    }
    function fail(message) {job=null;error=message;show('mediafx:cancel');}
    function uniqueFilename(name, location, all) {
      let result = name + '.segno-fx.json', n = 2;
      while (all.some(file => file.location === location && file.name.toLocaleLowerCase() === result.toLocaleLowerCase())) result = name + ' (' + n++ + ').segno-fx.json';
      return result;
    }
    function transfer() {
      if (!state || job || !available() || busyElsewhere()) return;
      const current = state, driveGeneration = generation, file = list().find(f=>f.id===state.selected);
      if (state.mode === 'import' && !file) return;
      if (state.mode === 'export' && !state.name.trim()) return;
      error='';current.transfer=true;
      job = setTimeout(() => {
        job=null;current.transfer=false;
        if (state !== current) return;
        if (current.location === 'usb' && (!media().usbConnected || generation !== driveGeneration)) return fail('USB drive changed during the transfer. Reconnect it and try again.');
        if (busyElsewhere()) return fail('Another transfer started. Wait for it to finish, then try again.');
        if (failure) {const message=failure;failure='';return fail(message);}
        try {
          if (current.mode === 'import') {
            const latest=read().find(f=>f.id===file.id&&f.location===current.location);
            if (!latest || latest.text!==file.text) return fail('The preset package changed. Select it again.');
            codec.decode(latest.text);
            const receive=current.receive;state=null;receive(latest.text);return;
          }
          const all=read(), name=uniqueFilename(current.name.trim(),current.location,all);
          const added={id:'preset-file-'+nextId++,location:current.location,name,text:current.text};
          while(all.some(f=>f.id===added.id))added.id='preset-file-'+nextId++;
          const capacity=media()[current.location+'FreeBytes'];
          if (finite(capacity) && bytes(current.text)>capacity) return fail('There is not enough space. Choose another location or free some space.');
          if (ctx.write ? ctx.write(all.concat(added)) === false : false) return fail('Could not write the preset package. Existing files are unchanged.');
          if (!ctx.write) files=all.concat(added);
          current.done?.({location:current.location,name});close(false);
        } catch (e) {fail(e.message);}
      }, 650);
      show('mediafx:cancel');
    }
    function keyboard() {
      return `<div class="overlay keyboard-overlay"><section class="dialog keyboard-sheet mediafx-keyboard" role="dialog" aria-modal="true" aria-label="Preset package name"><h2>Package name</h2>${button('mediafx:name-value',`<span class="${state.replace?'selected-name':''}">${esc(state.name)||'Name'}</span>`,'name-value')}<div class="name-keyboard">${['QWERTYUIOP','ASDFGHJKL','ZXCVBNM','1234567890'].map(line=>`<div class="key-row">${line.split('').map(c=>button('mediafx:key:'+c,c)).join('')}</div>`).join('')}<div class="key-row">${button('mediafx:key:clear','Clear')}${button('mediafx:key:space','Space','quiet space-key')}${button('mediafx:key:delete','Delete')}</div></div><div class="actions">${button('mediafx:name-cancel','Cancel')}${button('mediafx:name-done','Use name','primary',state.name.trim()?'':'disabled')}</div></section></div>`;
    }
    function overlay() {
      if (!state) return '';
      if (state.keyboard) return keyboard();
      const importing=state.mode==='import', selected=list().find(f=>f.id===state.selected), connected=available();
      return `<div class="overlay"><section class="dialog mediafx-dialog" role="dialog" aria-modal="true" aria-label="${importing?'Import presets':'Export presets'}"><div class="mediafx-heading"><h2>${importing?'Import presets':'Export presets'}</h2><span>Preset packages</span></div><div class="segment mediafx-locations" aria-label="Storage location">${['internal','usb'].map(location=>button('mediafx:location:'+location,location==='internal'?'Internal':'USB drive',state.location===location?'selected':'',`aria-pressed="${state.location===location}" ${job?'disabled':''}`)).join('')}</div>${!connected?'<div class="mediafx-empty">Connect a USB drive to continue. Your presets stay in My presets.</div>':importing?`<div class="mediafx-files list">${list().map(file=>button('mediafx:file:'+encodeURIComponent(file.id),`<span>${esc(file.name)}</span><small>${Math.max(1,Math.ceil(bytes(file.text)/1024))} KB</small>`,'mediafx-file '+(file.id===state.selected?'selected':''),`aria-pressed="${file.id===state.selected}" ${job?'disabled':''}`)).join('')||'<div class="mediafx-empty">No preset packages here. Choose another location.</div>'}</div>`:`<div class="mediafx-export"><span>Package name</span>${button('mediafx:name',esc(state.name)+'.segno-fx.json','mediafx-name',job?'disabled':'')}<p>${state.count} personal preset${state.count===1?'':'s'} · A new copy. Existing packages keep their names.</p></div>`}${job?`<p class="mediafx-status" role="status">${importing?'Reading package…':'Writing package…'}</p>`:error?`<p class="mediafx-error" role="alert">${esc(error)}</p>`:busyElsewhere()?'<p class="mediafx-status" role="status">Another transfer is using storage. Wait for it to finish.</p>':''}<div class="actions">${button('mediafx:cancel','Cancel')}${button('mediafx:transfer',importing?'Review package':'Export package','primary',!connected||job||busyElsewhere()||importing&&!selected||!importing&&!state.name.trim()?'disabled':'')}</div></section></div>`;
    }
    function action(id) {
      if(!id.startsWith('mediafx:'))return false;
      if(!state)return true;
      const [,command,...parts]=id.split(':'),value=parts.join(':');
      if(command==='cancel')return close();
      if(job)return true;
      if(command==='location'&&['internal','usb'].includes(value)){state.location=value;state.selected=null;error='';show(id);}
      else if(command==='file'&&available()){const file=list().find(f=>f.id===decodeURIComponent(value));if(file){state.selected=file.id;error='';show(id);}}
      else if(command==='transfer')transfer();
      else if(command==='name'){state.keyboard=true;state.originalName=state.name;state.replace=true;show('mediafx:name-value');}
      else if(command==='name-value'){state.replace=!state.replace;show(id);}
      else if(command==='key'&&state.keyboard){const prior=state.replace?'':state.name;state.name=value==='clear'?'':value==='delete'?prior.slice(0,-1):prior.length>=32?prior:prior+(value==='space'?' ':value);state.replace=false;show(id);}
      else if(command==='name-done'&&state.name.trim()){state.keyboard=false;show('mediafx:name');}
      else if(command==='name-cancel'){state.name=state.originalName;state.keyboard=false;show('mediafx:name');}
      return true;
    }
    function key(event) {
      if(!state?.keyboard)return false;
      if(event.key==='Escape')action('mediafx:name-cancel');
      else if(event.key==='Enter')action('mediafx:name-done');
      else if(event.key==='Backspace')action('mediafx:key:delete');
      else if(event.key.length===1&&/^[\p{L}\p{N} _-]$/u.test(event.key))action('mediafx:key:'+(event.key===' '?'space':event.key));
      else return false;
      return true;
    }
    return {overlay,action,key,active:()=>!!state,busy:()=>!!job,back:()=>state?.keyboard?(action('mediafx:name-cancel'),true):close(),leave:()=>close(false),
      chooseFile:(receive,onError,cancel)=>start('import',{receive,onError,cancel,opener:'fxpresets:import'}),
      export:(text,filename,done,opener='fxpresets:export-all')=>{const count=codec.decode(text).length;start('export',{text,count,filename,done,opener});},
      mediaChanged:()=>{generation++;if(state){if(job&&!available()){clearTimeout(job);job=null;state.transfer=false;error='USB drive disconnected. Reconnect it and try again.';}show();}},
      simulate:value=>{if(value.failure!==undefined)failure=value.failure;if(value.files!==undefined){files=copy(value.files);if(ctx.write)ctx.write(files);}show();},
      snapshot:()=>copy({state:state?{mode:state.mode,location:state.location,selected:state.selected,name:state.name,keyboard:state.keyboard}:null,error,busy:!!job,files:read()})};
  }

  function createTargetRepair(ctx) {
    const {button,escape:esc}=ctx;
    let request=null,original='',candidate=null,destination=null,view='choose',error='';
    const show=focus=>{ctx.render();if(focus)ctx.focus(focus);};
    const targets=()=>request?.targets()||[];
    const target=()=>targets().find(t=>t.key===candidate);
    const valueFor=(t,v)=>t.coerce?t.coerce(v):v;
    function close(){if(!request)return false;const focus=request.focus;request=null;candidate=null;error='';show(focus);return true;}
    function open(spec){request=spec;original=JSON.stringify(spec.read());candidate=null;destination=null;view='choose';error='';show('repair:cancel');}
    function overlay(){
      if(!request)return '';
      const t=target();
      return `<div class="overlay"><section class="dialog mapping-repair-dialog" role="dialog" aria-modal="true" aria-label="Repair control"><div class="mediafx-heading"><h2>${view==='review'?'Use this control?':'Repair control'}</h2><span>${esc(request.source)}</span></div><div class="mapping-repair-missing"><small>Missing control</small><strong>${esc(request.label)}</strong></div>${view!=='review'?`<div class="mapping-repair-targets list">${view==='choose'?[...new Set(targets().map(t=>t.destination||t.detail||'Controls'))].map(d=>button('repair:destination:'+encodeURIComponent(d),esc(d),'mapping-repair-target')).join('')||'<p class="mediafx-empty">No replacement controls are available. Restore the missing effect, or return and remove this mapping.</p>':targets().filter(t=>(t.destination||t.detail||'Controls')===destination).map(t=>button('repair:target:'+encodeURIComponent(t.key),`<span>${esc(t.label)}</span><small>${esc(t.detail||t.destination||'')}</small>`,'mapping-repair-target')).join('')||'<p class="mediafx-empty">These controls are no longer available. Choose another destination.</p>'}</div>`:`<div class="mapping-repair-review"><strong>${esc(t?(t.detail?t.detail+' · ':'')+t.label:'This control is no longer available.')}</strong><div class="mapping-repair-values">${(request.values||[]).map(v=>`<div><span>${esc(v.label)}</span><output>${esc(t?t.format?.(valueFor(t,v.value))??String(valueFor(t,v.value)):'Unavailable')}</output></div>`).join('')}</div><p>The range keeps its positions. Review these values before applying. Save the source setup to keep this change.</p></div>`}${error?`<p class="mediafx-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${button('repair:cancel','Cancel')}${view==='review'?button('repair:choose','Choose another')+button('repair:apply','Apply repair','primary',t?'':'disabled'):view==='targets'?button('repair:choose','Other destination'):''}</div></section></div>`;
    }
    function action(id){
      if(!id.startsWith('repair:'))return false;
      if(!request)return true;
      const [,command,...parts]=id.split(':'),key=parts.join(':');
      if(command==='cancel')close();
      else if(command==='choose'){view='choose';error='';show('repair:cancel');}
      else if(command==='destination'){destination=decodeURIComponent(key);view='targets';error='';show('repair:cancel');}
      else if(command==='target'){const t=targets().find(t=>t.key===decodeURIComponent(key));if(t){candidate=t.key;view='review';error='';show('repair:apply');}}
      else if(command==='apply'){
        if(JSON.stringify(request.read())!==original){error='The mapping changed. Cancel and open repair again.';show('repair:cancel');return true;}
        const t=target();if(!t){error='The replacement control is no longer available. Choose another control.';show('repair:choose');return true;}
        try{if(request.apply(t)===false){error='Could not apply the repair. Your previous mapping is unchanged.';show('repair:apply');return true;}close();}
        catch(e){error=e.message;show('repair:apply');}
      }
      return true;
    }
    return {open,overlay,action,back:close,leave:()=>{request=null;candidate=null;error='';},active:()=>!!request,snapshot:()=>copy({active:!!request,source:request?.source,label:request?.label,candidate,view,error,values:request?.values})};
  }
  const api=Object.freeze({recordingEstimate,estimateBody,createPresetInterchange,createTargetRepair});
  root.SegnoMediaClosure=api;
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof window==='undefined'?globalThis:window);
