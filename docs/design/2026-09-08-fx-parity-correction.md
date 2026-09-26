# FX parameter and personal preset correction

September 8, 2026. Prototype implementation only. The reference files remain
unchanged. No production application, engine, firmware, commit or deployment is
part of this slice.

## Implemented modules

- `fx-parameter-descriptors.js` provides one descriptor and value contract for
  direct controls and mappings. It covers every source key, including the
  twenty family entries previously hidden by the name regex. Exact module power
  aliases include `Chor`, `Comp`, `Para EQ`, `Dist`, `Oct` and `HP/Gate`.
- Rack modules use their title power button for enable state. The duplicate
  Off/On row is omitted from the rack parameter list; the source enable value
  remains intact and available to mappings. Other imported values remain
  directly editable and visibly say **Source** and
  **Scale unverified**. `Amp Modern` stays present. Controls retain exact loaded
  values until an edit, and reset means the loaded preset value. It does not
  pretend that this is the native algorithm's factory default.
- `fx-preset-library.js` adds rename, delete/undo, per-preset/all export, file
  import and import review. Renaming or deleting a personal preset does not
  mutate any rack instance. Imports create independent copies, retain original
  source records and edited values, and number duplicate names. Runtime mapping
  identities and instance placement/activation are excluded from interchange.
- `fx-parity.css` follows the existing blue-gray palette and bottom keyboard.

## Evidence and remaining native questions

The original extracted `AppUI/Pages/FxEdit/Parameter.qml` explicitly renders
`TwoStateValue`, `DiscreteValue` and other translator types differently.
`ParamsPanel.qml` reads each native parameter's `trans`, `stringNoUnits` and
`stringUnits`, and associates it with the native bypass parameter. These QML
files do not contain the per-parameter translator definitions. The source
records and native label vocabulary establish the module-enable aliases. The
test checks their values in all 159 supplied presets, including disabled
modules, rather than treating only the long display name as the source key.

Other native type/scale/option/default tables remain unverified. Adjacent native
strings (cabinet names, reverb names, rhythmic divisions, scale names) are
vocabulary evidence, not a proven parameter-to-option-value mapping. No such
table was invented. The descriptor's 0–1 interval is the serialized source
domain, and `nativeRangeVerified` is false for unresolved controls. Observed
preset minima/maxima do not constrain the editor.

Single FX remains a separate native verification gate: all 26 prototype entries
borrow controls from rack records. Keep `sourceFamily`, `sourcePresetId` and
`parameterSourcePresetId` on modules so those values cannot masquerade as
recovered native Single FX schemas. The prototype has no audio engine; this
work establishes value editing and preset handling, not equivalent sound.

The portable format is `segno.fx-preset-library`, version 1, with a `presets`
array. It is a concrete JSON interchange for this Segno prototype, not a claim
to write Looper X `.fxpreset` files. It validates a whole package before saving
and rejects malformed values, unsupported versions and invalid artwork paths.
The browser download/file chooser is actual file interchange. USB appliance
access belongs to the media/device implementation and remains separate.

## Shared parameter target contract

`SegnoFxParameters.targets(rig, {locationLabel, artworkRoot})` returns all source
parameters with the existing `['fx', rackId, moduleId, sourceKey]` target key.
It has no name-based exclusion filter. Each target provides:

```js
{ key, destination, detail, label, art,
  type, min, max, step, options, defaultValue, descriptor, resolution,
  format(value), parse(text), coerce(value), get(), set(value), persist(state, value) }
```

`type` is `switch`, `continuous`, `enum` (supported when verified options exist)
or `unresolved`. Switch writes snap to 0/1. Mapping an explicit module enable
also clears the prototype's additional module-bypass flag. Unresolved writes
retain source-normalized values and display their status in every picker.
`toNormalized`/`fromNormalized` are identity mappings within the serialized
domain; they are not physical-unit conversions.

Across the nine family schemas, the descriptors identify 61 module-enable
entries and explicitly mark the remaining 239 source entries unresolved. These
counts concern family-specific keys, not native Single FX schemas or algorithms.

## Main HTML integration (coordinator owns this file)

Load `fx-parity.css`, then `fx-parameter-descriptors.js`,
`fx-parameter-controls.js` and `fx-preset-library.js` before the main inline
script. The helpers do not depend on load order of the factory catalogue.

1. In `modulesFromPreset`, add `sourceFamily:family, sourcePresetId:p.id` to each
   new module. Preserve these properties when creating racks and Single FX.
