# NFS 2015 handoff for Rosetta and x87 work

## Proven on this Mac

- EA is signed in. The original Wine 11.0/CX runtime loads Apple D3DMetal 4.0b2, but NFS exits before creating a game window. A separate Wine 11.18/DXVK attempt also exits `-6` before a visible window; its early module snapshot confirms the new runtime, but does not establish later graphics activity.
- Game code explicitly requests `TerminateProcess(-6)`, usually from return RVA `0x04bdf5a6`. An eventual `-5` uses RVA `0x075ca521`.
- The current Wine/Rosetta path loses accepted debug-register state after a thread resumes. An isolated server candidate corrects that: the state probe changes from 24 checks / 1 failure to 24 / 0. The actual game also retains both observed register configurations, but still exits.
- A separate TF probe under the original runtime passes 7/7 checks: exactly three `EXCEPTION_SINGLE_STEP` events at expected instruction boundaries, followed by normal return. Its disabled-TF control fails the three exception checks. This establishes a stepping mechanism, not transparent DR emulation.
- The independent execution probe accepts and reads back `DR0=worker entry`, `DR7=1`, then executes that worker without delivering `EXCEPTION_SINGLE_STEP`: 4 checks / 1 failure / 0 infrastructure errors. This is a breakpoint-delivery limitation in owned test code, not proof of the game's exit cause.
- The captured game context function checks API success, without comparing returned register values. A snapshot does not establish whether the game executes its requested breakpoint target `0x14547de70`.

## Useful question for the x87 agent

Can the existing Rosetta translation mapping support reliable execution-breakpoint delivery for a guest address, accounting for fragment creation, invalidation, reuse, thread ownership, and exception-context reconstruction? State storage alone cannot deliver an exception. A mapping suitable for sampling is not automatically safe for placing a trap.

No x87 arithmetic failure has been identified in this NFS 2015 startup path. The Most Wanted 32-bit x87 performance investigation is separate; measure any proposed arithmetic optimization with its existing compatibility and benchmark suite.

LLVM's [Mach exception handling source](https://github.com/llvm/llvm-project/blob/main/lldb/source/Plugins/Process/Utility/StopInfoMachException.cpp) distinguishes Rosetta execution breakpoints from data watchpoints. Avoid treating those as one capability. Wine's existing `dlls/ntdll/tests/exception.c` hardware-breakpoint tests require actual exception delivery after setting `Dr0` and `Dr7=1`.

## Reproduction materials

- [Standalone owned-code probes](../tools/ea-app/Diagnostics/context-probes/README.md)
- [Experimental server state patch](../tools/ea-app/Diagnostics/rosetta-debug-state-experimental.patch)
- [Game observation and privacy limits](../tools/ea-app/Diagnostics/README.md)

The original EA runtime is preserved and stopped. EA is currently signed in under the separate Wine 11.18 clone described below. The experimental candidate is not in either delivered Most Wanted app. No game files, captured code bytes, account data, or binaries belong in this repository.

## Argument-free trace, 2026-09-26

A diagnostic x64 relay preserves calls but omits argument values and pointed-to
strings. Its synthetic marker test passes the same case-sensitive,
case-insensitive (fifth argument), and arithmetic checks with both DLLs; the
marker appears only in the original trace. See [relay probe and patch](../tools/ea-app/Diagnostics/relay-probes/README.md).

The first NFS capture accepted 1,074,916 metadata records over 54.185 seconds.
The bounded persisted tail contains 7,879 records covering the final 0.342
seconds. Broad logging costs CPU and perturbs timing; these are trace coverage
measurements, not startup performance claims. The first full process exited
`-6` from the previously observed caller RVA `0x04bdf5a6`.

The main thread installs a vectored exception handler, successfully allocates
memory, and completes two helper-thread handshakes. Each helper suspends the
main thread, gets/sets/gets its context successfully, resumes it, and signals an
event. The main thread then removes the handler, frees the temporary allocation,
creates its next process successfully, and terminates itself. Three retained
`NtAllocateVirtualMemory` calls return success. The short retained interval
cannot exclude earlier failures, direct syscalls, or non-API checks.

Relevant game caller RVAs for coordinating further diagnostics:

