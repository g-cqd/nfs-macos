# NFS 2015 handoff for Rosetta and x87 work

## Proven on this Mac

- EA is signed in; the installed 64-bit game loads Apple D3DMetal 4.0b2, but exits before creating a game window.
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

The normal EA runtime is restored with tracing disabled. The experimental candidate is not in either delivered Most Wanted app. No game files, captured code bytes, account data, or binaries belong in this repository.

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
errors; independent review remains pending. No game comparison or NFS startup
fix is claimed.
