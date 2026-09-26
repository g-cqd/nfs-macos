# Windows EA app through Wine on Apple Silicon

## Files safe to publish

`Launch EA app.command` contains only launcher configuration. It expects this local layout:

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
- EA sign-in and library pages were visibly verified. Need for Speed (2015) download started. Game execution has not yet been verified.

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

Install games in the isolated prefix, such as `C:\Program Files\EA Games\Need for Speed`. Confirm entitlement in EA app and let the user handle any purchase or subscription.

## Sources

- [EA app download](https://www.ea.com/ea-app)
- [EA app installation instructions](https://help.ea.com/en/articles/platforms/ea-app-download-install-update/)
- [Need for Speed requirements](https://www.ea.com/games/need-for-speed/need-for-speed)
- [CrossOver changelog](https://www.codeweavers.com/crossover/changelog)
- [CrossOver graphics backends](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26)
- Apple Docs MCP document `wwdc/wwdc2026-357`: Game Porting Toolkit 4 announcement.
- Local D3DMetal framework `Resources/Info.plist`: installed version and minimum system version.
