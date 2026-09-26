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
