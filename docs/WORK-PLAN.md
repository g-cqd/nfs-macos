# Current delivery phases

## 1. Preserve the implementation knowledge — complete

Create a dedicated source repository with the native launcher, tests, packaging scripts, verified runtime revisions, tuning rationale, and unresolved issues. Exclude game installations, runtimes, personal careers, account data, screenshots, and raw logs. Keep the Most Wanted (2005) and Need for Speed (2015) tracks separate.

## 2. Import an existing Most Wanted installation — implemented

Accept a folder containing the supported PC 1.3 executable and game assets. Validate every required asset against the bundle's pinned manifest, reject links and unsafe paths, and overlay the app's compatibility components. Copy into a staged generation, preserve careers/settings, and activate only after complete verification. Persist the imported origin inside that generation so later launches keep it. Run this operation in the session helper under its existing game/session lock. Offer the folder picker on the Play screen, including when bundled game data is absent. Add a packaging option that omits original game data while retaining its verification manifest and compatibility files.

Failing tests preceded implementation. The complete suite passes 70 tests, including import validation, rollback, onboarding, repeat launch, and save/settings preservation. Release builds pass with warnings as errors and Swift 6 concurrency checking. Both packaging modes pass their audit; the one-command import build also completed ZIP verification. The optimized runtime initialized a fresh Wine prefix, imported the real PC installation, passed repeat preparation, and reverified 1,419 unmodified payload files. A separate copied career reaches the rendered game; user menu confirmation is pending. Native onboarding was inspected and its import button moved above the launch summary so it is visible without scrolling.

## 3. Finish the crash and release gates

The maximum-quality light-streak startup crash is fixed and its menu was verified. Adding a Porsche still crashes at 0x45d380 despite correct native visual parts. A bounded exception recorder is prepared; investigate the caller before changing more save fields. Keep the production career untouched. Rebuild and audit a candidate app after the import changes; do not label the garage feature or sustained 120 FPS as verified.

## Parallel: Need for Speed (2015)

The isolated EA app is installed and the user signed in. The library confirms ownership. Download through EA after its storage check, then have the user perform the game interaction tests. D3DMetal 4.0b2 is Apple-signed and newest locally available; newest downloadable Apple build is unverified.
