// Synchronous prototype publication across the existing browser stores.
// This is recoverable from ordinary write failures, not power-loss atomicity.
(function(root){
  'use strict';
  function publish(storage, values){
    const keys=Object.keys(values), previous={}, written=[];
    try{for(const key of keys)previous[key]=storage.getItem(key);}
    catch{return {ok:false,restored:true,error:'Storage could not be read. Restore did not start.'};}
    try{
      for(const key of keys){
        if(values[key]===null)storage.removeItem(key);else storage.setItem(key,values[key]);
        written.push(key);
      }
      return {ok:true};
    }catch{
      let restored=true;
      for(const key of written.reverse())try{
        if(previous[key]===null)storage.removeItem(key);else storage.setItem(key,previous[key]);
      }catch{restored=false;}
      return {ok:false,restored,error:restored?'Restore could not be saved. Your previous setup is kept.':'Restore was interrupted and some saved settings could not be put back. Keep the backup connected and retry restore before restarting.'};
    }
  }
  const api={publish};root.SegnoApplianceStorage=api;
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof window==='undefined'?globalThis:window);
