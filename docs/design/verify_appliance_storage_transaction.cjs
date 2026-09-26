const {test}=require('node:test');
const assert=require('node:assert/strict');
const {publish}=require('./appliance-storage-transaction.js');
function storage(fail=()=>false){const values=new Map([['rig','old session'],['display','old display']]);let writes=0;return {values,getItem:key=>values.get(key)??null,setItem:(key,value)=>{if(fail(++writes,key,value))throw Error('write failed');values.set(key,value);},removeItem:key=>{if(fail(++writes,key,null))throw Error('write failed');values.delete(key);}};}
test('publishes every section including new and removed keys',()=>{const s=storage();assert.deepEqual(publish(s,{rig:'new session',display:null,midi:'new MIDI'}),{ok:true});assert.deepEqual([...s.values],[['rig','new session'],['midi','new MIDI']]);});
test('middle write failure restores every earlier key',()=>{const s=storage(n=>n===3),before=[...s.values];const result=publish(s,{rig:'new',newKey:'new',display:'new'});assert.equal(result.ok,false);assert.equal(result.restored,true);assert.deepEqual([...s.values],before);});
test('rollback failure is distinct and never reports the old setup intact',()=>{const s=storage(n=>n>=2),result=publish(s,{rig:'new',display:'new'});assert.equal(result.ok,false);assert.equal(result.restored,false);assert.match(result.error,/could not be put back/);});
test('read failure starts no writes',()=>{let wrote=false;const result=publish({getItem:()=>{throw Error('unreadable');},setItem:()=>{wrote=true;}},{rig:'new'});assert.equal(result.ok,false);assert.equal(wrote,false);});
