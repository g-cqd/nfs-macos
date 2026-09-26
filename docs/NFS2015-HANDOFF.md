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
