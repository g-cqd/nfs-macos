# Standalone x64 TF probe

The original EA-lab Wine runtime passed all seven checks in a separate prefix. The probe received exactly three Windows `EXCEPTION_SINGLE_STEP` exceptions and returned normally. It does not test x86 debug-register breakpoint delivery.

## Result

Test environment: Apple Silicon, macOS 27, custom Wine 11 from CrossOver 26.3. The runtime was `/Users/gc/Games/NFSMW-tools/ea-app-lab/Wine/bin/wine`; its `lib/wine/x86_64-unix/ntdll.so` SHA-256 was `3bc4baa14ae578036896e1cee462871e52a3815a7624bc35ed8292a5bc7508ba`.

| Test | Process exit | Checks | Exceptions | Overflow |
| --- | --- | --- | --- | --- |
| TF enabled | 0 | 7 passed, 0 failed | 3 | 0 |
| TF disabled mutation | 1 | 4 passed, 3 failed | 0 | 0 |

The enabled probe reported `0x80000004` at instruction offsets `0xe`, `0xf`, and `0x10`. Both `CONTEXT.Rip` and `ExceptionAddress` matched those boundaries. Each delivered context had `EFlags=0x202`, with TF clear. Both the ordinary and stepped fixtures returned `0x42` with TF clear.

The mutation replaced both `$0x100` operands in a temporary assembly copy with `$0x0`. It retained ordinary return behavior and failed all three exception checks. The temporary source and executable were removed. Logs are `tf.log` and `disabled-tf.log`.

The first attempt hit a 60-second deadline during prefix initialization, before the probe started. `prefix-initialization.log` preserves that infrastructure result. A second attempt used the same newly created prefix with Mono/Gecko loading disabled and a 90-second deadline; both tests completed. Only this prefix's server was stopped afterward.

## Source and checks

- `step-fixture.S` adapts `single_stepcode` from [Wine source at the tested commit](https://github.com/g-cqd/wine/blob/f064add996bbf4819acf49f48bab263735279800/dlls/ntdll/tests/exception.c#L3170). It adds a return value after the last stepped instruction.
- `step-probe.c` installs a vectored handler for its calling thread and fixture address range. Wine's adjacent `single_step_handler` supplies the expected three exceptions and cleared TF in delivered contexts.
- The handler stores at most four events and re-arms TF only after its first two accepted exceptions. A fifth accepted event continues the normal exception search rather than repeating indefinitely.
- The assembly has no loop. It executes only its own image code and never writes an instruction or a debug register.
- Output records Windows exception counts, not a separate measurement of Mach or POSIX signal counts.

The sources use Wine's LGPL-2.1-or-later license. Wine's license text is included as `COPYING.LIB`.

## Build

Run from this directory. The verified compiler was MinGW GCC 16.1.0. This command completed without warnings:

```sh
/opt/homebrew/bin/x86_64-w64-mingw32-gcc \
  -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  -o step-probe.exe step-probe.c step-fixture.S
```

Exit status `0` means all checks passed; `1` means a capability check failed; `2` means initial-state or handler setup/teardown failed. An unhandled exception or external deadline is a separate infrastructure/runtime failure.

## Isolated run

The following runner creates a uniquely named private test directory, uses only its probe prefix, removes inherited runtime overrides, applies a deadline, and stops only the selected prefix's server. Run it from this directory after building and set `NFS_PROBE_WINE_BIN` to the chosen runtime’s `bin` directory:

```python
import os
from pathlib import Path
import subprocess
import tempfile
import shutil
import uuid

root = Path.cwd().resolve()
runtime = Path(os.environ["NFS_PROBE_WINE_BIN"]).resolve()
env = os.environ.copy()
for name in list(env):
    if name.startswith(("WINE", "DXVK", "DXMT", "D3DM", "CX_", "DYLD_")):
        del env[name]
work = Path(tempfile.mkdtemp(prefix="nfs2015-step-"))
owner = uuid.uuid4().hex
marker = work / ".nfs2015-step-owner"
marker.write_text(owner)
env.update(
    WINEPREFIX=str(work / "prefix"),
    WINEDEBUG="-all",
    WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree,mshtml=",
)
try:
    result = subprocess.run(
        [str(runtime / "wine"), str(root / "step-probe.exe")],
        env=env, timeout=90, check=False,
    )
    print("probe exit:", result.returncode)
finally:
    if marker.read_text() != owner:
        raise RuntimeError("Probe ownership changed; retain the directory for inspection")
    subprocess.run([str(runtime / "wineserver"), "-k"], env=env, timeout=10, check=False)
    # Only delete after the selected server has exited; retain on timeout/failure.
    subprocess.run([str(runtime / "wineserver"), "-w"], env=env, timeout=15, check=True)
    shutil.rmtree(work)
```

The generated prefix, executable, and logs are local test artifacts. They contain no EA login or game installation and should stay outside source control.

## Limits

This result establishes TF stepping and resumption for one short, straight-line x64 fixture under this runtime. It does not establish full instruction coverage, sustained stepping performance, cross-thread operation, or debugger behavior. It does not implement the DR0–DR7 breakpoint contract, demonstrate that NFS executes its configured breakpoint target, or identify the cause of the NFS startup exit. No game code, EA prefix, runtime source, relay, or context candidate was changed.
