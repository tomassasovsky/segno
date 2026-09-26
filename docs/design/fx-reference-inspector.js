(function (root) {
  'use strict';
  function matching(data, {tab = 'controls', family = '', search = '', status = 'all'} = {}) {
    const query = search.trim().toLowerCase();
    const rows = tab === 'audio' ? data.audio : tab === 'singles' ? data.singles : data.controls;
    return rows.filter(row => (tab !== 'controls' || ((!family || row.family === family) && (status === 'all' || row.status === status)))
      && [row.key, row.name, row.module, row.family, row.borrowedFamily].filter(Boolean).join(' ').toLowerCase().includes(query));
  }
  function presetValue(catalogue, control, presetId) {
    const family = catalogue.families.find(row => row.name === control.family);
    const preset = family?.presets.find(row => row.id === presetId);
    return preset && Object.hasOwn(preset.parameters, control.key) ? {id: preset.id, name: preset.name, value: preset.parameters[control.key]} : null;
  }
  function constructorEvidence(data, control) {
    return control.family === "Ed's Rack" ? data.native.records.find(row => row.sourceKey === control.key) || null : null;
  }
  function missingSources(data) {
    return {
      date: data.date,
      requiredFxCapture: ['Stable family or native Single FX identity and exact source key', 'Instantiated translator type and units', 'Legal domain, scale curve and complete enum value/label table', 'Factory reset value and reset provenance', 'Mode-dependent visibility and editing conditions'],
      unresolvedControls: data.controls.filter(row => row.status === 'unresolved').map(row => ({family: row.family, key: row.key})),
      unresolvedSingles: data.singles.map(row => row.name),
      requiredAudioSource: 'Looper X factory-content Resources and looper.db, with version and provenance. Historical names and byte counts alone do not prove exact current content.',
      unavailableFactoryAudio: data.audio.filter(row => !row.available).map(row => ({name: row.name, expectedBytes: row.expectedBytes})),
      limits: data.scope,
    };
  }
  const api = Object.freeze({matching, presetValue, constructorEvidence, missingSources});
  root.SegnoFxEvidenceInspector = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (!root.document) return;

  const data = root.SegnoFxReferenceEvidence;
  const catalogue = root.LOOPERX_FACTORY;
  const $ = id => document.getElementById(id);
  const escape = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const params = new URLSearchParams(location.search);
  const state = {tab: ['controls','singles','audio'].includes(params.get('tab')) ? params.get('tab') : 'controls',
    family: params.get('family') || "Ed's Rack", search: params.get('search') || '', status: 'all', selection: params.get('control') || 'Amp Drive'};
  const families = catalogue.families.map(row => row.name);
  if (!families.includes(state.family)) state.family = families[0];
  $('family').innerHTML = families.map(name => `<option>${escape(name)}</option>`).join('');
  $('family').value = state.family;
  $('search').value = state.search;

  function renderDetail(row) {
    if (!row) { $('detail').innerHTML = '<h2>No matching evidence</h2><p>Change the search or filter to inspect another entry.</p>'; return; }
    if (state.tab === 'audio') {
      $('detail').innerHTML = `<p class="state">Audio unavailable</p><h2>${escape(row.name)}</h2>
        <p>A historical cleanup script names this file. Its audio is absent from both checked official firmware packages.</p>
        <div class="facts"><div><span>Historical expected size</span><strong>${(row.expectedBytes / 1000000).toFixed(2)} MB</strong></div><div><span>Usable source file</span><strong>Unavailable</strong></div></div>
        <div class="unavailable">Playback requires the original audio file</div>
        <h3>Source needed</h3><p>The Looper X factory-content Resources and looper.db, with version and provenance.</p>
        <p class="note">The official current specification lists 302 loops. The 302 names here come from the older 1.0.0 cleanup list retained in 1.0.2. Their count alone does not prove current collection identity.</p>
        <details><summary>Exact file evidence</summary><p><code>${escape(row.name)}</code></p><p>${row.expectedBytes.toLocaleString()} bytes expected by Scripts/clean_factory_content, lines ${escape(row.cleanupLines)}.</p></details>`;
      return;
    }
    if (state.tab === 'singles') {
      $('detail').innerHTML = `<p class="state">Native Single FX schema unresolved</p><h2>${escape(row.name)}</h2>
        <p>The native Single FX identity exists. The prototype currently demonstrates controls borrowed from a rack.</p>
        <div class="facts"><div><span>Borrowed family</span><strong>${escape(row.borrowedFamily)}</strong></div><div><span>Borrowed preset</span><strong>${escape(row.borrowedPreset)}</strong></div></div>
        <div class="callout"><p>Rack membership does not establish the Single FX control set, order, ranges, enums or defaults.</p></div>
        <h3>Source needed</h3><p>An instantiated Single FX descriptor dump for this exact processor identity, including its controls, reset behavior and any mode conditions.</p>`;
      return;
    }
    const isEnable = row.status === 'module-enable';
    const family = catalogue.families.find(item => item.name === row.family);
    const native = constructorEvidence(data, row);
    const details = native ? `<details id="native-evidence"><summary>Inspect native constructor evidence</summary>
      <p>The ${escape(native.sourceKey)} name reaches builder <code>${native.builderAddress}</code> at call <code>${native.callAddress}</code>, native index ${native.nativeIndex}. The surrounding constructor has the exact 52-key Ed's Rack set.</p>
      ${native.floatArguments ? `<p>Five float arguments: <code>${native.floatArguments.map(n => Number(n.toPrecision(7))).join(', ')}</code><br>Format argument: <code>${escape(native.formatArgument)}</code></p>` : ''}
      ${native.stringListArguments ? `<p>Ordered string-list arguments: <code>${native.stringListArguments.map(escape).join(' · ')}</code></p><p>Two integer arguments: <code>${native.integerArguments.join(', ')}</code></p>` : ''}
      <p>These are captured arguments with builder calls intercepted. Their roles, final UI translation and reset behavior are unverified. They are not promoted to a domain or default.</p></details>` : '<div class="callout"><p>No completed native constructor-to-UI trace is available for this family and control.</p></div>';
    $('detail').innerHTML = `<p class="state ${isEnable ? 'established' : ''}">${isEnable ? 'Module enable established' : 'Native control contract unresolved'}</p>
      <h2>${escape(row.key)}</h2><p>${escape(row.family)} · ${escape(row.module)}</p>
      <div class="facts"><div><span>${isEnable ? 'Established values' : 'Native domain'}</span><strong>${isEnable ? 'Off / On' : 'Unverified'}</strong></div><div><span>Factory reset default</span><strong>Unverified</strong></div></div>
      <label class="saved">Inspect an exact saved preset<select id="preset">${family.presets.map(p => `<option value="${escape(p.id)}">${escape(p.name)}</option>`).join('')}</select></label>
      <div id="saved-value" class="source-value"></div><p class="note">This is a serialized preset value. It is not a factory reset default or a physical-unit conversion.</p>
      ${details}<h3>What completes this control</h3><p>${isEnable ? 'Verify the factory reset value and its provenance.' : 'Verify the instantiated translator, legal domain, curve, all option labels, factory reset value and any mode conditions.'}</p>`;
    const showSaved = () => {
      const value = presetValue(catalogue, row, $('preset').value);
      $('saved-value').innerHTML = value ? `<span>Saved source value</span><strong>${escape(Number(value.value.toPrecision(9)))}</strong>` : '<span>Value unavailable</span>';
    };
    $('preset').addEventListener('change', showSaved);
    showSaved();
  }

  function render() {
    document.querySelectorAll('[data-tab]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.tab === state.tab)));
    $('family-label').hidden = state.tab !== 'controls';
    $('status-label').hidden = state.tab !== 'controls';
    const rows = matching(data, state);
    const name = row => row.key || row.name;
    const selected = rows.find(row => name(row) === state.selection) || rows[0];
    state.selection = selected ? name(selected) : '';
    $('result-count').textContent = `${rows.length} ${state.tab === 'audio' ? 'historical audio references · 0 playable files' : state.tab === 'singles' ? 'Single FX identities · native schemas unresolved' : 'controls · saved values are not domains'}`;
    $('items').innerHTML = rows.map((row, index) => `<button class="item" data-index="${index}" aria-current="${row === selected}"><span><strong>${escape(name(row))}</strong><small>${escape(row.module || row.borrowedFamily || 'Historical factory audio reference')}</small></span><span class="${row.status === 'module-enable' ? 'established' : ''}">${row.status === 'module-enable' ? 'Off / On' : state.tab === 'audio' ? 'No audio' : 'Unresolved'}</span></button>`).join('');
    $('items').querySelectorAll('[data-index]').forEach(button => button.addEventListener('click', () => {
      state.selection = name(rows[Number(button.dataset.index)]);
      $('items').querySelectorAll('[aria-current]').forEach(item => item.setAttribute('aria-current', String(item === button)));
      renderDetail(rows[Number(button.dataset.index)]);
    }));
    renderDetail(selected);
  }
  document.querySelectorAll('[data-tab]').forEach(button => button.addEventListener('click', () => {
    state.tab = button.dataset.tab; state.search = ''; state.selection = ''; $('search').value = ''; render();
  }));
  $('family').addEventListener('change', () => {state.family = $('family').value; render();});
  $('search').addEventListener('input', () => {state.search = $('search').value; render();});
  $('status').addEventListener('change', () => {state.status = $('status').value; render();});
  $('download').addEventListener('click', () => {
    const url = URL.createObjectURL(new Blob([JSON.stringify(missingSources(data), null, 2)], {type:'application/json'}));
    const link = document.createElement('a'); link.href = url; link.download = 'looper-x-missing-source-evidence.json'; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  render();
})(typeof window === 'undefined' ? globalThis : window);
