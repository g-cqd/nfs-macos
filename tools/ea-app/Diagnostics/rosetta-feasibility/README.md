# Source attribution and retained evidence

Investigation and probes supplied by the **mtld3d-x87 worker** in the shared
workspace. Publication was coordinated on 2026-09-26. The two C sources below
are byte-identical to the hashes in the report. The report records that worker’s
runs; this publication does not claim a new independent rerun. Generated
executables, private prefixes, and local logs are not included.

The source/runtime paths and local log names in the retained report refer to
`~/Games/NFSMW-tools/diagnostics/nfs2015-context` and its adjacent
matching Wine source/runtime. Create a unique private prefix for any new run.

---

# Execution breakpoints under Rosetta: feasibility result

The current debug-register candidate preserves state but does not deliver the
owned execution breakpoint. A reliable general replacement has not been
implemented. NFS 2015's exit remains unexplained; these results do not identify
an x87 arithmetic fault or establish that missing breakpoints cause that exit.

The investigation used only owned console probes in an isolated prefix. It
changed no Wine runtime source, x87sidecar source, game executable, or active
game runtime. The proposed ordinary-TF shortcut has unresolved architectural
semantics. The sampling map lacks the publication and lifetime synchronization
required for a reliable mapped breakpoint.

## Verified results

Runs on 2026-09-26 used macOS 27.0 build 26A5388g and the isolated runtime clone.
No native Windows control was available. All new probes compiled with
`-std=c11 -O2 -Wall -Wextra -Werror -pedantic` using MinGW GCC.

| Probe and retained log | Result | What it establishes |
| --- | --- | --- |
| `context-probe.exe`; `context-breakpoint-study.log` | 24 checks, 0 failures, 0 infrastructure errors | Accepted debug-register values survive the tested context operations. |
| `execution-breakpoint-probe.exe`; `execution-breakpoint-study.log` | 4 checks, 1 failure, 0 infrastructure errors | DR0/DR7 readback succeeds, but the owned worker executes with zero breakpoint hits. |
| `stepping-semantics-probe.exe`; `stepping-semantics-candidate.log` | 30 boundary cases, 3 mismatches; 3 architectural-TF visibility checks pass | Ordinary branches, PUSHFQ, POPFQ and the tested syscall return step as expected; all three MOV-SS cases deliver an extra trap. |
| `translation-invalidation-matrix.exe`; `translation-invalidation-matrix.log` | 4 cases, 1 failure | The RW-allocation/RWX-execution case continues executing stale code after successful write and flush. |

Each stepping case runs with TF enabled and disabled, first on the main thread,
then on its repeat, then on an owned worker. The enabled run precedes its
disabled control. The syscall case calls `NtYieldExecution` and checks the
owned boundaries before and after that call; it does not claim to validate
every instruction inside Wine. It observed eight external single-step events
in each enabled syscall case. The handler keeps a fixed 32-entry trace and
caps external events at 4,096. It rejects another thread, unrelated exception
codes and single-step events with DR6 B0-B3 set. The join watchdog is ten seconds.

The first draft incorrectly treated every boundary after MOV SS as the x86
oracle and described architectural-TF visibility as a transparency failure.
Independent review corrected both before the final build and run. Earlier
progress summaries saying 30/30 boundaries passed are superseded by this log.

## Single stepping is useful, but ordinary TF is not hidden state

At `stepping-semantics-probe.c:31`, PUSHFQ saves TF=1 when the probe deliberately
sets architectural TF, and saves TF=0 in the disabled control. This is expected
guest behavior, not a Rosetta defect. No internal-stepping implementation was
tested. The observation shows why merely setting TF in Wine and masking TF in
delivered CONTEXT structures would not provide transparent emulation: guest
instructions can read the flag directly. A more complete implementation would
need to virtualize flag-reading/writing instructions and their fault behavior,
as well as context capture, syscall transitions and nested exceptions.

