# NFS launch diagnostics

`watch-nfs.c` observes `NFS16.exe` in the Wine prefix where it runs. It reports the Windows process ID, parent process ID, and exit code. It does not read process memory, command-line arguments, or account files, and it does not terminate the game.

The observation ends after three minutes. More than one simultaneous NFS process stops the observation as ambiguous. Process enumeration and handle errors are reported.

Build with an available MinGW compiler:

```sh
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror -o Diagnostics/watch-nfs.exe Diagnostics/watch-nfs.c
```

Run from the lab directory while EA launches the game:

```sh
WINEPREFIX="$PWD/Prefix" WINEDEBUG=-all Wine/bin/wine Diagnostics/watch-nfs.exe
```

The compiler reported no warnings or errors. In the 2026-09-26 investigation, the watcher observed the following sequence with DXMT:

```text
observing_pid=2828 hex=0b0c parent_pid=2780
pid=2828 exit_code=0xfffffffa elapsed_observation_ms=1443
observing_pid=2896 hex=0b50 parent_pid=2828
pid=2896 exit_code=0xfffffffb elapsed_observation_ms=34320
```

The child process names and parent IDs establish a self-relaunch chain. The elapsed values measure time since this watcher opened each process, not total startup time.

The D3DMetal comparison also returned `0xfffffffa` and launched a child NFS process. Neither renderer produced a game window. Exception diagnostics showed the game's requests to set debug registers reaching Wine's Rosetta fallback, but did not establish that warning as the cause. Module diagnostics did not show a missing module in the observed NFS process IDs.

Source and these notes may be published. Keep binaries, raw logs, the Windows prefix, account data, and game files outside the source repository.

## Later user attempt and NX comparison

The user reported another failed launch at approximately 21:49 local time on 2026-09-26. The normal launcher had tracing disabled and retained the D3DMetal default. The read-only observer captured:

```text
observing_pid=3032 hex=0bd8 parent_pid=2992
pid=3032 exit_code=0xfffffffa elapsed_observation_ms=26462
observing_pid=3084 hex=0c0c parent_pid=3032
pid=3084 exit_code=0xfffffffa elapsed_observation_ms=25848
observing_pid=332 hex=014c parent_pid=3084
pid=332 exit_code=0xfffffffb elapsed_observation_ms=25558
```

This reproduces the earlier failure. No NFS window or new matching macOS crash report appeared. The last process had already exited before the attempted cleanup; no game process was terminated in that cleanup.

The next hypothesis concerned this custom Wine build's forced NX policy. Its documented `WINE_DISABLE_NX_COMPAT=0` option restores Wine's normal policy. The NFS executable has the `NX_COMPAT` flag, and the runtime contains the documented environment-variable hook.

A direct shortcut launch while EA was already running applied the option only to the initial bootstrap process. EA launched the actual game using its existing environment, so that first attempt was not a valid comparison. After a brief isolated EA restart, compatibility logs verified the option on the real NFS process and its successor, with D3DMetal unchanged. The observer captured process 1472 exiting `0xfffffffa` after 62,655 milliseconds of observation and child process 2460 reporting parent 1472. No game window appeared. The comparison was stopped and the normal launcher restored; the option is not retained.

The EA lab Wine executable was unsigned when inspected. A hardened-runtime signing change therefore does not explain this reproduction. No verified configuration fix emerged from the renderer or NX comparisons. The Rosetta debug-register warning alone does not establish the underlying cause.

## Exit callers

A bounded Wine relay trace restricted to process-exit APIs captured five `-6` exits and the final `-5` exit. Each call originated in `NFS16.exe`, which was mapped at `0x140000000`:

| Requested exit | API | Caller return address | RVA |
| --- | --- | --- | --- |
| `0xfffffffa` (`-6`) | `KERNEL32.TerminateProcess` | `0x144bdf5a6` | `0x04bdf5a6` |
| `0xfffffffb` (`-5`) | `KERNEL32.TerminateProcess` | `0x1475ca521` | `0x075ca521` |

