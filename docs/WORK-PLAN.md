# Current delivery phases

## 1. Preserve the implementation knowledge

Create a dedicated source repository with the native launcher, tests, packaging scripts, verified runtime revisions, tuning rationale, and unresolved issues. Exclude game installations, runtimes, personal careers, account data, screenshots, and raw logs. Keep the Most Wanted (2005) and Need for Speed (2015) tracks separate.

## 2. Import an existing Most Wanted installation

Accept a folder containing the supported PC 1.3 executable and game assets. Validate every required asset against the bundle's pinned manifest, reject links and unsafe paths, and overlay the app's compatibility components. Copy into a staged generation, preserve careers/settings, and activate only after complete verification. Persist the imported origin inside that generation so later launches keep it. Run this operation in the session helper under its existing game/session lock. Offer the folder picker on the Play screen, including when bundled game data is absent. Add a packaging option that omits original game data while retaining its verification manifest and compatibility files.

Write failing tests for successful import, missing/corrupt assets, links, rollback, first launch without bundled data, repeat launch, and settings/save preservation. Verify strict-concurrency release build and packaging before rebundling. A runtime test is still required before claiming a compatible imported game runs.

## 3. Finish the crash and release gates

The maximum-quality light-streak startup crash is fixed and its menu was verified. Adding a Porsche still crashes at 0x45d380 despite correct native visual parts. A bounded exception recorder is prepared; investigate the caller before changing more save fields. Keep the production career untouched. Rebuild and audit a candidate app after the import changes; do not label the garage feature or sustained 120 FPS as verified.

## Parallel: Need for Speed (2015)

The isolated EA app is installed and the user signed in. The library confirms ownership. Download through EA after its storage check, then have the user perform the game interaction tests. D3DMetal 4.0b2 is Apple-signed and newest locally available; newest downloadable Apple build is unverified.
