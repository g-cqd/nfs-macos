import argparse,importlib.util,tempfile
from pathlib import Path
ROOT=Path(__file__).parent
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
clock=load('clock',ROOT/'capture-window.py')
parser=argparse.ArgumentParser();parser.add_argument('--common-module',type=Path,default=ROOT/'collect-dxvk-markers.py');args=parser.parse_args()
common=load('common',args.common_module)
integration=load('integration',ROOT/'capture-lifecycle.py')
def expect(x):
 if not x:raise AssertionError('lifecycle integration invariant')
def make(root):
 p=root/'observer.log';p.touch();w=clock.CaptureWindow(0,900,180);return p,w,integration.LifecycleCapture(w,common.Tail(p),common.Lines(),common.Lifecycle())
def append(path,data):
 with path.open('ab') as f:f.write(data)
boot=b'observing_pid=100 hex=0064 parent_pid=1\n';bootexit=b'pid=100 exit_code=0x000186aa elapsed_observation_ms=10\n'
full=b'observing_pid=200 hex=00c8 parent_pid=100\n';failed=b'pid=200 exit_code=0xfffffffa elapsed_observation_ms=100\n'
with tempfile.TemporaryDirectory(prefix='ea-lifecycle-test-') as d:
 p,w,sut=make(Path(d));append(p,boot);expect(sut.poll(1,None) is None);expect(w.phase=='active')
 append(p,bootexit);expect(sut.poll(2,None) is None);expect(sut.lifecycle.full is None)
 expect(sut.poll(3,None) is None and sut.lifecycle.full is None)
 append(p,full);expect(sut.poll(4,None) is None and sut.lifecycle.full==200)
 append(p,failed);expect(sut.poll(5,None)=='first_full_exit');expect(sut.lifecycle.first_full_exit['windows_pid']==200);expect(w.deadline==181)
with tempfile.TemporaryDirectory(prefix='ea-lifecycle-test-') as d:
 p,w,sut=make(Path(d));expect(sut.poll(1,7)=='observer_exited');expect(sut.observer_exit==7 and w.phase=='waiting')
with tempfile.TemporaryDirectory(prefix='ea-lifecycle-test-') as d:
 p,w,sut=make(Path(d));append(p,boot[:8]);expect(sut.poll(1,None) is None and w.phase=='waiting');append(p,boot[8:]);expect(sut.poll(2,None) is None and sut.lifecycle.active==100)
with tempfile.TemporaryDirectory(prefix='ea-lifecycle-test-') as d:
 p,w,sut=make(Path(d));append(p,boot);sut.poll(1,None);p.write_bytes(b'');expect(sut.poll(2,None)=='observer_changed' and sut.lifecycle.ambiguous)
with tempfile.TemporaryDirectory(prefix='ea-lifecycle-test-') as d:
 p,w,sut=make(Path(d));append(p,boot+bootexit+full+failed+b'bad\n');expect(sut.poll(1,None)=='observer_ambiguous');expect(sut.lifecycle.first_full_exit is None)
with tempfile.TemporaryDirectory(prefix='ea-lifecycle-test-') as d:
 p,w,sut=make(Path(d));append(p,b'observing_');expect(sut.poll(1,0)=='observer_partial')
with tempfile.TemporaryDirectory(prefix='ea-lifecycle-test-') as d:
 p,w,sut=make(Path(d));append(p,boot+bootexit+full+failed);expect(sut.poll(900,None)=='wait_deadline');expect(w.phase=='waiting' and sut.lifecycle.first_full_exit is None)
print('PASS incremental lifecycle, idle repoll, observer early exit, split line, rewrite, invalid suffix, and partial exit checks')

# Cleanup failures must not replace the observed stop reason or skip final state.
import io,subprocess
class ObserverDouble:
 def __init__(self,waits,terminate_error=None,kill_error=None):
  self.waits=list(waits);self.terminate_error=terminate_error;self.kill_error=kill_error;self.killed=False;self.wait_limits=[]
 def poll(self):return None
 def terminate(self):
  if self.terminate_error:raise self.terminate_error
 def kill(self):
  self.killed=True
  if self.kill_error:raise self.kill_error
 def wait(self,timeout):
  self.wait_limits.append(timeout);result=self.waits.pop(0)
  if isinstance(result,Exception):raise result
  return result

def fail_games():raise subprocess.TimeoutExpired('scoped_games',3)
observer=ObserverDouble([subprocess.TimeoutExpired('owned_observer',5),-9]);stream=io.BytesIO();state={'capture_active':True};saved=[]
integration.finish_capture(observer,stream,state,'first_full_exit',fail_games,lambda value:saved.append(dict(value)))
expect(stream.closed and observer.killed and observer.wait_limits==[5,2])
expect(state['capture_active'] is False and state['stop_reason']=='first_full_exit' and saved[-1]['capture_active'] is False)
expect({x['step'] for x in state['cleanup_errors']}=={'game_cleanup','observer_wait'})

class FailingStream(io.BytesIO):
 def close(self):
  super().close();raise OSError('simulated close failure')
observer=ObserverDouble([OSError('wait failure'),subprocess.TimeoutExpired('owned_observer',2)],OSError('terminate failure'),OSError('kill failure'));stream=FailingStream();state={'capture_active':True};saved=[]
integration.finish_capture(observer,stream,state,'observer_exited',None,lambda value:saved.append(dict(value)))
expect(stream.closed and observer.killed and saved[-1]['stop_reason']=='observer_exited')
expect({x['step'] for x in state['cleanup_errors']}=={'observer_terminate','observer_wait','observer_kill','observer_final_wait','stream_close'})

observer=ObserverDouble([0]);stream=io.BytesIO();state={}
def fail_status(value):raise OSError('simulated status failure')
integration.finish_capture(observer,stream,state,'wait_deadline',None,fail_status)
expect(stream.closed and state['capture_active'] is False and state['stop_reason']=='wait_deadline')
expect(state['cleanup_errors'][-1]['step']=='status_write' and state['status_persisted'] is False)
print('PASS cleanup timeout, cleanup failures, bounded observer fallback, stream closure, final state, and status-write failure checks')
class ExitedObserver(ObserverDouble):
 def poll(self):return 0
observer=ExitedObserver([]);stream=io.BytesIO();state={}
integration.finish_capture(observer,stream,state,'observer_exited',None,lambda value:None)
expect(stream.closed and not observer.killed and observer.wait_limits==[] and state['cleanup_errors']==[])
print('PASS already-exited observer receives no termination or wait')