Both calls pass the current-process pseudo-handle `0xffffffffffffffff`. The following `ntdll.NtTerminateProcess` call originates in Wine's forwarding implementation. This establishes explicit termination requested by game code; it does not establish the reason for that request.

Both return addresses belong to the executable's `.rdata` section, which has executable permissions. The corresponding on-disk bytes do not form coherent instructions at those locations, so static disassembly does not establish the preceding runtime control flow. The tested `NFS16.exe` SHA-256 is `92aa6ff4b5f8d0f033ca7e88cb86cc64b42b1d2412c4294905eb22950616e4df`.

The trace did not attach a debugger, change game code, or collect launch arguments or network calls. A subsequent diagnostic narrows tracing to thread-context and platform-query APIs called from game modules. Any temporary Wine relay registry settings must be removed or restored after diagnostics.

## Numeric context capture

`filter-context.py` filters a trace stream before it reaches a file. It retains only context/exit API metadata, exception codes and PCs, and allowlisted numeric context fields. It discards unrelated lines, limits each input line to 64 KiB, and limits total output to 1 MiB. `check-context-filter.py` verifies retained records, rejection of unrelated or oversized input, and the output-size limit. It rejects exception payload strings.

The 2026-09-26 trace captured this sequence on the NFS main thread using the current-thread pseudo-handle:

1. `GetThreadContext` returned success with all debug registers zero.
2. `SetThreadContext` requested `Dr7=0x155`, with `Dr0` through `Dr3` and `Dr6` zero. The Wine server returned `UNSUCCESSFUL`; Wine's Rosetta fallback converted that result to success for the game.
3. The immediate `GetThreadContext` returned success with `Dr7=0`, losing the value just accepted by `SetThreadContext`.
4. The game restored the previous zero context. The sequence repeated.

The first setter's caller return RVA is `0x055d8739`; the read-back caller return RVA is `0x055d8755`. This proves a Set/Get inconsistency on the game path. It does not yet prove that restoring the round trip is sufficient for startup or that the game never requires actual hardware breakpoint execution.

The sequence occurred again 0.478 seconds before a captured `-6` exit. Between that sequence and the exit, a helper thread requested `Dr0=0x14547de70, Dr7=1` on another thread through handle `0xd4`. That Set succeeded, and its immediate Get returned those values. A second helper's Get on the same handle about 10 milliseconds later returned all debug registers zero; it then cleared that context. The game requested `-6` about 0.339 seconds after the second helper's final Get. The trace establishes loss of a nonzero breakpoint state as well as the self-context mismatch. It does not establish whether the protected startup code requires that breakpoint to execute.

The diagnostic stopped the isolated prefix after this first complete failing sequence, avoiding further identical retries. The normal launcher file remained unchanged. The numeric server trace and relay trace are separate streams; use thread IDs and event order to correlate them. Timing differences quoted above use timestamps from the relay stream alone.

An unmodified server rebuilt from the matching source started successfully after placement beside the lab's original server; a standalone copy outside that runtime initially failed to locate `l_intl.nls`. The original server was never replaced. EA then requested a fresh manual sign-in, so this rebuilt-server attempt produced no game-startup comparison result. All tracing was stopped before the sign-in handoff. No authentication files were read or edited.

An additional `NtSetInformationThread` result, `STATUS_INFO_LENGTH_MISMATCH` for class 7 and an eight-byte input, matches Wine's Windows-conformance test. That result is not evidence of a compatibility defect.

## Register-state candidate result

A separate runtime clone received a server-only register-state persistence change. Its isolated regression test passed 24 checks; the unchanged comparison failed the post-resume persistence check. The tested server SHA-256 was `d7fc4c934c0bf70a45bc1e32d4508ce1f5ce8ba9cdb7b3cf4e49576178e07659`. Native process inspection verified that server, and NFS mapped D3DMetal/DXGI/Direct3D 11 from the same runtime clone.

