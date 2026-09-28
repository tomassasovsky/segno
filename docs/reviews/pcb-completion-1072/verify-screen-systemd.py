import subprocess,time,json
from pathlib import Path
container='segno-screen-systemd-1072'
def command(*args):
 return subprocess.check_output(['docker','exec',container,*args],text=True)
def wait_for(text):
 end=time.monotonic()+8
 while time.monotonic()<end:
  data=command('cat','/tmp/events')
  if text in data:return data
  time.sleep(.05)
 raise AssertionError(data)
def reset():
 command('systemctl','stop','segno','weston')
 command('sh','-c',': > /tmp/events')
def check_sequence(events,sequence):
 start=0
 for item in sequence:
  start=events.index(item,start)+len(item)
results={}
reset();command('systemctl','start','segno');wait_for('app start')
command('systemctl','stop','segno','weston');data=command('cat','/tmp/events')
check_sequence(data,['gpio 1','weston start','app start','app stop','gpio 0','weston stop'])
results['orderly_stop']=data.splitlines()
reset();command('systemctl','start','segno');wait_for('app start')
command('systemctl','restart','segno');data=wait_for('weston stop')
# Wait for restart app, not merely the first app start.
end=time.monotonic()+8
while time.monotonic()<end:
 data=command('cat','/tmp/events')
 if data.count('app start')==2:break
 time.sleep(.05)
check_sequence(data,['app stop','gpio 0','weston stop','gpio 1','weston start','app start'])
results['restart']=data.splitlines()
reset();command('systemctl','start','segno');wait_for('app start')
command('systemctl','kill','--signal=KILL','segno-screen-power')
wait_for('release');command('systemctl','stop','weston','segno')
data=command('cat','/tmp/events')
assert 'gpio 0' in data and 'release' in data
check_sequence(data,['gpio 0','settled 0','weston stop'])
assert command('systemctl','show','weston','-p','ActiveState','--value').strip() in ('inactive', 'failed')
results['keeper_sigkill']=data.splitlines()
print(json.dumps(results,indent=2))
Path('/tmp/segno-screen-systemd-results.json').write_text(json.dumps(results,indent=2)+'\n')
