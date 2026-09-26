# EA app and Need for Speed (2015)

This track uses a separate Wine runtime and fresh prefix. It does not share Most Wanted's prefix, game data, or saves.

## Verified installation on 2026-09-26

- Wine 11.0 from the local CrossOver 26.3-based bundle.
- Apple-signed D3DMetal framework 4.0b2, minimum macOS 14.
- Official EA installer 13.796.0.6309, downloaded from the link on [EA's app page](https://www.ea.com/ea-app).
- Installer SHA-256: `dcbda653c9776320b283157be70def64db73c2b01bf45d5fa78f35d7e4e29320`.
- Installer completed with result 0 and exit 0. Its first quiet attempt stalled during update checking; a diagnostic retry completed.
- The user signed in manually, and the library confirms ownership of Need for Speed (2015) Standard Edition.

D3DMetal 4.0b2 is the newest runtime found locally. Apple's current downloadable beta/release could not be verified through the permitted Apple Docs index or local SDK metadata. WWDC 2026 session 357 confirms GPTK 4 but does not identify the newest evaluation-runtime build. Do not silently relabel the local framework as Apple's latest release.

## Blank-window fix

EA's login page returned HTTP 200 but drew no content. Chromium's separate GPU process crashed in D3DMetal's `WineSwapchainCallbacks::InitializeForHWND`. Add `--in-process-gpu` for `EADesktop.exe` only, through this Wine bundle's compatibility rule. The sign-in page then rendered correctly. Leave the game's renderer selection separate.

The portable launcher follows EA’s stable Windows junction so EA can update its versioned installation directory. See [the launcher and setup note](../tools/ea-app/README.md). Keep network tracing disabled before account login. Credentials and verification codes belong in EA's own UI; never commit account logs, cookies, tokens or prefixes.

## NFS (2015)

The [official game page](https://www.ea.com/games/need-for-speed/need-for-speed) lists DirectX 11, a persistent internet connection and 30 GB free disk space. EA's actual download dialog currently reports about 16 GB for this account's selected installation. Check both the installation requirement and real available storage; macOS Storage and `df` may report different available/purgeable space.

Game download and gameplay verification are in progress. EA login working does not prove the game renders or meets a frame-rate target. Save game-specific settings and measurements here after an actual run.