The real game trace confirmed both corrected read-backs: `Dr7=0x155` survived the self-context sequence, and `Dr0=0x14547de70, Dr7=1` survived until the second helper explicitly cleared them. NFS nevertheless called `TerminateProcess(-6)` from the same return address `0x144bdf5a6`, without creating a game window. No NFS exception record appeared in the numeric exception trace. That absence does not prove the breakpoint target executed.

The retry chain was stopped after the first failure. The original runtime was not replaced. This change repairs register-state persistence but does not implement hardware breakpoint delivery, and it is not a demonstrated NFS startup fix. Temporary relay registry settings were restored afterward.

## Bounded live code snapshot

`capture-nfs-code.c` accepts one Windows PID and verifies that it names the exact installed NFS executable. It reads three fixed ranges only after `VirtualQueryEx` confirms that each range lies wholly inside a committed, readable executable image region with the expected image base. It opens the process for querying, synchronization, and reading; it does not attach a debugger or write process memory.

The capture takes three snapshots, five seconds apart, with a maximum of 3,840 bytes written. The fixed ranges start at `0x144bdf500` (256 bytes), `0x14547ddc0` (512 bytes), and `0x1455d8600` (512 bytes). Output uses exclusive file creation under `Logs/code-capture-private`. Keep those game-code bytes private; publish only this diagnostic source and sanitized findings.

Build with MinGW using `-O2 -Wall -Wextra -Werror`. Run `capture-nfs-code.exe --check` for the eight region-validation checks, which passed in the tested runtime. Compilation produced no warnings or errors. The live read completed all nine fixed captures. The first snapshots differed from the later snapshots; the second and third snapshots matched each other.

The decoded runtime function at `0x1455d8690` through `0x1455d87b1` checks the Boolean result of `GetThreadContext`, sets debug-register fields, reads context again, and clears the debug-register fields. It contains no comparison of the returned debug-register values. Consequently, the observed read-back inconsistency alone does not establish that this function rejects Wine.

The exit return address belongs to a jump chain in transformed code, rather than a nearby ordinary API call followed by a clear error branch. The nonzero breakpoint address is a function entry followed by a jump into transformed code. A memory snapshot does not establish whether the CPU reached that address or whether missing breakpoint delivery caused termination.

This attempt again exited `-6` and launched a successor. The retry chain was stopped, and the original untraced launcher was restored.

## Argument-free API tail collector

`collect-api-tail.py` accepts only the diagnostic relay's `MetaCall` and `MetaRet` records. Ordinary relay output and any line containing API arguments are rejected. The diagnostic Wine build must omit argument formatting at the source; this collector is not a substitute for that build.

The caller supplies a fresh lifecycle file produced by `watch-nfs.exe`. The collector validates its decimal and hexadecimal process IDs, accepts at most 64 NFS IDs, and discards records from every other process. Records arriving before the observer identifies a process are discarded. Use a new lifecycle filename for each run so stale process IDs cannot be mistaken for current ones.

The collector owns an 8 MiB byte ring. It atomically writes at most 1 MiB of recent complete JSONL records on the first exit API call per process and when input closes. The output begins with per-process first/last Wine timestamps and call/return/record counts, plus discarded-line and evicted-record counts. These counters describe the accepted observation interval; they do not claim that every startup call was captured. The parent diagnostic must stop the retry chain and close the stream after the selected attempt.

Run the collector after starting a fresh lifecycle observer, connecting only the argument-free diagnostic relay stream to its input:

```sh
python3 Diagnostics/collect-api-tail.py \
  --pid-source Logs/fresh-nfs-lifecycle.txt \
  --output Logs/nfs-api-tail.jsonl
```

`check-api-tail.py` was written before implementation. It verifies strict metadata parsing, secret-bearing input rejection, process filtering, observer limits, ring wrapping and eviction, tail retention, and the persisted-size limit. The checks pass. The collector does not start, stop, or modify Wine or the game.

### Metadata experiment result

The tested x64 `ntdll.dll` SHA-256 was `1a8b2c3dd66348431077f3e2ad3f8aec46cc71e2fde7498b04f299a92806d653`. Its synthetic probe preserved the tested return values and emitted no supplied sentinel string. The runtime also contained the previously tested register-state persistence change. Native mapped-file inspection confirmed that NFS loaded this ntdll and D3DMetal from the diagnostic clone.

