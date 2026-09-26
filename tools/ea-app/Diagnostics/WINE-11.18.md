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
