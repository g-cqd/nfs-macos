# Windows x64 debug-register regression probes

`context-probe.c` tests the Windows x64 thread-context contract independently of
Need for Speed. It creates its own suspended worker threads and never opens the
EA app, the game, account files, or another process. Every context write sets
`DR7=0`, so the probe requests no enabled hardware breakpoints.

## Build

```sh
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  -o context-probe.exe context-probe.c
```

## Run in an isolated prefix

The executable takes no arguments. Use a dedicated prefix, with no EA app or
game processes. For the isolated candidate runtime:

```sh
WINEPREFIX="$PWD/Prefix-probe" \
WINEDEBUG=-all \
  "$PWD/Wine-candidate/bin/wine" \
  "$PWD/context-probe.exe"
```

Keep the matching candidate `bin/wineserver` beside this `bin/wine`. This Wine
loader tries the adjacent server before the `WINESERVER` environment variable
(`dlls/ntdll/unix/loader.c`, `exec_wineserver`). Setting
`WINESERVER` alone therefore does not select the candidate when an adjacent
server exists. Let the loader start its matching server in a fresh dedicated
prefix; manually starting a server introduces a race with loader startup.

On native x64 Windows, run `context-probe.exe` directly. A native Windows control
run is useful before changing runtime behavior. Compilation alone does not
establish Windows conformance or reproduce the Wine failure.

Exit codes: `0` means all checks passed; `1` means a context contract check failed;
`2` means setup or cleanup failed and the run is incomplete. The summary reports
check, failure, and infrastructure-error counts. Failed register comparisons
print only addresses of this probe's marker storage and returned register values.
A complete run with all writes accepted performs 24 checks. The original 21
checks remain intact; the final three examine persistence across resumption.

## Verified comparison on 2026-09-26

Both logs below come from comparisons with the intended adjacent server selected.
The earlier `candidate-final` failure is not a valid candidate result because
the harness had not reliably selected that server.

| Server behavior | Checks | Failures | Infrastructure errors | Evidence |
| --- | ---: | ---: | ---: | --- |
| Baseline | 24 | 1 | 0 | `baseline-verified.log` (private result) |
| Candidate with target-owned register state | 24 | 0 | 0 | `candidate-verified.log` (private result) |

The baseline accepted the register write and preserved values while the worker
remained suspended. After resumption and a second suspension, `DR0` through `DR3`
read back as zero. The candidate preserved all four values. Its isolated source
change keeps register state on the target thread in `server/mach.c`,
`server/thread.h`, and `server/thread.c` under `nfs2015-context-src`.

These results establish persistence for the tested disabled-breakpoint contexts.
They do not establish hardware-breakpoint delivery or playable game startup.

## Behaviors examined

- A suspended worker preserves accepted `DR0` through `DR3` values.
- `OpenThread` and `DuplicateHandle` aliases observe the same target state.
- Writes to one target do not change another target's values.
- Writing through an alias updates the target's other handles.
- Closing and reopening an alias preserves the target state.
- Clearing the registers replaces previously stored values.
- A replacement worker starts clear after the first worker exits, accepts its
  own values, and leaves the surviving second worker unchanged.
- A null thread handle is rejected for both context APIs.
- A fourth worker accepts values while suspended and preserves them after
  resumption, an event handshake from the worker, and a second suspension.

`DR6` is not compared. Only the low eight enable bits of returned `DR7` must be
zero; reserved-bit normalization does not fail the test. The probe does not test
breakpoint delivery, current-thread contexts, forced thread-ID reuse, or
cross-process contexts. Fresh-thread initialization assumes an ordinary launch
without an attached debugger. It does not claim a game fix.

Memory and work are bounded: four worker lifetimes, at most two live workers,
two unnamed events, fixed context data, and fixed marker storage. The first three
workers return immediately when resumed. The fourth signals its started event
and waits on its completion event. The controller observes that handshake before
suspending the worker again and reading its context. No running-thread context
is read. Cleanup signals completion, resumes the worker if suspended, and joins
it before closing the events.

