# Windows EA app through Wine on Apple Silicon

## Files safe to publish

`Launch EA app.command` contains only launcher configuration. `Diagnostics/` contains the observation tools, bounded trace collectors, regression checks and owned-code probes described in its README. These are publishable source files and sanitized findings, without account data. The launcher expects this local layout:

```text
Launch EA app.command
Wine/bin/wine
Prefix/
Logs/
```

The Wine runtime, Windows prefix, game installation, logs, screenshots, and account data are not source files. Keep them outside version control. Download EA app from its official page and sign in manually.

## Verified configuration

- Host used for this test: Apple Silicon, macOS 27.0.
- Wine: custom bundle from CrossOver 26.3 sources, reporting Wine 11.0.
- Wine's `ntdll.so` build metadata requires macOS 15.0. D3DMetal's own minimum is macOS 14.0, which does not lower the full bundle's requirement.
- Apple D3DMetal: installed framework version `4.0b2`, with an Apple Software Signing signature.
- D3DMetal passed `codesign --verify --deep --strict`.
- D3DMetal 4.0b2 binary SHA-256: `f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad`.
- Its `libd3dshared.dylib` SHA-256: `1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0`.
- The runtime bundle selects D3DMetal for 64-bit DXGI applications. It supplies different implementations for 32-bit DXGI and Direct3D 9; D3DMetal is not the Direct3D 9 backend.
- EA app installer: `13.796.0.6309`, downloaded from EA on 2026-09-26. Installation completed with exit code zero.
- EA sign-in and library pages were visibly verified. Need for Speed (2015) installation completed, but the game did not open a window in the launch tests described below.

`4.0b2` is the newest runtime found locally. Apple Docs confirms Game Porting Toolkit 4, but the available documentation index does not establish the newest downloadable evaluation-runtime release. Do not describe this build as the latest Apple release without checking Apple's current download catalog.

## Empty EA window

The initial EA sign-in page loaded successfully over HTTP but remained empty. Its separate Chromium GPU process crashed in D3DMetal's `WineSwapchainCallbacks::InitializeForHWND`.

This bundle supports process-specific compatibility rules. The launcher adds:

```text
v=3
name=ea-ui;exe=EADesktop.exe;company=Electronic Arts;arguments=--in-process-gpu
```

With that rule, EA rendered its sign-in page and library. The rule applies to EA's interface; it does not apply the Chromium argument to games.

## EA installation path

The Windows path `C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\EALauncher.exe` resolves through EA's Windows junction into the current version directory. Pass that Windows path to Wine. A macOS filesystem test on the junction can incorrectly report the executable missing.

## Need for Speed (2015)

EA lists Windows, DirectX 11, a persistent internet connection, and 30 GB free space. In this installation, EA Download Manager displayed an 11.7 GB transfer. The transferred size and installed size are different; check available storage before starting.

EA reported installation complete on 2026-09-26. The installed game occupied 14,296,824 KiB (about 13.6 GiB), measured with `du -sk`. Its final `NFS16.exe` is a 64-bit Windows executable.

Install games in the isolated prefix, such as `C:\Program Files\EA Games\Need for Speed`. Confirm entitlement in EA app and let the user handle any purchase or subscription.

### Launch result on 2026-09-26

NFS loaded the installed D3DMetal framework and its Direct3D 11/DXGI libraries, but did not create a game window. A Windows process observer recorded a self-relaunch chain: each NFS child named the previous NFS process as its parent, and the observed parents exited with `0xfffffffa` (`-6`). The bounded D3DMetal observation lasted three minutes and ended while the last child was still running.

A temporary NFS-only DXMT comparison also produced no game window. Its observed relaunch chain eventually exited with `0xfffffffb` (`-5`). The normal launcher was restored to its original D3DMetal configuration and tracing was disabled.

The observed NFS process IDs showed no missing-module error or unhandled exception in the enabled diagnostic channels. They did request x86 debug-register operations that Wine reported as unsupported under Rosetta. That warning is a compatibility clue; its causal role has not been established. The game remains installed, but playable startup has not been achieved in this environment.

A later user launch at approximately 21:49 reproduced the same sequence under the normal launcher: two observed `-6` exits and a final `-5` exit, with matching parent/child process IDs and no window or new macOS crash report. A separate, verified NFS-only test of the custom Wine option `WINE_DISABLE_NX_COMPAT=0` still produced the `-6` self-relaunch. That option was removed after the test; it is not a recommended fix. The lab's Wine executable is unsigned, so a hardened-runtime signing change was not present in this test.

A targeted process-exit trace subsequently established that `NFS16.exe` directly calls `TerminateProcess` on itself. Five `-6` exits share caller return RVA `0x04bdf5a6`; the final `-5` exit uses RVA `0x075ca521`. These are game code locations, not evidence of an unhandled Wine crash. The underlying failed check remains unidentified. See `Diagnostics/README.md` for the evidence and limits.

A numeric thread-context trace then proved that Wine reported success when NFS set `Dr7=0x155`, but immediately returned zero on read-back. NFS also set a nonzero breakpoint address on another thread, read it back successfully, and received zero from a later helper-thread read. These are concrete compatibility defects on the startup path; whether a corrected implementation makes the game playable remains unverified.

A separate runtime candidate corrected both read-backs in the actual game and passed its 24-check register-state regression probe. NFS still requested `-6` from the same code location without opening a window. Register-state persistence alone is therefore insufficient for this startup failure. The candidate does not implement hardware breakpoint delivery; the original EA runtime remains unchanged.

A subsequent bounded live-code capture showed that the inspected self-context function checks API success but does not compare the returned register values. The register-state defect is therefore not a demonstrated cause of the exit. The captured exit return address and nonzero breakpoint target lead into transformed jump chains; these small snapshots do not prove that the breakpoint target executes. Private code bytes remain outside the publishable source set. No further unchanged launch is warranted by this evidence.

## Sources

- [EA app download](https://www.ea.com/ea-app)
- [EA app installation instructions](https://help.ea.com/en/articles/platforms/ea-app-download-install-update/)
- [Need for Speed requirements](https://www.ea.com/games/need-for-speed/need-for-speed)
- [CrossOver changelog](https://www.codeweavers.com/crossover/changelog)
- [CrossOver graphics backends](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26)
- Apple Docs MCP document `wwdc/wwdc2026-357`: Game Porting Toolkit 4 announcement.
- Local D3DMetal framework `Resources/Info.plist`: installed version and minimum system version.
