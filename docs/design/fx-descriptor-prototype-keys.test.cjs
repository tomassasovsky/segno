const test=require('node:test'),assert=require('node:assert/strict');
const descriptors=require('./fx-parameter-descriptors.js'),presets=require('./fx-preset-library.js');
for(const name of ['constructor','toString','__proto__'])test('portable custom effect name '+name+' does not collide with descriptor table internals',()=>{
 const [preset]=presets.decode(JSON.stringify({format:presets.format,version:presets.version,presets:[{name:'Custom effect',family:'Single FX',modules:[{name,params:[['Gain',.5,'',.5]],sourceValues:true}]}]}));
 const module=preset.modules[0],parameter=module.params[0];
 assert.equal(descriptors.enabled(module),true);assert.equal(descriptors.describe(module,parameter).type,'unresolved');descriptors.write(module,parameter,.25);assert.equal(parameter[1],.25);
});