Wine's process-specific debug syntax enabled relay only for `NFS16.exe`: `-all,NFS16.exe:+relay,NFS16.exe:+pid,NFS16.exe:+timestamp`. Temporary `RelayFromInclude=NFS16.exe;kernel32;kernelbase` retained game calls and the forwarding calls needed to observe NT allocation status. EA and its 32-bit helper had relay disabled. The original relay registry values were restored after the experiment.

The first real NFS process exited `0xfffffffa` after 54,608 milliseconds of observation. Its final call was again `KERNEL32.TerminateProcess`, with return address `0x144bdf5a6`. The collector accepted 1,074,916 records from that process over 54.185 seconds, retained an 8 MiB ring, and persisted 1,017,043 bytes at the first termination call. The persisted tail contains 7,879 records covering the final 0.342 seconds. Early and evicted records are not available for analysis. The collector reached 98.7% CPU in one process sample, so this instrumentation can perturb timing.

The retained sequence establishes these API outcomes:

- Three `NtAllocateVirtualMemory` calls returned success. The retained tail contains neither `STATUS_NO_MEMORY` nor `STATUS_CONFLICTING_ADDRESSES` from an allocation API.
- File opens and reads immediately before the exception-handler sequence returned success. No file paths or contents were captured.
- `RtlAddVectoredExceptionHandler` returned a nonzero handle, followed by a successful `VirtualAlloc`.
- Two helper threads each completed `WaitForSingleObject`, `SuspendThread`, `GetThreadContext`, `SetThreadContext`, a second `GetThreadContext`, `ResumeThread`, and `SetEvent`. Both main-thread `SignalObjectAndWait` calls returned `WAIT_OBJECT_0`.
- The main thread successfully removed the exception handler and freed the allocation, then successfully called `CreateProcessW` before requesting termination.

The two helper handshakes occurred about six milliseconds apart. The metadata trace does not identify the code executed between them. It does not prove that the nonzero hardware-breakpoint address executed or that a breakpoint exception was delivered. The expected class-7 `NtSetInformationThread` failure remained present. Raw return-register bits must be interpreted using each API's return type; high unused bits in a Boolean return are not an NTSTATUS failure.

The collector was stopped after its first termination snapshot, and the isolated prefix was stopped to prevent another retry. The original untraced EA runtime was then reopened. This experiment found no failing API boundary in the retained interval and did not fix game startup.

### Reduced-volume metadata result

A second capture excluded the heap, string, and critical-section calls that dominated the first tail. It kept context, allocation, protection, thread, process, query, and exception-handler calls. The runtime, process restriction, and collector limits remained the same.

The second capture accepted 95,307 records over 42.038 seconds. Its 1,018,932-byte tail retained 7,404 records spanning 38.024 seconds. The first full process exited `-6` after 42,452 milliseconds of observation, again from return address `0x144bdf5a6`. The collector was stopped at that first exit, and the successor was stopped with the isolated prefix.

All 505 retained `NtAllocateVirtualMemory` returns, four `NtMapViewOfSection` returns, and 150 `NtProtectVirtualMemory` returns indicated success. All 505 corresponding game `VirtualAlloc` returns were nonzero. Of those, 500 came from return address `0x14560324b`; returned addresses included a descending series from `0x7ff001da0000` through `0x7ff000000000`, followed by addresses below `0x200000000`. The trace does not record allocation arguments or prove that every allocated page was accessed.

Among `Nt`-prefixed API returns, the only nonzero NTSTATUS in this retained tail was the already explained `NtSetInformationThread` class-7 result, seen twice. A separate `RtlQueryProcessDebugInformation` return was `STATUS_INVALID_CID` (`0xc000000b`), at timestamp `39617.267`, from game return RVA `0x055d8813`. This API also returns NTSTATUS and must not be omitted from failure analysis merely because its name starts with `Rtl`. Its arguments were not captured, so the trace does not establish whether the process ID was valid or whether this was an intentional invalid-ID query.

