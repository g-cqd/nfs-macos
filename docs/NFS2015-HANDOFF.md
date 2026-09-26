# NFS 2015 handoff for Rosetta and x87 work

## Proven on this Mac

- EA is signed in; the installed 64-bit game loads Apple D3DMetal 4.0b2, but exits before creating a game window.
- Game code explicitly requests `TerminateProcess(-6)`, usually from return RVA `0x04bdf5a6`. An eventual `-5` uses RVA `0x075ca521`.
- The current Wine/Rosetta path loses accepted debug-register state after a thread resumes. An isolated server candidate corrects that: the state probe changes from 24 checks / 1 failure to 24 / 0. The actual game also retains both observed register configurations, but still exits.
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
