// Deterministic captures of real gestures, shared by the browser audit and Pen export.
// These scene names are capture labels; the interactive URLs use the existing views.
const scenes = {
  'performance-feedback-ready': 'performance-tracks',
  'performance-feedback-hold': 'performance-tracks',
  'performance-feedback-fx-held': 'performance-fx',
  'performance-feedback-fx-released': 'performance-fx',
};
async function apply(page, name) {
  const foot = id => page.locator(`[data-action="perform:${id}"]`);
  if (name.includes('-fx-')) {
    await foot(4).dispatchEvent('pointerdown', {pointerId: 51, button: 0});
    await page.evaluate(() => dispatchEvent(new PointerEvent('pointerup', {pointerId: 51})));
    if (name.endsWith('-held')) await foot(5).dispatchEvent('pointerdown', {pointerId: 52, button: 0});
  } else if (name.endsWith('-hold')) {
    await foot(3).dispatchEvent('pointerdown', {pointerId: 53, button: 0});
    await page.clock.runFor(480);
  }
}
module.exports = {scenes, apply};
