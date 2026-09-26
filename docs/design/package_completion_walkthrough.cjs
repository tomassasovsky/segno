// Assemble captured clips into a chaptered recording without changing speed.
const fs=require('node:fs'),path=require('node:path'),{execFileSync}=require('node:child_process');
const dir=path.join(__dirname,'completion-previews','walkthroughs');
const clips=JSON.parse(fs.readFileSync(path.join(dir,'clips.json'),'utf8'));
if(clips.length!==7)throw Error('Seven complete clips are required.');
const concat=path.join(dir,'concat.txt');
fs.writeFileSync(concat,clips.map(c=>"file '"+c.file+"'").join('\n')+'\n');
execFileSync('ffmpeg',['-y','-loglevel','error','-f','concat','-safe','0','-i',concat,'-c','copy','-movflags','+faststart',path.join(dir,'all-flows.mp4')]);
fs.unlinkSync(concat);
let cursor=0;const chapters=clips.map(c=>{const row={title:c.title,start:Number(cursor.toFixed(3)),end:Number((cursor+c.seconds).toFixed(3)),file:c.file};cursor+=c.seconds;return row;});
fs.writeFileSync(path.join(dir,'chapters.json'),JSON.stringify(chapters,null,2)+'\n');
const time=n=>{const ms=Math.round(n*1000),h=Math.floor(ms/3600000),m=Math.floor(ms/60000)%60,s=Math.floor(ms/1000)%60;return [h,m,s].map(v=>String(v).padStart(2,'0')).join(':')+'.'+String(ms%1000).padStart(3,'0');};
fs.writeFileSync(path.join(dir,'chapters.vtt'),'WEBVTT\n\n'+chapters.map((c,i)=>(i+1)+'\n'+time(c.start)+' --> '+time(c.end)+'\n'+c.title+'\n').join('\n'));
execFileSync('ffmpeg',['-y','-loglevel','error','-ss','5','-i',path.join(dir,'all-flows.mp4'),'-frames:v','1','-q:v','3',path.join(dir,'poster.jpg')]);
console.log('Assembled '+Math.round(cursor)+' seconds with seven chapters.');
