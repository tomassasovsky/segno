// Deterministic author references reached through prototype controls.
exports.apply=async(page,review)=>{
 const click=id=>page.locator('[data-action='+JSON.stringify(id)+']').click();
 const open=scene=>page.goto('http://127.0.0.1:8768/fx-ux-prototype.html?review='+scene+'&canvas=actual');
 if(review==='closure-clear-custom'){await open('pedal-custom');await click('setup:clear-custom');}
 if(review==='closure-transpose-bypass'){await open('performance-transpose');await page.evaluate(()=>segnoDemo.dispatchMapping('command:transpose-bypass','reference'));}
 if(review==='closure-preset-export'||review==='closure-preset-import'){
  await open('my-presets');await click('fxpresets:export-all');await click('mediafx:location:usb');
  if(review==='closure-preset-import'){await click('mediafx:transfer');await page.waitForTimeout(800);await click('fxpresets:import');await click('mediafx:location:usb');await click('mediafx:file:preset-file-1');}
 }
 if(review==='closure-repair-destination'||review==='closure-repair-review'){
  await open('expression');for(const id of ['stage','settings','effects','rack:rack-1','rack-options','remove','remove-confirmed','stage','settings','pedal-setup','expression','expr:replace'])await click(id);
  if(review==='closure-repair-review'){await click('repair:destination:Guitar');await click('repair:target:%5B%22mix%22%2C%22Guitar%22%2C%22level%22%5D');}
 }
 await page.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode()));});
};
