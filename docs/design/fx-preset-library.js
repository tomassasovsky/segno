// Portable prototype preset values. This format does not claim native Looper X
// interchange or DSP equivalence. It carries both edited values and raw source.
(function (root) {
  'use strict';
  const format = 'segno.fx-preset-library', version = 1, maxBytes = 2 * 1024 * 1024;
  const copy = value => JSON.parse(JSON.stringify(value));
  const finite = value => typeof value === 'number' && Number.isFinite(value);
  const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const normalized = value => finite(value) && value >= 0 && value <= 1;
  function nameFor(value) {
    if (typeof value !== 'string' || !value.trim() || value.trim().length > 32 || /[\u0000-\u001f\u007f]/.test(value)) throw Error('Use a preset name of 1–32 characters.');
    return value.trim();
  }
  function sound(preset) {
    if (!object(preset) || preset.factory === true) throw Error('Factory presets are read-only. Save a personal copy first.');
    const name = nameFor(preset.name);
    if (typeof preset.family !== 'string' || !preset.family || preset.family.length > 80) throw Error('The preset family is missing.');
    if (!Array.isArray(preset.modules) || !preset.modules.length || preset.modules.length > 128) throw Error('The preset must contain 1–128 effects.');
    const modules = preset.modules.map(module => {
      if (!object(module) || typeof module.name !== 'string' || !module.name || module.name.length > 80 || !Array.isArray(module.params) || module.params.length > 128) throw Error('An effect description is invalid.');
      const keys = new Set();
      const params = module.params.map(p => {
        if (!Array.isArray(p) || p.length !== 4 || typeof p[0] !== 'string' || !p[0] || p[0].length > 100 || keys.has(p[0]) || !normalized(p[1]) || typeof p[2] !== 'string' || p[2].length > 24 || !normalized(p[3])) throw Error('An effect parameter is invalid.');
        keys.add(p[0]); return copy(p);
      });
      const next = {name: module.name, params, sourceValues: !!module.sourceValues};
      if (module.bypass !== undefined) { if (typeof module.bypass !== 'boolean') throw Error('An effect bypass value is invalid.'); next.bypass = module.bypass; }
      for (const key of ['sourceFamily','sourcePresetId','parameterSourcePresetId']) if (module[key] !== undefined) {
        if (typeof module[key] !== 'string' || module[key].length > 100) throw Error('The effect source is invalid.'); next[key] = module[key];
      }
      // Icons are bundled filenames, never external URLs or traversal paths.
      if (module.icon !== undefined) { if (typeof module.icon !== 'string' || !/^[\w -]+\.png$/.test(module.icon)) throw Error('The effect artwork is invalid.'); next.icon = module.icon; }
      return next;
    });
    const result = {name, family: preset.family, modules, kind: 'Your saved sound'};
    if (preset.artwork !== undefined) { if (typeof preset.artwork !== 'string' || !/^[\w-]+$/.test(preset.artwork)) throw Error('The rack artwork is invalid.'); result.artwork = preset.artwork; }
    if (preset.parameterSourcePresetId !== undefined) { if (typeof preset.parameterSourcePresetId !== 'string') throw Error('The source preset identifier is invalid.'); result.parameterSourcePresetId = preset.parameterSourcePresetId; }
    if (preset.original !== undefined) { if (!object(preset.original)) throw Error('The original source record is invalid.'); result.original = copy(preset.original); }
    if (preset.channels !== undefined) {
      const c = preset.channels;
      if (!object(c) || !['stereo','left','right','mono'].includes(c.input) || !['stereo','mono'].includes(c.output) || !Array.isArray(c.pan) || c.pan.length !== 4 || c.pan[0] !== 'Pan' || !normalized(c.pan[1]) || c.pan[2] !== '' || !normalized(c.pan[3])) throw Error('The channel settings are invalid.');
      result.channels = copy(c);
    }
    return result;
  }
  function encode(presets) {
    if (!Array.isArray(presets) || !presets.length || presets.length > 256) throw Error('Choose 1–256 personal presets.');
    const text = JSON.stringify({format, version, presets: presets.map(sound)}, null, 2);
    if (new TextEncoder().encode(text).length > maxBytes) throw Error('The preset package is larger than 2 MB. Export fewer presets.');
    return text;
  }
  function decode(text) {
    if (typeof text !== 'string' || new TextEncoder().encode(text).length > maxBytes) throw Error('Choose a preset package smaller than 2 MB.');
    let value; try { value = JSON.parse(text); } catch { throw Error('This file is not valid preset JSON.'); }
    if (!object(value) || value.format !== format || value.version !== version) throw Error('Choose a Segno FX preset package, version 1.');
    if (!Array.isArray(value.presets) || !value.presets.length || value.presets.length > 256) throw Error('The package must contain 1–256 presets.');
    return value.presets.map(sound);
  }
  function unique(name, used) {
    let result = name, n = 2;
    while (used.has(result.toLocaleLowerCase())) { const suffix = ' (' + n++ + ')'; result = name.slice(0, 32 - suffix.length).trimEnd() + suffix; }
    used.add(result.toLocaleLowerCase()); return result;
  }
  function importedNames(presets, saved) {
    const used = new Set(saved.map(p => p.name.toLocaleLowerCase()));
    return presets.map(p => ({...copy(p), name: unique(p.name, used)}));
  }
  function store({read, write}) {
    let removed = null;
    const list = () => copy(read() || []);
    function commit(next) { if (write(copy(next)) === false) throw Error('Could not save My presets. Your previous library is unchanged.'); }
    function entry(index, saved) { if (!Number.isInteger(index) || !saved[index]) throw Error('This personal preset is no longer available.'); if (saved[index].factory === true) throw Error('Factory presets are read-only.'); return saved[index]; }
    return {
      list,
      rename(index, value) {
        const next = list(), p = entry(index, next), name = nameFor(value);
        if (next.some((p,i) => i !== index && p.name.toLocaleLowerCase() === name.toLocaleLowerCase())) throw Error('A personal preset already has this name.');
        p.name = name; commit(next); removed = null; return copy(p);
      },
      remove(index) {
        const next = list(), p = entry(index, next); next.splice(index,1); commit(next);
        removed = {index, preset:copy(p), after:JSON.stringify(next)}; return copy(p);
      },
      undo() {
        if (!removed) return false;
        const next = list(); if (JSON.stringify(next) !== removed.after) throw Error('My presets changed after the deletion.');
        next.splice(removed.index,0,copy(removed.preset)); commit(next); removed = null; return true;
      },
      canUndo: () => !!removed,
      export(index) { const saved = list(); return encode(index === undefined ? saved : [entry(index,saved)]); },
      preview(text) { return importedNames(decode(text),list()); },
      import(presets) {
        const next = list(), additions = importedNames(presets.map(sound),next);
        commit(next.concat(additions)); removed = null; return copy(additions);
      },
    };
  }
  function createUI(ctx) {
    const {button,escape:esc} = ctx, library = store(ctx), media = ctx.media;
    if (!media) throw Error('The appliance preset media adapter is required.');
    let modal = null, error = '', opener = '';
    const show = id => { ctx.render(); if (id) ctx.focus(id); };
    function close() { modal = null; error = ''; show(opener); }
    function receive(text) {
      try { const presets = library.preview(text); modal = {type:'import',presets}; error=''; show('fxpresets:import-confirm'); }
      catch (e) { error=e.message; modal={type:'error'}; show('fxpresets:cancel'); }
    }
    function body() {
      const saved = library.list();
      return ctx.header('My presets','',`<div class="chain-actions">${library.canUndo()?button('fxpresets:undo','Undo delete'):''}${button('fxpresets:import','Import presets')}${button('fxpresets:export-all','Export all','quiet',saved.length?'':'disabled')}</div>`)
        + `<div class="list"><div class="saved-grid">${saved.map((p,i)=>`<div class="fx-preset-card">${button('fxpresets:load:'+i,`<span class="saved-art">${ctx.artwork(p)}</span><span class="catalog-title">${esc(p.name)}</span><span class="catalog-meta">${p.family==='Single FX'?'Single effect':p.modules.filter(m=>m.name!=='Master').length+' effects'}</span>`,'catalog-card saved-card')}<div class="fx-preset-actions">${button('fxpresets:rename:'+i,'Rename')}${button('fxpresets:export:'+i,'Export')}${button('fxpresets:delete:'+i,'Delete')}</div></div>`).join('') || '<div class="list-empty">Save a sound or import a preset package to start My presets.</div>'}</div></div>`;
    }
    function overlay() {
      if (media.active()) return media.overlay();
      if (!modal) return '';
      let content = '', keyboard = false;
      if (modal.type === 'rename') {
        keyboard = true;
        content = `<h2>Rename preset</h2>${button('fxpresets:name',`<span class="${modal.replace?'selected-name':''}">${esc(modal.value)||'Name'}</span>`,'name-value',`aria-label="Preset name: ${esc(modal.value)}"`)}<div class="name-keyboard">${['QWERTYUIOP','ASDFGHJKL','ZXCVBNM','1234567890'].map(line=>`<div class="key-row">${line.split('').map(c=>button('fxpresets:key:'+c,c)).join('')}</div>`).join('')}<div class="key-row">${button('fxpresets:key:clear','Clear')}${button('fxpresets:key:space','Space','quiet space-key')}${button('fxpresets:key:delete',ctx.icon('delete'),'quiet icon-only','aria-label="Delete character"')}</div></div>${error?`<p class="fx-preset-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${button('fxpresets:cancel','Cancel')}${button('fxpresets:rename-save','Save name','primary',modal.value.trim()?'':'disabled')}</div>`;
      } else if (modal.type === 'delete') content = `<h2>Delete ${esc(modal.name)}?</h2><p class="fx-preset-summary">Remove this copy from My presets. Racks in your session keep their sound.</p>${error?`<p class="fx-preset-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${button('fxpresets:cancel','Cancel')}${button('fxpresets:delete-confirm','Delete preset','primary')}</div>`;
      else if (modal.type === 'import') content = `<h2>Import ${modal.presets.length===1?'preset':modal.presets.length+' presets'}?</h2><p class="fx-preset-summary">Add independent copies to My presets. Duplicate names receive a number.</p><div class="fx-preset-import-list">${modal.presets.map(p=>`<div class="fx-preset-import-row">${esc(p.name)}<span>${esc(p.family)} · ${p.modules.length} effects</span></div>`).join('')}</div>${error?`<p class="fx-preset-error" role="alert">${esc(error)}</p>`:''}<div class="actions">${button('fxpresets:cancel','Cancel')}${button('fxpresets:import-confirm','Import presets','primary')}</div>`;
      else content = `<h2>Preset import</h2><p class="fx-preset-error" role="alert">${esc(error)}</p><div class="actions">${button('fxpresets:cancel','Close')}</div>`;
      return `<div class="overlay ${keyboard?'keyboard-overlay':''}"><section class="dialog ${keyboard?'keyboard-sheet':''}" role="dialog" aria-modal="true" aria-label="${modal.type==='rename'?'Rename preset':modal.type==='delete'?'Delete preset':'Import presets'}">${content}</section></div>`;
    }
    function action(id) {
      if (media.action(id)) return true;
      if (!id.startsWith('fxpresets:')) return false;
      const [,command,value] = id.split(':');
      if (!modal) opener=id;
      try {
        if (command === 'load') { const p=library.list()[Number(value)]; if(p)ctx.load(p); }
        else if (command === 'rename') { const p=library.list()[Number(value)]; if(p){modal={type:'rename',index:Number(value),value:p.name,replace:true};error='';show('fxpresets:name');} }
        else if (command === 'name' && modal?.type==='rename') {modal.replace=!modal.replace;show(id);}
        else if (command === 'key' && modal?.type==='rename') {const prior=modal.replace?'':modal.value;modal.value=value==='delete'?prior.slice(0,-1):value==='clear'?'':prior.length>=32?prior:prior+(value==='space'?' ':value);modal.replace=false;error='';show(id);}
        else if (command === 'rename-save' && modal?.type==='rename') {library.rename(modal.index,modal.value);close();ctx.notice('Preset renamed.');}
        else if (command === 'delete') {const p=library.list()[Number(value)];if(p){modal={type:'delete',index:Number(value),name:p.name};error='';show('fxpresets:cancel');}}
        else if (command === 'delete-confirm' && modal?.type==='delete') {library.remove(modal.index);modal=null;error='';show('fxpresets:undo');ctx.notice('Preset deleted. Undo is available.');}
        else if (command === 'undo') {if(library.undo()){show('fxpresets:import');ctx.notice('Preset restored.');}}
        else if (command === 'export' || command === 'export-all') {const text=library.export(command==='export'?Number(value):undefined);media.export(text,'My presets.segno-fx.json',result=>ctx.notice('Preset package exported to '+(result.location==='usb'?'USB drive':'Internal')+'.'),id);}
        else if (command === 'import') media.chooseFile(receive,message=>{modal={type:'error'};error=message;show('fxpresets:cancel');},()=>show(opener));
        else if (command === 'import-confirm' && modal?.type==='import') {const additions=library.import(modal.presets);modal=null;error='';show('fxpresets:load:'+(library.list().length-additions.length));ctx.notice(additions.length+' preset'+(additions.length===1?'':'s')+' imported.');}
        else if (command === 'cancel') close();
      } catch (e) {error=e.message;if(modal)show();else ctx.notice(error);}
      return true;
    }
    return {body,overlay,action,receive,key:event=>media.key(event)||false,back:()=>{if(media.back())return true;if(!modal)return false;close();return true;},leave:()=>{media.leave();modal=null;error='';},snapshot:()=>copy({modal,error,presets:library.list(),canUndo:library.canUndo()}),store:library};
  }
  const api = {format,version,maxBytes,sound,encode,decode,store,importedNames,createUI};
  root.SegnoFxPresetLibrary = Object.freeze(api);
  root.createFxPresetLibraryStudy = createUI;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