| Call | Return RVA |
| --- | --- |
| RtlAddVectoredExceptionHandler | `0x06bebe1a` |
| First CreateThread / SignalObjectAndWait | `0x0735b620` / `0x06d0ae3f` |
| Second CreateThread / SignalObjectAndWait | `0x0707a760` / `0x076c1afd` |
| Helper GetThreadContext / SetThreadContext / GetThreadContext | `0x04ff8cbd` / `0x04ff90dd` / `0x04ff910d` |
| Helper ResumeThread / SetEvent | `0x04ff912a` / `0x04ff9150` |
| RtlRemoveVectoredExceptionHandler | `0x06e606a2` |
| CreateProcessW / TerminateProcess | `0x070cbb03` / `0x04bdf5a6` |

For a client-side TF matcher, inspect two Wine hydration paths before relying
on cached debug registers: syscall suspension in `usr1_handler` requests no
DEBUG context, and `signal_start_thread` replaces its initial context flags
with `CONTEXT_FULL`. `setup_raise_exception` also fetches DEBUG state again,
which could overwrite synthesized DR6. Wine's `bpx_handler` regression requires
separate BS and B0 events at the same RIP when stepping and execution
breakpoints coincide. RF, application TF, flag-reading instructions, and
flag-changing instructions require explicit semantics.

The [standalone TF probe](../tools/ea-app/Diagnostics/step-probes/README.md)
contains its exact test and limits. Other collaborators are investigating
breakpoint emulation in separate directories; this diagnostic stream owns the
EA launch trace and does not modify those experiments.

### Reduced-noise comparison

Excluding the observed heap/string hot calls retained 7,404 records spanning
38.024 seconds before the same `-6` exit. Of the retained calls,
505 `NtAllocateVirtualMemory`, four `NtMapViewOfSection`, and 150
`NtProtectVirtualMemory` calls all returned success. All 505 game
`VirtualAlloc` returns were nonzero. Timing remains affected by tracing.

One `Rtl` function returning NTSTATUS, `RtlQueryProcessDebugInformation`,
returned `0xc000000b` (`STATUS_INVALID_CID`) from caller RVA `0x055d8813`.
A subsequent scalar-only capture established that the game passed its thread
ID (`0x09d0`), while its process ID was `0x09cc`; its mask was `0x14`. Wine's
Windows conformance test expects this status for a thread ID. This lead is
therefore ruled out for the observed call. An `Nt`-name-only failure filter
would have missed the return, so future status analysis must use API contracts.
The same run then exited `-6` from the known caller.

The separate [address-ceiling probe](../tools/ea-app/Diagnostics/address-probes/README.md)
passed its valid narrow/wide/narrow comparison with the original runtime.
The wider permitted range did not cause allocation failure. Initial controls
near the address ceiling failed themselves and were inconclusive. No ceiling
patch was applied to the game runtime.

## Coordinated Rosetta feasibility findings

The **mtld3d-x87 worker** supplied a corrected, reviewed
[feasibility report and exact probe sources](../tools/ea-app/Diagnostics/rosetta-feasibility/README.md).
Its stepping matrix passes 27 of 30 boundary cases; all three MOV-SS cases show
an extra trap compared with Intel’s specified suppression. PUSHFQ observing an
intentionally set architectural TF is expected behavior, not a Rosetta defect.
An internal stepping mechanism still needs separate guest-state semantics.

Its executable-page matrix finds one reproducible stale-code case out of four:
a page initially allocated RW and subsequently executed RWX continues returning
old code after successful WriteProcessMemory and FlushInstructionCache on two
warmed, parked threads. A checked RW→RWX transition restores updated execution.
The current helper tests initial AllocationProtect rather than current Protect
and does not check its protection-operation results. Our team owns an isolated
repair and expanded tests; the supplying worker will review a stable snapshot.
Game relevance remains under investigation. No production fix is claimed.

## Code-write relevance capture

The original-runtime scalar capture retained all 309 accepted records without
eviction: 154 VirtualProtect calls, 154 successful returns and the same `-6`
termination. No WriteProcessMemory, NtWriteVirtualMemory, FlushInstructionCache,
NtFlushInstructionCache or VirtualProtectEx appeared in the selected game and
Windows forwarding-module scope. Direct stores, direct syscalls, excluded
modules and events before observer registration remain outside that evidence.
The standalone write-plus-flush failure is therefore not connected to NFS by
this capture.

