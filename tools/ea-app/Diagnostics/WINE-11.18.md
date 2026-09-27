# Wine 11.18 isolated boot and renderer gate

## Provenance

The [maintainer release](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.18), published 2026-09-25 at 15:27:48 UTC, supplies `wine-devel-11.18-osx64.tar.xz` (190,974,384 bytes). Its published SHA-256 and the downloaded archive both equal `aa0ea4c82e636ae7bca2076387cb0a5affa26509ad13f119ecd0d62bd7ba6f82`. Extraction validated member paths and link targets before expanding 5,378 entries (871,377,330 bytes). The private session has an ownership marker, separate runtime, and new prefix. The existing EA prefix and global Wine were not changed.

## Boot evidence

Both Wine and wineserver report version 11.18. A fresh-prefix `cmd /c echo WINE1118_CONSOLE_OK` returned zero and the expected marker. Notepad visibly rendered the two-line smoke document. Its mapped Unix ntdll, winemac, and PE ntdll paths all belonged to the private 11.18 runtime. The UI test had a real 30-second subprocess deadline and then stopped only its owned prefix. No private smoke processes remained afterward; the original signed-in EA process remained running.

These checks establish console and window creation. They do not establish D3D11 rendering, media playback, EA compatibility, or game startup.

## Renderer gate

The shipped x86_64 winemac driver exports only `__wine_unix_call_funcs` and `__wine_unix_call_wow64_funcs`. It does not export `macdrv_functions`, `get_win_data`, `release_win_data`, `macdrv_view_create_metal_view`, `macdrv_view_get_metal_layer`, or `macdrv_view_release_metal_view`.

