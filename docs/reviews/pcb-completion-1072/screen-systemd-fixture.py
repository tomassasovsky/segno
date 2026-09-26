from pathlib import Path
import shutil
base=Path('/src/deploy/yocto/meta-segno/recipes-segno/segno-bundle/files')
units=Path('/etc/systemd/system')
shutil.copy(base/'segno-screen-power.service', units)
(units/'weston.service.d').mkdir(exist_ok=True)
shutil.copy(base/'30-segno-screen-power.conf', units/'weston.service.d')
(units/'weston.service').write_text('''[Unit]
PartOf=segno.service
[Service]
Type=notify
ExecStart=/usr/bin/fixture-display weston
''')
(units/'segno.service').write_text('''[Unit]
After=weston.service
Requires=weston.service
[Service]
ExecStart=/usr/bin/fixture-display app
Restart=always
RestartSec=1
''')
Path('/usr/bin/segno-screen-power').write_text('''#!/usr/bin/python3
import importlib.machinery, importlib.util, sys, types, time, fcntl, errno
loader=importlib.machinery.SourceFileLoader('power', '/src/deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-screen-power')
spec=importlib.util.spec_from_loader(loader.name, loader)
power=importlib.util.module_from_spec(spec); loader.exec_module(power)
sys.modules['gpiod.line']=types.SimpleNamespace(Value=types.SimpleNamespace(ACTIVE=1, INACTIVE=0))
class Request:
 def __init__(self):
  self.fd=open('/tmp/gpio.lock','w')
  try: fcntl.flock(self.fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError:
   self.fd.close(); raise OSError(errno.EBUSY,'GPIO owned')
 def __enter__(self): return self
 def __exit__(self,*a):
  with open('/tmp/events','a') as f: f.write('release\\n')
  self.fd.close()
 def set_value(self,line,value):
  with open('/tmp/events','a') as f: f.write('gpio '+str(value)+'\\n')
power.request_gpio=Request
power.ON_DELAY=power.OFF_DELAY=0.05
original_set=power.set_power
def set_power(request,enabled):
 original_set(request,enabled)
 with open('/tmp/events','a') as f: f.write('settled '+str(int(enabled))+'\\n')
power.set_power=set_power
power.main()
''')
Path('/usr/bin/fixture-display').write_text('''#!/usr/bin/python3
import signal,sys,time,os,socket
name=sys.argv[1]
def log(value):
 with open('/tmp/events','a') as f: f.write(name+' '+value+'\\n')
def stop(*_):
 log('stop');sys.exit(0)
signal.signal(signal.SIGTERM,stop)
log('start')
if 'NOTIFY_SOCKET' in os.environ:
 with socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM) as notify:
  notify.connect(os.environ['NOTIFY_SOCKET']); notify.sendall(b'READY=1')
while True: time.sleep(1)
''')
for p in ['/usr/bin/segno-screen-power','/usr/bin/fixture-display']:Path(p).chmod(0o755)
