(function (root) {
  'use strict';
  const esc = text => String(text).replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
  function render(module, moduleIndex, param, paramIndex, label) {
    const api = root.SegnoFxParameters, d = api.describe(module, param), id = `inline:${moduleIndex}:${paramIndex}`;
    const text = api.format(d, param[1]), caption = label || d.label;
    const heading = `<span class="inline-label"><span>${esc(caption)}</span><output data-value-for="${id}">${esc(text)}</output></span>`;
    if (d.type === 'switch' || d.type === 'enum') return `<div class="inline-control fx-typed-control" data-fx-type="${d.type}">${heading}<div class="fx-value-options" role="group" aria-label="${esc(module.name + ' ' + caption)}">${d.options.map(option => `<button data-action="fx-value:${moduleIndex}:${paramIndex}:${option.value}" class="quiet ${api.coerce(d,param[1]) === option.value ? 'selected' : ''}" aria-pressed="${api.coerce(d,param[1]) === option.value}">${esc(option.label)}</button>`).join('')}</div></div>`;
    return `<label class="inline-control fx-typed-control" data-fx-type="${d.type}" title="${esc(d.note)} Exact stored value: ${esc(param[1])}">${heading}<input type="range" data-action="${id}" aria-label="${esc(module.name + ' ' + caption)}" aria-valuetext="${esc(text)}" min="0" max="1" step="any" value="${param[1]}" style="--amount:${param[1]*100}%">${d.type === 'unresolved' ? '<span class="fx-source-note">Scale unverified</span>' : ''}</label>`;
  }
  const api = {render};
  root.SegnoFxControls = Object.freeze(api);
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