2. Remove `enableKeys`; use:

   ```js
   const fxParameters = window.SegnoFxParameters;
   const moduleEnabled = fxParameters.enabled;
   const parameterLabel = fxParameters.label;
   const parameterValue = p => fxParameters.format(
     fxParameters.describe({name:'',sourceValues:p[0]!=='Pan',params:[p]},p),p[1]);
   const inlineControl = (m,mi,p,pi,label) => window.SegnoFxControls.render(m,mi,p,pi,label);
   const inlineModule = mi => mi===-1 ? {name:'Channel',params:[channels().pan]} : rack().modules[mi];
   ```

3. Keep original parameter indexes with `m.params.map((p,pi)=>({p,pi}))`.
   In `chainBody`, omit only descriptors with `role === 'enable'`: each module's
   title already controls that same state. Do not filter by approximate name;
   all sound parameters, including Amp Modern, remain visible. The single-effect
   screen and mapping descriptors retain their existing controls.
4. Replace the `module-power` action body with
   `fxParameters.setEnabled(m,!moduleEnabled(m)); save(); render();`.
   `singleDefinition` uses `fxParameters.powerParameter(module)` when enabling
   its copied module. No source factory record is modified.
5. Before generic action handling, handle `fx-value:mi:pi:value`:

   ```js
   if (action==='fx-value') {
     const [mi,pi,v]=parts.map(Number);
     fxParameters.write(inlineModule(mi),inlineParam(mi,pi),v);
     save(); render(); return;
   }
   ```

   Keep this after the existing `const [action,...parts]` declaration.
6. `adjustInline` delegates to `fxParameters.write(inlineModule(mi),p,value)`.
   The encoder branch computes `fxParameters.turn(fxParameters.describe(m,p),
   p[1],delta)`. Touch input uses `write`, then updates output with
   `format(describe(m,p),p[1])`. Existing commit/cancel/double-tap-reset handling
   remains; reset restores the exact loaded `p[3]` value.
7. In `expressionTargets`, retain the non-FX targets and replace the entire
   rack/module/parameter loop with
   `list.push(...fxParameters.targets(rig,{locationLabel,artworkRoot}));`.
8. Instantiate the preset UI after `createRack` is in scope (its declaration
   is hoisted):

   ```js
   const fxPresetUI = window.createFxPresetLibraryStudy({
     button,header,icon,escape,render,focus:setFocus,notice:notify,
     artwork:soundArtwork,load:createRack,read:()=>rig.saved,
     write:next=>{const prior=rig.saved;rig.saved=next;save();
       if(!review&&!storageOK){rig.saved=prior;return false;}return true;}
   });
   ```

9. Replace the `page==='saved'` body with `fxPresetUI.body()`. In the overlay
   selection add `page==='saved'?fxPresetUI.overlay():` before `modalBody()`.
   Early in `activate`, use `if(fxPresetUI.action(id))return;`. At the start of
   `back`, use `if(page==='saved'&&fxPresetUI.back())return;`. `go` and Stage
   navigation should call `fxPresetUI.leave()` when leaving My presets.
10. Optional browser QA hooks:
    `fxPresetState:fxPresetUI.snapshot, importFxPresets:fxPresetUI.receive`.

The existing Save preset keyboard and duplicate-replace flow remain in the
main HTML. My presets management uses the same fixed bottom naming keyboard,
with no enlarged generic parameter popup.

## Verification

Run `node --test docs/design/fx-parity.test.cjs`. Nine behavior tests passed
against the actual catalogue and the main prototype conversion functions:
159 source presets, 300 family entries, source equality/default preservation,
factory switch states, hidden control visibility, touch/encoder/mapping
coercion, independent snapshot writes, channel balance, rename/delete/undo,
failed storage rollback, raw+edited-value interchange, duplicate names,
malformed package rejection and import review before mutation.

`node docs/design/fx-parity.browser.cjs` also passed in Chrome with Playwright:
the real browser file chooser and download, import review before mutation,
rename, delete/undo, a bottom-anchored naming keyboard, visible `Amp Modern`,
and switch/source controls. The isolated fixture uses the current main-page
styles and actual source records; it reported no browser errors. Set
`SEGNO_CHROME_EXECUTABLE` for a different Chrome installation and
`SEGNO_FX_SCREENSHOT` for an optional screenshot output.

Main-page browser integration and Pen synchronization are coordinator-owned
checks. A successful module test does not claim that the shared HTML or Pen
already contains its integration edits.


Main integration review also covered custom portable module names that collide
with JavaScript object prototypes (`constructor`, `toString`, `__proto__`).
Descriptor enable-key lookup now accepts only own table keys; these names stay
unresolved editable source controls and do not crash. The independent
`fx-descriptor-prototype-keys.test.cjs` covers all three imports. Shared mapping
targets now expose `encoderStep` separately from touch precision `step`, so five
encoder ticks use the same 0.05 normalized movement as direct FX editing.