The actual single-step mismatch is at the MOV-to-SS instruction in
`stepping-semantics-probe.c:44`. The observed next RIP is `ss_b`, immediately
after loading SS. Intel specifies suppression of that trap and suppression of
an instruction breakpoint on the following instruction. The expected trace is
`ss_a, ss_c, ss_end`; the observed trace adds `ss_b`. This happened on cold main,
warm main and warm worker. The result is a Wine/Rosetta-stack observation; this
probe does not isolate which component causes it. See
[Intel SDM Volume 3A, section 7.8.3](https://cdrdv2-public.intel.com/835754/253668-sdm-vol-3a.pdf#page=206).

An internal stepping engine must model that suppression, guest TF, and RF
separately. It cannot translate every private step into a guest exception, or
consume every guest single-step exception as its own. The source paths needing
that distinction include `signal_x86_64.c:1062` (`restore_context`), `:1108`
(`NtSetContextThread`), `:1576` (`setup_raise_exception`), `:2354`
(`handle_syscall_trap`), `:2595` (`trap_handler`) and `:2820` (`sigsys_handler`).

## Executable-page invalidation has a reproducible gap

The matrix allocates one owned 4 KiB page per case, writes a function returning
1, and warms it with 1,000 calls on each of two threads. Both threads are outside
the page during the write. `WriteProcessMemory` reports one byte written,
`FlushInstructionCache` succeeds, and direct byte readback confirms immediate
2 in all four cases. The subsequent function results are:

| Initial allocation protection | Protection during execution | Extra operation after write | Main / worker |
| --- | --- | --- | --- |
| RW | RX | None | 2 / 2 |
| RW | RWX | None | **1 / 1, stale** |
| RWX | RWX | None | 2 / 2 |
| RW | RWX | Explicit RW then RWX protection transition, with checked results | 2 / 2 |

The source explains the difference. `dlls/ntdll/unix/virtual.c:6854` tests
`AllocationProtect`, which describes the original allocation rather than its
current executable protection. It skips the invalidation workaround for a
page allocated RW and later made RWX. `dlls/kernelbase/memory.c:640` already
considers RWX writable, so this route does not perform the protection changes
used around an RX write. `NtFlushInstructionCache` is an x86 no-op at
`dlls/ntdll/unix/virtual.c:7039`. The explicit transition control restores the
expected return values without changing the guest function bytes again.

This is a follow-up defect in the existing runtime, not repaired by this
investigation. A proper repair must inspect current protection across the
whole affected range, preserve each region's attributes, check both protection
operations, and define failure reporting and synchronization. The helper at
`:6860` currently ignores both protection-operation results. Merely changing
`AllocationProtect` to `Protect` would not establish a general transactional
invalidation contract. The parked-thread test does not prove safety while a
different thread is executing the modified page.

## Recommended implementation boundary

A translator-owned execution-breakpoint facility is the viable engineering
direction to investigate. It remains a design recommendation, not a proven
Rosetta API or an implemented solution. Its admission gate must establish all
of these properties before accepting an enabled breakpoint:

1. Identify every executable translation of the requested guest instruction
   and create an exact state boundary before it. Split a fused x87 run when a
   breakpoint falls inside it. The existing precise-state rule is documented
   in `x87sidecar/docs/internals.md:57`.
2. Install the execution check before a translation becomes runnable, and
   synchronize retirement and address reuse with its removal. A sampling
   lookup plus periodic refresh cannot provide this ordering. The unlocked
   `guest_pc_map.hpp:17` contract and negative cache at `:193` are appropriate
   for sampling, not a breakpoint registry.
3. Cover stock non-x87 instructions. The filter at `stub_asm.cpp:1153` currently
   bypasses sidecar IPC for them. The normal sidecar launcher already sets
   `ROSETTA_DISABLE_AOT=1` before exec at `main.cpp:1220`; late attachment must
   independently reject or retire translations created before instrumentation.
4. Make successful context updates and exception continuations commit one
   version of target-thread debug state. Handles are aliases of that thread,
   not separate stores. Resume must observe the committed version; thread exit
   must invalidate it before identity reuse. A failed update must leave the
   previous version fully armed or report the failure without partial state.
5. Deliver the correct guest RIP and DR6 slot bits, including multiple matching
   slots, while respecting guest TF, RF, MOV-SS suppression and unrelated
   traps. Disabling, replacing or rearming from an exception context must take
   effect before execution resumes. Do not infer these semantics from DR7
   readback alone.
6. Validate warmed code, cross-thread translation, code writes, unmapping and
   address reuse under concurrency. Use a proven invalidation operation with
   checked failure paths; the successful RX control alone is insufficient.

ARM hardware breakpoint state is a possible backend only after proving exact
translated-thread delivery and sufficient coverage of translation aliases. Its
existence in SDK headers does not establish those properties. Patching guest
INT3 bytes adds guest-code observability and process-wide patch ownership to
the problem; temporarily restoring bytes lets other threads pass unless their
execution is coordinated. Neither alternative was installed.

The acceptance suite for a future implementation must include the original
entry breakpoint, all four slots, local/global enables, simultaneous matches,
initial-PC hits, alias handles, remote/current-thread updates, continuation
edits, RF, guest TF, MOV-SS suppression, unrelated exceptions, target exit,
concurrent same-code threads, warmed translations, writes and address reuse.
Performance must be measured after correctness; this work makes no speed,
energy or allocation-performance claim.

## Reproduction and ownership

The two new `.c` sources, corresponding `.exe` files and four result logs named
above are retained in this directory. No change was committed or pushed.
The existing original probe sources and logs were preserved.

Build the new probes from this directory:

```sh
/opt/homebrew/bin/x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic stepping-semantics-probe.c -lntdll -o stepping-semantics-probe.exe
/opt/homebrew/bin/x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic translation-invalidation-matrix.c -o translation-invalidation-matrix.exe
```

The runs used `WINEMSYNC=1`, `WINEDEBUG=-all`,
`WINEDLLOVERRIDES=winemenubuilder.exe=d`, and this owned prefix:
`~/Games/NFSMW-tools/diagnostics/nfs2015-context/prefix-breakpoint-study`.
The runtime was `../nfs2015-breakpoint-wine/bin/wine` with its adjacent server.
After the runs, the owned prefix and temporary `../nfs2015-breakpoint-src` and
`../nfs2015-breakpoint-wine` clones were removed after their server was idle.
No breakpoint build directory was created. Cleanup is recorded in
`breakpoint-cleanup.log`.

Before cleanup, the relevant source files in the clone were byte-identical to
`../nfs2015-context-src`, which is retained. The server and ntdll were also
byte-identical to `../nfs2015-context-wine`. The source locations above refer to
those retained originals. Future runs should create a fresh, exclusively owned
prefix and use that retained runtime with its adjacent server.

| Artifact | SHA-256 |
| --- | --- |
| `bin/wineserver` | `d7fc4c934c0bf70a45bc1e32d4508ce1f5ce8ba9cdb7b3cf4e49576178e07659` |
| `lib/wine/x86_64-unix/ntdll.so` | `3bc4baa14ae578036896e1cee462871e52a3815a7624bc35ed8292a5bc7508ba` |
| `stepping-semantics-probe.c` | `fdd18ff2c95afef27451cdd16d03d173e338ac20d8b5fa3cb223de717dd00023` |
| `stepping-semantics-probe.exe` | `b132eb99445a01c0d8cfe261ccd6295d701e4b8eff25f4c59288b403dad5f3b6` |
| `translation-invalidation-matrix.c` | `14fa91760a833f6af287388a6ae33ed5ed6425889b4824570d690130fced28d9` |
| `translation-invalidation-matrix.exe` | `78b64d5577e682f895b831313aefbc055e257a74a53e46da25c95389f8433cae` |
