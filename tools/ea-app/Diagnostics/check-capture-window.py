import importlib.util
from pathlib import Path
s=importlib.util.spec_from_file_location('capture_window',Path(__file__).with_name('capture-window.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
def expect(v):
 if not v:raise AssertionError('capture timing invariant')
w=m.CaptureWindow(100.0,900.0,180.0)
expect(w.phase=='waiting' and w.remaining(999.999)>0)
expect(w.observe_start(999.999) and w.phase=='active')
expect(abs(w.remaining(999.999)-180.0)<1e-6)
expect(not w.observe_start(1100.0) and abs(w.deadline-1179.999)<1e-6)
expect(w.remaining(1179.999)==0)
w=m.CaptureWindow(0,900,180);expect(not w.observe_start(900) and w.phase=='waiting' and w.remaining(900)==0)
w=m.CaptureWindow(100,900,180);expect(not w.observe_start(99) and w.remaining(99)==0)
w=m.CaptureWindow(100,900,180);expect(w.observe_start(100) and w.deadline==280)
for values in ((0,0,180),(0,900,0),(float('nan'),900,180),(0,float('inf'),180)):
 try:m.CaptureWindow(*values)
 except ValueError:pass
 else:raise AssertionError('invalid timing accepted')
print('PASS waiting/active deadline, exact expiry, no extension, backward time, immediate start, and invalid bounds')