The handshake and cleanup waits each have a five-second watchdog. A watchdog
failure reports an infrastructure error; no assertion depends on elapsed time.
If a worker cannot be joined, its events remain valid until process exit instead
of being closed during a pending wait. There are no sleeps or polling loops.
API calls themselves are synchronous and are not covered by an external process
timeout.

## Execution-breakpoint delivery probe

`execution-breakpoint-probe.c` separately tests an enabled execution breakpoint
in its own suspended worker. It does not modify executable code, attach a
debugger, or access another process. Run it without an attached debugger.

```sh
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  -o execution-breakpoint-probe.exe execution-breakpoint-probe.c

WINEPREFIX="$PWD/Prefix-execution-probe" \
WINEDEBUG=-all \
  "$PWD/Wine-candidate/bin/wine" \
  "$PWD/execution-breakpoint-probe.exe"
```

It takes no arguments and uses the same exit-code meanings as the context probe.
A complete run has four checks:

1. `SetThreadContext` accepts `DR0=worker_main` and `DR7=1`.
2. Suspended readback retains the address and slot-zero execution configuration.
3. Exactly one `EXCEPTION_SINGLE_STEP` reaches the vectored exception handler
   on the intended thread, with both `ExceptionAddress` and `RIP` equal to the
   worker address, before the worker body runs.
4. After the handler clears slot zero in the supplied exception context, the
   worker body executes once and returns its expected exit code.

The address is the exact noinline function pointer passed to `CreateThread`.
The suspended thread's initial `RIP` may point to a system startup thunk; that
address is not used as the breakpoint target. `DR6` is logged for diagnosis but
is not a pass condition. Reserved `DR7` bits are ignored during readback.

The probe owns one thread and one handler. Its shared counters use Interlocked
operations. It joins the worker with a five-second watchdog, without sleeps or
polling. The handler permits at most two matching continuations before passing
a repeated exception onward, preventing an unbounded handler loop if clearing
the breakpoint is ineffective. Unrelated exceptions are never swallowed.
The handler is removed after the worker joins. If joining fails, the handler
and its static state remain valid until process exit. Synchronous API calls are
not covered by the watchdog.

The executable was compiled with warnings treated as errors. Runtime results
must be recorded separately; compilation does not establish breakpoint delivery.
Passing establishes this owned-code execution-breakpoint case only, not all
debug-register behavior or game compatibility.

## Contract sources

Microsoft documents suspended targets for valid
[GetThreadContext](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getthreadcontext)
results, and explicitly says current-thread results are invalid.
[SetThreadContext](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setthreadcontext)
also requires a suspended target and permits normalization of OS-controlled bits.
[CreateThread](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createthread)
defines `CREATE_SUSPENDED` and the thread handle's lifetime.
[CreateEventW](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createeventw)
and [SetEvent](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setevent)
define the worker handshake. The controller uses
[SuspendThread](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-suspendthread)
before the final context read.

The execution probe uses
[AddVectoredExceptionHandler](https://learn.microsoft.com/en-us/windows/win32/api/errhandlingapi/nf-errhandlingapi-addvectoredexceptionhandler)
to observe exceptions and
[EXCEPTION_RECORD](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-exception_record)
for the exception code and address. Its handler edits the supplied
[x64 CONTEXT](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-context)
before returning `EXCEPTION_CONTINUE_EXECUTION`.

## Experimental server patch

The parent directory’s `rosetta-debug-state-experimental.patch` applies to
[g-cqd/wine at f064add996bbf4819acf49f48bab263735279800](https://github.com/g-cqd/wine/tree/f064add996bbf4819acf49f48bab263735279800).
It adds six 64-bit fields owned by each server thread, initializes them on thread
creation, and preserves accepted Rosetta debug-register values. It uses existing
thread lifetime and server serialization, with no global handle cache.

This patch does not implement execution or data breakpoint exceptions, and has
not been adopted into either delivered Most Wanted app or the normal EA runtime.
Its validation covers the x64 cases above; native Intel, WoW64, and cross-process
behavior remain unverified. The tested candidate server SHA-256 is
`d7fc4c934c0bf70a45bc1e32d4508ce1f5ce8ba9cdb7b3cf4e49576178e07659`.
Keep experimental binaries and prefixes outside this repository.