The helper repeatedly requested RWX then RX protection for a 14-byte range near
termination. Protection requests alone do not prove that code bytes changed.
The [collector and results](../tools/ea-app/Diagnostics/README.md#code-write-and-instruction-cache-relevance)
record the exact scope. Original launch settings were restored afterward.

The isolated invalidation repair now passes the four-case execution matrix,
14 native range checks and 32 controlled API checks under ASan/UBSan. An
identically rebuilt unpatched runtime reproduces the native failures. The
candidate preserves mixed current region permissions and reports protection
errors. Independent review found no blocking defect in the production helper
within its documented stable-layout scope. The [patch, portable contract tests
and native probes](../tools/ea-app/Diagnostics/wine-invalidation/README.md) are
retained with attribution and exact hashes. A separate cross-process probe
passes five checks on the candidate; the original executes stale code.

## Rebuilt-runtime integration remains unresolved

EA did not create the full NFS process during the invalidation-candidate trial.
The matching unpatched rebuild also failed to create it: no full game was seen
at 183 seconds, and the actual stop occurred at 209 seconds. The original
runtime launched NFS again, which exited `-6`. Both rebuilds retained the
original PE ntdll and the previously tested register-state wineserver.

This does not isolate the invalidation patch as the cause of the failed
handoff. The candidate kept EA at “Launching game”; the unpatched rebuild
returned EA to Home. Neither produced a full-game exit comparison. The
[detailed launch record](../tools/ea-app/Diagnostics/README.md#reviewed-invalidation-candidate-and-original-control)
distinguishes observed exits from deliberately stopped successor processes.
The original EA runtime and registry were restored, and the private control
runtime was removed after its processes stopped.

The user requested a separate latest-Wine comparison. As checked on September
26, 2026, [WineHQ](https://www.winehq.org/) lists Wine 11.18 as the latest
development release, published September 18. The isolated track uses the
[Gcenx macOS build](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.18),
with its release asset digest verified before extraction. Both Wine and
wineserver report 11.18. Fresh-prefix console and visible Notepad smoke tests
passed; [provenance and renderer requirements](../tools/ea-app/Diagnostics/WINE-11.18.md)
record their scope and remaining checks.

The shipped winemac library does not export the private window/Metal APIs that
the inspected DXMT renderer expects. Verified DXVK-macOS files instead passed
a D3D11 feature-level 11_0 device, exact rendered-pixel readback and 180
nonfailed Present calls. A visible blue test window was checked separately.
Explicit selection of the private Vulkan ICD eliminated an initially discovered
global MoltenVK duplicate; a follow-up checked all matching loaded modules.
Current mtld3d handles D3D8/9. No NFS startup success is claimed.

The fresh EA installer had an independently confirmed command-line quoting
error, then reached a 32-bit CLR startup hang after that correction. The same
owned CLR activation source hangs in its 32-bit build and succeeds in its
64-bit build. Portable Mono is found; no missing-dependency diagnosis is made.
A uniquely owned APFS copy of the already-installed EA prefix allowed the
runtime comparison without repeating the installer. Original prefix processes
stopped before copying, host user-folder links were redirected privately, and
original hive hashes remained unchanged. Wine 11.18 updated only the copy
successfully. EA rendered with `--in-process-gpu`; the user signed in, and a
restart retained login.

The first new-runtime launch at 23:04:59 UTC on September 26 still failed.
Bootstrap `0x06cc` exited `100010`; full NFS `0x094c` (native PID 53554)
exited `-6` after 26,840 ms of observation. No game window was observed. The
identified successor was stopped deliberately, and EA remained signed in.
The full process's early mapping confirmed Wine 11.18 and the cloned game.
The marker collector, validated immediately beforehand on the owned D3D11
probe, retained zero NFS markers with explicitly incomplete coverage. Neither
that absence nor the early module list proves that no graphics call occurred.
The new-runtime exit caller has not been established.

## Astra startup profiling

Two bounded launches of the original runtime still exited `-6`. An early-armed
native sample succeeded after an owned Windows control verified the collector.
The second run consumed 29.36 CPU seconds over 39.999 seconds of resource
observations, with observed peak RSS 409.97 MiB. These are diagnostic
observations with uncontrolled concurrent workloads, not a speed comparison.

Repeated Wine dispatcher and unresolved translated frames also appeared in the
control. They do not establish an x87 fault, a particular hot function, or the
exit cause. The [Astra report](../tools/ea-app/Diagnostics/ASTRA-STARTUP-PROFILE.md)
records timing, sampling limitations and the next D3D11 creation boundary.
Temporary profiling helpers and the control prefix were removed; raw samples
remain private.

The [DXVK marker collector](../tools/ea-app/Diagnostics/DXVK-COLLECTOR.md) passes
19 focused checks, including permanent ambiguity after malformed or oversized
observer records and a failed writer-query cleanup deadline. It retains only allowed markers and numeric metadata with
bounded input, output and collection time. Buffered file markers do not prove
which process emitted them, and feature-level selection precedes device
construction. No missing marker is treated as proof that a call did not occur.

## Bounded breakpoint diagnostic

The independently reviewed [v6 source patch and probes](../tools/ea-app/Diagnostics/wine-tf-emulation/README.md)
pass 52 delivery checks and 13 supplementary cases, including eight explicit
unsupported stops. The source bundle pins the register-state prerequisite,
all six before/after hashes, and the tested version of each control. The
portable runner passes four cleanup/error checks.

This is an opt-in diagnostic with instruction and elapsed-time limits, not
general breakpoint emulation. It has not been established as the cause or fix
for NFS startup, and rebuilt-runtime integration remains unresolved. No game
was launched with this diagnostic.

## Latest external observation

The September 27 capture joined an already-running attempt. Windows PID 52
exited `-6` after 9,018 ms of observation; successor 1272 also exited `-6`.
Separate native snapshots confirmed private Wine 11.18 and D3D11/DXGI modules,
without proving device creation or an exact Windows/native PID mapping. The
[updated runtime record](../tools/ea-app/Diagnostics/WINE-11.18.md) distinguishes
these observations from startup duration and cleanup exits.

EA failed to reach Home during bounded attempts with detailed tracing, while
normal launches reached Home. A full output
pipe was excluded in two attempts. A later normal-settings EA control opened
Home through a discard-only pipe, so a pipe alone is insufficient to reproduce
the wait; the preparation cause remains unresolved.
The earlier three-minute external capture expired without observing a launch.
The replacement separates waiting for NFS from the active capture interval.
Review found and corrected replayed lifecycle records that could misclassify a
bootstrap as the full game. Incremental-record, deadline and bounded-cleanup
checks now pass. A later instrumented attempt exercised the corrected helper
and completed cleanup without a reported error.
Astra remains stopped at the user's request.

The next user attempt, observed from 08:04:42 UTC, again exited `-6`: Windows
PID 2912 after 13,172 ms of observation. Native snapshots independently
confirmed the private runtime and D3D11/DXGI in a successor. Those snapshots
do not establish device creation or Windows/native PID equivalence. EA remains
signed in; retry processes were stopped only after checking their game image.

## Complete Wine source baseline

A separately owned Wine 11.18 source build completed the Unix modules,
both PE architectures and wineserver from one configuration. The full build
and install returned zero. This provides a coherent baseline for source
instrumentation; it does not establish NFS startup compatibility.

The source is pinned to `7b3fff76fa5178f6ce0141b2c776afa2a822f101`, with the
package's Vulkan-portability patch and no experimental TF patch. All 380
private SDK/framework dylibs passed isolated x86_64 load controls. A native
control initialized TLS, fonts, SDL, GStreamer, FFmpeg, ICU, XML2 and Vulkan;
Vulkan enumerated one device. These are dependency controls, not game tests.

The archival XML2 2.15.2 dependency required unavailable ICU76. Rebuilding the
same XML2 source against verified ICU78.3 preserved its features and library
compatibility version. Its bundled tests passed; optional external conformance
datasets were absent. MinGW GCC 16.1 also differs from the package's compiler,
so this is not a byte-identical package rebuild.

The explicit macOS 14.0 build target required disabling configure's detection
of SDK27-only `pipe2`, selecting Wine's existing fallback. Availability warnings
now fail native compilation. Runtime controls ran on this macOS27 host;
they cannot establish support on macOS14. The upstream build retained 123
warning lines, including deprecated declarations, parser conflicts and GCC
diagnostics; it was not warning-free.

| Focused control | Result |
| --- | --- |
| x86 and x64 process startup, software exception, real memory-fault resume, suspended-thread context | Passed |
| x64 CLR activation | Passed |
| x86 CLR activation | Faulted in `ICorRuntimeHost_Start`; stopped at the 45-second watchdog |
| Built-in WineD3D/Vulkan device and swapchain | Failed with `0x80004005` |
| Verified DXVK-macOS fork, stock built DXGI, private Vulkan dependencies | FL11_0, RGBA `64,128,191,255`, 180 nonfailed Present calls |

The DXVK comparison used a disposable clone with async disabled. Its clone
and both control prefixes were removed after their matching servers stopped
and open-handle checks passed. The retained baseline has no DXVK overlay or
experimental TF patch. The x86 CLR failure prevents claiming a working fresh
EA installer; an already-installed EA clone is a separate integration test.

That integration test subsequently passed the launcher handoff. A uniquely
owned APFS clone of the installed EA prefix reached signed-in Home under the
complete source runtime. The original packaged runtime and prefix stayed
stopped and unchanged by the source build. One launch at 09:01:28 UTC produced
bootstrap exit `100010`, then full NFS Windows process 2904. Native snapshots
independently confirmed the cloned source ntdll and D3D11/DXGI; the Windows
and native process IDs were not independently mapped.
The game exited `-6` after 30,533 milliseconds of observation without a game
window. Only its verified successor was stopped; EA remained signed in.
This resolves the earlier partial-rebuild launcher stall for this baseline,
while leaving the game's startup failure unresolved.

## Startup and networking capture, 2026-09-27 08:44 UTC

The observer was armed before one controlled launch. Windows process 1560
exited `-6` after 29,807 milliseconds of observation. Native process 95996
was independently verified against the owned game image. Its 51 socket
snapshots spanned 29.141 seconds, with no matching internet socket in any
snapshot. Cumulative CPU time rose from 0.29 to 26.57 seconds; peak sampled
RSS was 339,852 KiB. Concurrent workloads were not controlled, so these are
observations, not a performance comparison. The two PID namespaces were not
independently mapped.

The process mapped `wsock32`, `ws2_32`, `wininet`, `dnsapi`, `iphlpapi` and
`crypt32`, plus the private Wine and D3D11/DXGI modules. A native sample
contained 261 observations per thread. The host main thread waited in the
AppKit event loop; translated guest frames were largely unresolved. This
does not identify a guest hot function or a failing network API. The separate
per-thread `ps` parser rejected the host's output format, so it supplied no
per-thread measurements for this run.

Source review found a coverage gap: Wine's `ws2_32!connect` sends
`IOCTL_AFD_WINE_CONNECT`, and `server/sock.c` performs host `connect()` on a
server-owned socket. Game-process-only socket inspection therefore cannot
exclude networking through wineserver. Polling also misses transient sockets.
The next network measurement must identify the requesting Windows process
and capture the AFD request, host connection result and asynchronous outcome.
It must include a positive process-start marker before treating zero requests
as negative evidence.

The sample and observer stopped normally. Only the image-verified retry was
stopped; EA remained open. The capture reported no cleanup error. No game code,
authentication data or network payload was changed or collected.

## Evidence required before another compatibility change

| Open question | Discriminating evidence |
| --- | --- |
| Does a server connection fail during startup? | NFS-scoped Wine AFD and completion records with startup/exit coverage, not only native socket snapshots |
| Does the requested execution-breakpoint address run? | Bounded guest instruction-boundary observation with explicit target-hit and unsupported/budget-stop records |
| Does the game handle the breakpoint exception? | Correlated exception delivery, handler return and continuation; successful Set/Get alone is insufficient |
| Does the coherent source baseline integrate with EA? | Established for the installed-EA clone: Home and full-process launch work; the game still exits `-6` |

The latest [EA shutdown list](https://www.ea.com/legal/service-updates/i-q)
was checked on September 27, 2026. It names NFS Rivals, but no NFS 2015 entry
was found. This does not establish live service health. Uncode's
[offline-mode demonstration](https://www.youtube.com/watch?v=twhQsBRymXs)
is a research lead; no released source or installable implementation was
verified. Neither an unavailable service nor anticheat has been established
as this startup failure's cause. No mock server or bypass patch was applied.