[DXMT v0.80 source](https://github.com/3Shain/dxmt/blob/v0.80/src/winemetal/unix/winemetal_unix.c) and current main obtain the Metal-view bridge with `dlsym`, using those symbols. DXMT therefore requires a matching Wine 11.18 bridge or driver build before it can present with this package. Copying a driver from the Wine 11.0-based CX runtime would introduce an unverified ABI combination. No CX renderer or driver was copied.

The package includes MoltenVK and Vulkan loader libraries, but no D3DMetal or winemetal integration. The existing custom CX D3DMetal bridge has not been established as compatible with this stock runtime. The local mtld3d project implements D3D8/9; NFS 2015 requires D3D11.

The [Gcenx DXVK-macOS latest release](https://github.com/Gcenx/DXVK-macOS/releases/tag/v1.10.3-20230507-repack) is `v1.10.3-20230507-repack`, published 2024-07-23. Its macOS D3D10/11 fork requires Wine 7.1+ and MoltenVK 1.2.0+. The builtin archive is 2,785,833 bytes with published SHA-256 `810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00`. The asset was downloaded and its hash verified. The release excludes `dxgi.dll` and `d3d9.dll`; only its D3D11/D3D10Core builtin files were copied into the private runtime, with original files backed up. Async mode was explicitly disabled in the environment and configuration. Its requirements do not prove NFS compatibility.

The [Wine package README](https://github.com/Gcenx/macOS_Wine_builds/blob/11.18/README.md) requires the GStreamer framework for multimedia support. It is absent from `/Library/Frameworks`, and the linked GStreamer libraries were not found in the private package. The console/UI smoke does not exercise that dependency. No global dependency was installed.

## Retention and next gate

The private runtime, working EA clone, ownership/provenance JSON, and small diagnostic results are retained. After the game attempt, the failed fresh prefix and disposable control files were removed once their processes and open handles were gone. The verified download archive and temporary screenshots were also removed. At the end of the graphics smoke phase, no EA installation, game clone, or NFS launch had occurred with Wine 11.18. The later installation attempt, CLR controls, and first NFS launch are recorded below.

## D3D11 creation and presentation result

`d3d11-smoke.c` was written before changing the renderer and compiled with `-O2 -Wall -Wextra -Werror`. It requests feature level 11_0, clears an RGBA8 render target, copies it to a staging texture, checks the center pixel, and presents 180 frames. The unmodified Wine 11.18 renderer returned `E_FAIL` (`0x80004005`) at device creation. With verified DXVK-macOS builtin files, the same test returned zero: feature level `0xb000`, pixel `64,128,191,255`, and 180 nonfailed Present returns.

A second bounded run verified the visible blue window and DXVK/FL11_0 HUD. The initial mapping report selected paths inside the private runtime and was incomplete: later log inspection found a second MoltenVK loaded from `/usr/local/lib` through global Vulkan driver discovery. The initial D3D11 runs therefore do not establish isolated use of the bundled driver. A follow-up sets `VK_DRIVER_FILES` to the private manifest and checks every matching module path, including paths outside the runtime. The DXVK D3D11 file hash is `173980cb6c51fdd53dc37b9a17f0de7c5dfdebda18f52059aa7d5a6f1871299c`. The owned-prefix watchdog stopped remaining smoke processes. This establishes a working D3D11 path for the test, without a game-compatibility claim.


## Explicit Vulkan driver isolation

A follow-up selected only the package's `lib/wine/x86_64-unix/vulkan/icd.d/MoltenVK_icd.json` with `VK_DRIVER_FILES`. The same D3D11 probe again returned zero, feature level 11_0, exact pixel `64,128,191,255`, and 180 nonfailed Present returns. Inspection retained every matching module path instead of filtering by directory. Only the private MoltenVK and Vulkan loader were mapped, alongside private Wine/DXVK modules and their system-managed Rosetta AOT files. The duplicate-class warning disappeared. This corrects the isolation limitation of the earlier runs without asserting that the duplicate driver caused the installer failure.

## Fresh EA installation and CLR boundary

The reused official EA installer retained SHA-256 `dcbda653c9776320b283157be70def64db73c2b01bf45d5fa78f35d7e4e29320`. It downloaded the 246,083,584-byte MSI; its SHA-1 `a59750da134b077769b08a1dd59ba4b6cbfcd9e7` matched the signed bootstrapper manifest. The bootstrapper stalled after handing off to Windows Installer and was stopped at its 180-second deadline.

The first direct invocation returned Unix exit 103. A private command-file control captured the full Windows result, `1639` (invalid command line). The cause was quoting the entire `INSTALL_ROOT=value` argument; moving the quotes around only the value fixed that invocation. The corrected MSI advanced through install actions and reached `JunoInitializeSession`, then logged SFXCA binding CLR `v4.0.30319`. It made no further progress before the next 180-second deadline. No EA login window or game launch occurred in this prefix.

`clr-smoke.c` isolates the managed-runtime boundary without loading an application assembly. Both 32-bit and 64-bit builds compile cleanly with `-Wall -Wextra -Werror`. Under the private Wine 11.18 runtime, both load mscoree and return `S_OK` from `CorBindToRuntimeEx(v4.0.30319)`. The 32-bit `ICorRuntimeHost::Start` call hangs until the 25-second probe deadline; the 64-bit call returns `S_OK` and the process exits zero. Portable Wine Mono 11.3.0 is therefore discoverable; a missing Mono directory is not the diagnosis. The package's 32-bit CLR startup remains blocked.

Read-only registry checks found empty global DLL overrides and no msiexec-specific AppDefaults in either prefix. The installer environment disabled only winemenubuilder; it did not disable mscoree. Both prefixes had the .NET install-root and v4 policy entries. No global runtime, dependency, or original-prefix configuration was changed.

The [CLR source analysis](CLR-NOTE.md) identifies the Wine and Mono initialization boundaries and a proposed probe-only logging comparison. It does not establish an x87 defect or the cause of NFS's separate exit.

## Build the owned smoke probes

These are the successful compiler arguments, with output paths replaced by an owned temporary directory. Run from this Diagnostics directory. Set `PROBE_BUILD` to that directory first, keep the generated executables outside the repository, and remove them after testing.

```sh
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror d3d11-smoke.c -o "$PROBE_BUILD/d3d11-smoke.exe" -ld3d11 -ldxgi -luuid -lgdi32
i686-w64-mingw32-gcc -O2 -Wall -Wextra -Werror clr-smoke.c -o "$PROBE_BUILD/clr-smoke32.exe" -lole32 -luuid
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror clr-smoke.c -o "$PROBE_BUILD/clr-smoke64.exe" -lole32 -luuid
```

The recorded CLR runs used a separate process for each architecture and a 25-second external deadline. A timed-out probe's exact prefix was stopped and waited for. The probes contain no EA or game code and do not load an application assembly.

## Existing-installation clone and first NFS attempt

After confirming no original NFS process, the original lab wineserver was stopped and its prefix was APFS-cloned into a uniquely marked private child session. Six external user-folder symlinks were replaced with private directories. The current macOS username aliases the cloned Windows profile with a relative symlink inside the clone. Shell-folder registry values use `%USERPROFILE%`; no symlink referenced the original lab. The clone retained only the expected C: and Z: mappings. Its Wine graphics override sections were empty.

Wine 11.18 updated only the clone and returned zero. The source registry-hive hashes remained unchanged after the clone, update, and game attempt. The launch environment selected the verified builtin DXVK D3D11/D3D10Core and stock DXGI, disabled async, and selected the private Vulkan manifest. EA's mapped ntdll, winemac, D3D11, DXGI, and MoltenVK belonged to this runtime; no old CX/D3DMetal modules appeared in that inspection.

The first EA login frame was blank. Directly launching EADesktop with the existing `--in-process-gpu` workaround rendered it. The user signed in manually. A subsequent same-prefix restart configured a private DXVK log directory and retained sign-in; the EA Home page showed NFS installed. No account files or application logs were inspected. Temporary EA screenshots were removed.

Before the game attempt, the bounded marker collector was validated against the owned D3D11 probe, renamed only inside its private control directory. It accepted the expected feature-probe and selected-feature markers for 11_0; the rendered probe exited zero. A Windows Z: log path was used so the path does not depend on the application's current drive. The collector retained explicit attribution uncertainty, including multiple writable file descriptors held by Wine processes.

The first game attempt started at 2026-09-26 23:04:59 UTC. Bootstrap `0x06cc` exited `100010`. Full NFS `0x094c` (native PID 53554) exited `0xfffffffa` (`-6`) after 26,840 ms of observation. No visible game window was observed. Cleanup began 35.38 seconds after launch and stopped only identified successor `0x058c` (native PID 53862). No NFS process remained, and EA remained signed in.

The first full-process mapping snapshot confirmed the cloned NFS executable and Wine 11.18 Unix ntdll. D3D11/DXGI were not present in that early snapshot; the later query occurred after exit and supplies no later module evidence. The validated marker collector stopped normally on the first full-process exit with zero markers and zero NFS log bytes consumed. Its coverage is explicitly incomplete. These observations do not prove the absence of every graphics call, nor establish the new-runtime exit caller address. Wine 11.18 did not produce playable startup in this attempt.

## Selective startup trace control

The owned D3D11 test, temporarily named `NFS16.exe`, validated a pipe-only startup collector under Wine 11.18. The collector retained 12 records for the observer-confirmed process: the executable and selected module bases, plus `KERNEL32.ExitProcess(0)` with its numeric caller address. The exit caller belonged to a runtime wrapper outside the test image; no test-image caller RVA was fabricated. The test returned zero, created feature level 11_0, verified the rendered pixel, and returned from 180 presents without a failing HRESULT.

The collector consumed 100,414 bytes and reported no dropped lines, unattributed records, or observer ambiguity. It persisted only fixed module/API identifiers and numeric fields. The temporary six-export `RelayInclude` value was removed, and the Debug registry query matched its pre-test snapshot exactly.

A subsequent preparation attempt restarted EA with the same process-specific debug configuration and a 180-second collector. EA did not open its main window within the 80-second preparation gate, so no NFS process was launched. The supervisor restored the Debug registry and opened normal untraced EA. Signed-in Home returned within approximately 12 seconds. The traced EA process and background service were observed; no MSI updater was observed. This does not establish the cause of the preparation delay.

The collector was terminated during preparation cleanup before it wrote its final summary. Its empty output is a cleanup limitation and supplies no negative trace evidence. The next configuration check must distinguish debug scoping or pipe effects before another game attempt.

## User-requested restart with capture

After the user requested a global Wine shutdown and EA restart, two bounded preparation attempts used the existing signed-in clone. The first retained the validated relay/loader/exception configuration. The second removed only `NFS16.exe:+relay` from `WINEDEBUG`. Neither opened EA Home within its 100-second preparation gate, and neither launched NFS. Each cleanup completed at approximately 103 seconds, restored the Debug registry exactly, and reopened normal EA.

A bounded memory transport forwarded all 10,768 input bytes in each attempt, with no dropped lines or backlog. This excludes a full stderr pipe as the observed wait. It does not identify the cause of the startup difference. The launch executable, `--in-process-gpu`, working directory, private prefix, DXVK overrides, Vulkan ICD and renderer configuration matched the successful normal launch. Allowlisted mapped paths confirmed private Wine, Vulkan and MoltenVK modules. Removing relay alone did not resolve the preparation wait.

Normal EA then opened signed-in Home. A fresh external capture was armed from 2026-09-26 23:36:44 UTC through 23:39:44 UTC for a user-started game attempt. This mode records numeric Windows process lifecycle events and allowlisted native module paths. It does not record API callers or exceptions, and it does not infer Windows/native PID equivalence from timing. No game was started automatically.

The external capture ended normally at 23:39:45 UTC after 180.227 seconds. It observed no NFS process, so its lifecycle file remained empty and it produced no game outcome. The observer stopped; normal signed-in EA remained open. Capture was inactive after this deadline.

## Existing user attempt on 2026-09-27

At 07:54 UTC, an NFS process was already running in the owned Wine 11.18 clone. Native process 68076 mapped the private Wine Unix ntdll and private D3D11/DXGI modules. Module mapping establishes a loaded library, not successful device creation. No visible game window was found in the queried process window list.

An external observer armed at 07:54:58 UTC recorded Windows process 52 exiting `0xfffffffa` after 9,018 ms of observation. Its successor, Windows process 1272, also exited `0xfffffffa`, after 45,128 ms. A later process exited with code 1 during scoped retry cleanup. The observer attached after the original process started, so it did not measure that process's full lifetime. The native and Windows PID namespaces were not independently mapped; the numbers must not be equated from timing alone. Only image-verified processes in this owned prefix were stopped, and EA remained open.

Normal EA used `DXVK_LOG_LEVEL=none` and `DXVK_LOG_PATH=none`. The exact checked NFS log paths contained no file, which is expected in this configuration and supplies no negative device-initialization evidence. A future logging check must account for the executable spelling when selecting the NFS log basename, without reading EA logs.

The external helper now has separate deadlines: at most 15 minutes waiting for an observed NFS process, followed by at most 180 seconds of active observation. Later processes cannot extend the active deadline. Timing checks cover start immediately before wait expiry, exact expiry, repeated start observations, backward time, immediate start, and invalid timing inputs. These tests exercise the timing model; the five transport checks separately exercise `LineQueue`, not the supervisor's expiry-drain cleanup. The updated helper was not launched again after this captured failure.

## Capture integration correction and EA-only controls

Review found that the private external helper replayed the whole lifecycle file on every poll while retaining its bootstrap state. If one poll ended at bootstrap exit, a later poll could incorrectly classify the replayed bootstrap observation as the full game. The helper now uses the existing bounded `Tail`, `Lines` and `Lifecycle` helpers and consumes each complete line once. A regression sequence feeds bootstrap observation, bootstrap exit, an idle poll, full-process observation, then full-process exit. The old behavior was reproduced as a failing mock; the corrected integration passes. Additional checks cover an early observer exit, split records, file rewrites, malformed data after an exit, partial EOF, and an event arriving at the expired wait deadline. An early observer exit now stops collection with its actual return code instead of leaving an inactive observer apparently armed.

An EA-only control retained normal `WINEDEBUG=-all`, the unchanged Debug registry, the same executable, `--in-process-gpu`, working directory and renderer configuration. It changed only stderr to an actively drained discard-only pipe. EA opened signed-in Home; the main window was observed by 17.6 seconds and then visually confirmed. The control discarded 78,141 bytes without persisting them and restored normal EA. A pipe alone did not reproduce the earlier capture-mode wait. The unresolved difference remains the debug configuration and temporary relay filter combination.

A separate owned `d3d11-smoke.exe` control used the exact NFS16-specific debug string while EA remained untouched. It exited zero after 5.99 seconds, with 40,610 stderr bytes drained and zero relay, loaddll or seh tagged lines. This supports filename exclusion for that owned executable. It does not establish the cause of EA's earlier startup wait.

A later user-started attempt was observed from 08:04:42 UTC. Windows process 2912 exited `0xfffffffa` after 13,172 ms of observation, followed by a successor. Native process 83922 was independently seen at that time with age 16 seconds and cumulative CPU time 13.48 seconds; it exited before its module query completed. An image-verified successor, native process 84014, mapped the private game, Wine ntdll and D3D11/DXGI modules. Windows and native PID associations remain unproven. Only verified successor processes in the owned clone were stopped; EA stayed open.


The finalization review also found that an exception while stopping retries or
waiting for the observer could leave the status reporting an active capture.
The corrected finalizer preserves the primary stop reason, records cleanup
failures separately, attempts stream closure and final status writing, and
bounds observer termination waits to five seconds followed by a two-second
kill fallback. Focused failure controls pass. The production wrapper bounds
its image-verified retry cleanup to eight seconds. No EA or game process was
launched for these corrections. The later 08:44 UTC capture exercised the
corrected lifecycle/finalization path and reported successful cleanup.
See [external capture helper contract](EXTERNAL-CAPTURE.md).

## Complete source baseline and network coverage

The complete source build, focused controls and latest instrumented launch
are recorded in the [handoff](../../../docs/NFS2015-HANDOFF.md#complete-wine-source-baseline).
The source baseline passes x86/x64 process and exception controls, x64 CLR,
and the separate DXVK pixel/Present control. Its x86 CLR and built-in
WineD3D/Vulkan D3D11 controls fail. These limits remain explicit.

The 08:44 UTC game attempt still exited `-6`. Native socket snapshots found
no internet socket in the game process. Wine source establishes that the
server performs host connections for AFD requests, so those snapshots do
not establish that NFS made no network request. A process-scoped server
diagnostic is required to distinguish a connection failure from earlier
startup code. No network payload or EA authentication log was captured.