The two context-helper handshakes, exception-handler cleanup, successful successor creation, and final termination remained present. The longer interval supplies a specific query boundary to investigate, but it does not establish the cause of termination. It does not exclude a bad value returned inside an output buffer, a missing exception, or a check inside game code.

Afterward, the original relay registry values and untraced EA runtime were restored. All collectors and observers from these two runs were stopped. No new Wine prefix was created. Future disposable probe prefixes must use `tempfile.mkdtemp` inside a private per-session directory with an ownership marker; the installed EA prefix remains exclusively owned by this diagnostic track.

### Debug-query argument check

`collect-debug-query.py` reuses the bounded collector with a parser restricted to five exact scalar signatures: `RtlCreateQueryDebugBuffer`, `RtlQueryProcessDebugInformation`, `RtlDestroyQueryDebugBuffer`, `KERNEL32.TerminateProcess`, and `ntdll.NtTerminateProcess`. Wine's export specifications mark their arguments as integers or pointers, with no string formatting. The parser enforces exact argument counts and widths, rejects every other API and all argument strings, and retains only observer-confirmed NFS process IDs. `check-debug-query.py` failed before implementation and passed afterward; the existing collector checks also remained green.

One run used the original runtime with relay enabled only for these exports and only in NFS. The actual NFS process ID was `0x09cc`, and its main thread ID was `0x09d0`. The trace captured `RtlQueryProcessDebugInformation(0x09d0, 0x14, buffer)`, which returned `STATUS_INVALID_CID`. The first argument was therefore the caller's thread ID, not the game's process ID. Wine's Windows-conformance test expects that status for this invalid-ID case. The preceding buffer allocation succeeded, and buffer destruction returned success.

The game requested the same `-6` exit 24.223 seconds after the query returned. The complete scalar capture retained seven records in 1,352 bytes without eviction. This resolves that query failure as expected invalid-ID behavior; it does not identify the startup failure. The retry chain and collector were stopped, and the normal registry and untraced EA launcher were restored.

### Code-write and instruction-cache relevance

`collect-code-writes.py` supplies a static numeric profile to the same scalar parser and bounded collector. It accepts `WriteProcessMemory`, `NtWriteVirtualMemory`, `FlushInstructionCache`, `NtFlushInstructionCache`, `VirtualProtect`, `VirtualProtectEx`, and the two termination exports. The parser validates each argument count and numeric width; it never dereferences a buffer or writes process memory. `check-code-writes.py` failed before implementation and passed afterward. The query-profile and bounded-collector checks also passed after the shared parser gained a static-profile factory.

One original-runtime attempt enabled only those eight exports for NFS, with calls originating from `NFS16.exe`, `kernel32`, or `kernelbase`. Its first full game process exited `-6` after 98,812 milliseconds of observation, at the same return address `0x144bdf5a6`. The capture retained all 309 accepted records in 50,926 bytes without eviction; the accepted events span 89.779 seconds.

The records contain 154 `VirtualProtect` calls, 154 successful returns, and the final termination call. Requested protections were `PAGE_EXECUTE_READWRITE` 101 times, `PAGE_READONLY` 48 times, and `PAGE_EXECUTE_READ` five times. Several changes covered game image sections. A helper also repeatedly changed a 14-byte region at `0x6fffffd77554` from requested RWX to requested RX near termination, through caller RVAs `0x055d8b62` and `0x055d8bcf`. The trace captured neither the previous protection output nor the bytes at that address.

No `WriteProcessMemory`, `NtWriteVirtualMemory`, `FlushInstructionCache`, `NtFlushInstructionCache`, or `VirtualProtectEx` call appeared in this accepted scope. This does not establish that the standalone write-plus-flush stale-code reproduction occurs in NFS. It also does not rule out direct stores, direct system calls, calls from excluded modules, or events before observer registration. Protection changes alone do not prove that code bytes were written.

The collector and retry chain were stopped after the first failure. The original relay registry values and untraced EA runtime were restored. No new Wine prefix or runtime clone was created for this attempt.
