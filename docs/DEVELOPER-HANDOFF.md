# Developer handoff: Windows game bundles for Apple Silicon

Status snapshot: 27 September 2026. Read this document before changing a runtime, launching a game, or editing a save. It combines a report of completed work with a proposed roadmap. Proposed features are explicitly labelled; they are not implemented merely because they appear here.

## 1. The product we are building

We want a person to open a normal macOS application, configure a Windows game through a native interface, select a profile, and play without manually managing Wine, DLLs, Terminal commands, or compatibility patches.

The immediate games are:

- **Need for Speed: Most Wanted (2005), PC 1.3**, abbreviated NFSMW. This is the 2005 game, separate from Most Wanted (2012) and Need for Speed (2015).
- **Call of Duty 4: Modern Warfare, PC 1.0 build 525**, abbreviated CoD4. Both campaign and multiplayer executables are packaged; multiplayer operation has not been verified.

Each game has two editions:

1. **Bundled:** includes the supported original game data, Wine, mtld3d, x87sidecar, compatibility files, and native starter.
2. **Import:** includes the same starter and compatibility runtime, then asks the player to select their matching installed PC game folder. It validates and copies those files into private player storage.

Both editions should behave the same after setup. They should survive being moved to another folder or another compatible Mac. Personal saves, account credentials, product keys, development paths, and existing Wine prefixes must stay out of distributed apps.

The broader target is a composable bundler: share packaging, runtime setup, signing, profile infrastructure, and UI components while supplying explicit adapters for each game's configuration and save formats. A new recipe alone does not prove that a new game is compatible.

## 2. User priorities and definition of success

In priority order:

1. Reliable launch, correct graphics, responsive controls, and preservation of progress.
2. Complete, signed macOS apps that can be shared and opened with a clear first-run experience.
3. Native graphics/settings/profile controls, including a useful Maximum Quality preset.
4. Modular code and recorded knowledge so adding another game is manageable.
5. Measured improvements to frame time, image quality, loading, and distribution size.

Earlier performance requests targeted 60 FPS, then 120 FPS, with low lag. These remain ambitions, not established results for all scenes. Maximum graphics quality and a sustained frame-rate target can conflict. Expose useful choices and measure their effects.

A frame limiter of 120 does not prove the game renders 120 FPS. A 60 Hz display cannot show 120 distinct refreshes each second. Generated frames, when added in the future, must be reported separately from game-rendered frames and simulation/input updates.

**Current release scope:** refreshed runtimes, working NFSMW and CoD4 bundles, settings and profiles, spatial MetalFX, and release validation.

**Deferred by explicit user decision:** temporal upscaling and frame generation. Sections 11–13 describe proposed follow-up work for them. Do not delay the current release to implement these proposals.

## 3. A plain-language map of the runtime

```text
Native SwiftUI starter
    | chooses game/profile/settings; checks Rosetta
Native session helper
    | validates files; prepares private storage; applies settings; launches
Bundled Wine + Windows game
    | Windows API calls handled by Wine
    | Direct3D calls handled by mtld3d -> Metal -> GPU/display
    | x86 CPU execution handled by Rosetta
    | selected x87 instruction translation accelerated by x87sidecar
Persistent player folder
    | saves, settings, Wine prefix, logs, writable game generation
```

Terms:

- **Wine:** implements Windows interfaces so the PC executable can run on macOS.
- **Rosetta:** Apple's translation of Intel CPU code on Apple Silicon. The delivered Wine runtime needs it.
- **x87:** an older Intel floating-point instruction set used by these games.
- **x87sidecar:** a native ARM64 companion that translates x87 instruction runs and provides CPU profiling. It already emits ARM64 machine code; assembly-based acceleration is part of the existing design.
- **mtld3d:** a Rust Direct3D-to-Metal renderer. These two games use its Direct3D 9 path. The fork also contains Direct3D 8 work.
- **Wine prefix:** a directory holding a Windows-like C drive, registry, and per-installation state.
- **MetalFX:** Apple's image reconstruction/upscaling and interpolation APIs. The shipping renderer currently uses the spatial upscaler.
- **Notarization:** Apple's assessment of a signed distribution. A successful result is followed by stapling a ticket to the app and rebuilding its ZIP.

## 4. Where the work lives

All local paths below are on the current developer Mac; another developer must clone the repositories and relocate external inputs.

| Purpose | Location |
| --- | --- |
| Native starters, session helpers, tests, bundler, documentation | `~/Games/NFSMW-tools/macos-app` |
| Bundler GitHub repository | `https://github.com/g-cqd/nfs-macos` |
| Current bundler branch | `refresh-runtimes-cod4-bundle` |
| mtld3d source | `~/Developer/mtld3d` |
| mtld3d fork / upstream | `https://github.com/g-cqd/mtld3d` / `https://github.com/athei/mtld3d` |
| x87sidecar source | `~/Developer/x87sidecar` |
| x87sidecar fork / upstream | `https://github.com/g-cqd/x87sidecar` / `https://github.com/athei/x87sidecar` |
| Runtime fork branches | `development` in both forks; `origin` is g-cqd, `upstream` is athei |
| Cursor-corrected Wine source fork | `https://github.com/g-cqd/wine/tree/nfsmw-macos` |
| Original NFSMW installation | `~/Games/NFSMW` |
| Original CoD4 installation and original Gigi profile | `~/Games/CoD4`; `players/profiles/Gigi` beneath it |
| Existing CoD4 tools/runtime/evidence | `~/Games/CoD4-tools` |
| New apps and ZIPs | `~/Desktop/Game Builds` |
| Latest machine-readable release status | `~/Desktop/Game Builds/Verification/release-status.json` |
| NFSMW app's writable player data | `~/Library/Application Support/NFSMW` |
| CoD4 app's writable player data | `~/Library/Application Support/CoD4Mac` |
| Shared worker communication | `~/Desktop/The_Board` |
| Current delivery evidence | `~/Games/NFSMW-tools/macos-app/Evidence/delivery-20260927-yczkgx7b` |

The old NFSMW v5 app on the Desktop is still a packaging input for retained Wine, compatibility files, notices, and dependency sources. Preserve it until those inputs have been deliberately migrated. `docs/BUNDLING.md` and recipe JSON files enumerate the actual input paths. The obsolete original conversation working directory is not the source repository.

### Pinned runtime versions in this release

- mtld3d: `7d108a4a7bf983cb0f993ffae2aa39ca159f2c6f`, built `PROD=1 PERF=0` with Rust 1.99.0.
- x87sidecar: `c3969379750531fb124859ae742ab4f727f54f9c` (binary `3ca9cc72…a628` since 2026-10-08, was `160e06be…bae5`; NFS2015.md §22.2); adds the `fld_gap_fstp` fusion over `12afdc2`; see UPSTREAMS.md.
- NFSMW cursor-corrected Wine source: `f064add996bbf4819acf49f48bab263735279800`, CX26.3 / Wine 11.0 lineage.

`Packaging/runtime-inputs.json` pins artifacts as well as sources. The renderer's tested binaries match all 631 recorded source-file hashes at the pinned commit. Windows DLLs and the native Unix bridge must be updated as a compatible set. Do not combine arbitrary Wine versions, PE DLLs, native bridges, and sidecars.

## 5. Current status: what is actually established

### Most Wanted

- Earlier sessions reached gameplay with corrected graphics and analog DualShock throttle/sticks. Vibration pulses were physically confirmed during troubleshooting; this is not proof of all in-game rumble effects on every controller.
- The native starter includes graphics controls, controller settings, profiles/import/export/backups, and a separate cheating interface.
- Save controls include money operations and car/upgrade editing. The current global availability switch combines cars/events/shop parts; every requested granular unlock is not necessarily implemented.
- Adding arbitrary cars is **not fully verified**. A Porsche loading crash remains unresolved. Keep this visible as a known limitation and test edits on copied careers.
- The new runtime refresh passed fresh bundled/import setup and file verification. Earlier gameplay evidence must not be presented as a complete gameplay test of every newly rebuilt app.
- **Both new NFSMW editions are Developer ID signed, Apple notarized, stapled, and accepted by Gatekeeper.** Final ZIPs passed CRC verification and have adjacent SHA-256 files.

### Call of Duty 4

- New SwiftUI starter: Play, Graphics, Audio & gameplay, Controls, Profiles & backups, and Setup.
- Campaign/multiplayer configuration adapters expose supported settings, resolution presets, frame limits, MSAA, texture/filtering quality, lighting/effects, mouse and keyboard bindings, and renderer options.
- Profile operations include fresh creation, selection, import/export, backup, restore, and removal with preservation. A copy of the existing Gigi campaign is in the local app's player folder. It is not distributed in the app.
- Maximum Quality selects the display resolution and the implemented highest-quality preset: native render scale, 4× MSAA, supersampled alpha edges, 16× anisotropy, and high texture/world/effect settings. Actual presentation and gameplay still need verification.
- Controller detection is present; CoD4 controller mapping and rumble are **not verified**. Use keyboard and mouse for the first campaign check.
- Both apps are signed and audited. Both ZIPs are CRC verified. **CoD4 notarization has not been submitted**, pending the campaign check requested from the user.
- The corrected live game process opened the main archives and loaded the bundled renderer. The user's confirmation that the campaign is playable is still pending in this handoff.

### Two important fixes to understand

**CoD4 could not find `fileSysCheck.cfg`.** The file existed inside `main/iw_00.iwd`; its hash matched the original. Wine could open `C:\CoD4`, but could not map the native current directory through that directory symlink after host drives were removed. It fell back to `C:\windows`. `CoD4GameDrive` now adds a temporary `G:` drive pointing only at the private game directory before play, and removes it after Wine stops. The exact bundled Wine then reported `G:\` and found the archive. Regression tests cover mapping, cleanup, external-target rejection, and preserving an unrelated mapping.

**The first large CoD4 ZIP was invalid.** macOS `ditto` produced a central-directory offset truncated by 2^32 for the archive above 4 GiB. The apps were intact. A shared ZIP64 writer now preserves file bytes, executable modes, internal links, signatures and ticket files, verifies every entry, and publishes the output atomically. Its tests include native `ditto` extraction and failure cleanup. A real notarized app round trip retained its code signature and stapled ticket.

### Exact archive sizes at this snapshot

| Edition | ZIP bytes | Release state |
| --- | ---: | --- |
| NFSMW bundled | 2,538,415,162 | Final, notarized/stapled |
| NFSMW import | 289,341,384 | Final, notarized/stapled |
| CoD4 bundled | 6,885,137,136 | Prepared ZIP64 archive; awaiting release validation |
| CoD4 import | 280,241,010 | Prepared archive; awaiting release validation |

Use `release-status.json` and adjacent `.sha256` files for current identifiers/checksums. CoD4's original compressed archives and videos dominate its size. Do not remove game assets merely to produce a smaller download.

### Separate, paused investigation

NFS (2015) uses a separate EA/Wine setup. The user owns it in their EA library and installed it. Attempts have failed before a game window. This work is paused and is not part of the two bundled games. Do not restart its experiments, assume an online-service explanation is proven, or reuse its changing runtime/prefix for NFSMW or CoD4.

## 6. Source map for a new developer

Paths in this section are relative to the bundler repository.

| Directory/file | Responsibility |
| --- | --- |
| `Sources/LauncherCore` | Verified game installation, manifests, paths, bounded file operations, transactions, process/session locks, Wine environment and shutdown, guest drive isolation, existing NFSMW save/settings logic |
| `Sources/SharedLauncher` | Shared Rosetta onboarding/state and display-quality support |
| `Sources/NFSMWLauncher` | NFSMW SwiftUI starter and observable UI models |
| `Sources/NFSMWSession` | NFSMW setup, configuration, save operations and game process lifecycle |
| `Sources/CoD4Core` | CoD4 setting catalogue/config files, profiles, backups and private game drive |
| `Sources/CoD4Launcher` | CoD4 SwiftUI starter and its session client/models |
| `Sources/CoD4Session` | CoD4 preparation, mode/profile selection, settings application and launch/cleanup |
| `Tests` | Swift Testing suites for core behavior and UI models |
| `Packaging/Recipes` | Per-game JSON definitions: identifiers, products, input roots, allowlists, hashes, defaults |
| `Packaging/runtime-inputs.json` | Tested runtime/source/artifact pins |
| `Packaging/build.py` | Runs build and validation stages, then assembles/signs/audits/archives |
| `Packaging/assemble.py`, `recipes.py`, `payload.py` | Shared recipe parsing, input validation and payload composition |
| `Packaging/sign.py`, `audit.py` | Signing policy and dependency/hash/path verification |
| `Packaging/app_archive.py`, `check_app_archive.py` | New ZIP64 writer and regression gate |
| `docs/BUNDLING.md`, `UPSTREAMS.md`, `COD4.md` | Detailed setup, inputs, runtime provenance and CoD4 contract |
| `docs/METALFX-ROADMAP.md` | Verified capability probe, Apple API references and renderer integration gaps |
| `docs/TUNING.md`, `VERIFICATION.md`, `WORK-PLAN.md` | Historical rationale, test evidence, limitations and phases |

At handoff creation, the committed bundler baseline is `786b4ea` on `refresh-runtimes-cod4-bundle`. The packaging worker has completed but not yet committed the ZIP64 changes in `Packaging/build.py`, `Packaging/app_archive.py`, `Packaging/check_app_archive.py`, and `docs/BUNDLING.md`. Preserve these changes; they belong to this work. The live release-status JSON is newer than some committed release notes. Check `git status` and the release status before proceeding.

## 7. Storage, safety and lifecycle contracts

The installed `.app` stays immutable. Runtime writes go into the game's player folder:

```text
Library/Application Support/<game>/
  Data/Versions/<manifest-version>/Game   verified writable generation
  Data/Current                          points to active generation
  Data/Prefix                           private Wine prefix
  Data/Saves                            persistent profiles/progress
  Logs/                                 session diagnostic outputs
  RuntimeHome/Player/                    private process home
  Temporary/                            temporary runtime state
```

Setup stages and verifies a complete generation before publishing it. Existing saves survive application updates. CoD4's `Game/players` links to private persistent saves. APFS file cloning avoids allocating another full physical copy when supported; it preserves independent writes. A streaming-copy fallback exists.

The helper uses a session lock and a game lease containing PID and kernel start time. Do not bypass these protections. Save/settings changes use transactions, backups and recovery; an interrupted operation must not corrupt the active career.

Guest drive isolation removes host home/root aliases. It is **not an enabled macOS App Sandbox**. Hardened runtime and notarization do not establish sandbox confinement. Sandbox work would need a separate compatibility/security investigation.

Rosetta onboarding is implemented: detect availability before Wine starts, request Apple's installation UI, recheck on activation, and offer Refresh. This Mac already has Rosetta; the first-install dialog still needs a clean-machine test.

Normal runs disable the Metal HUD and performance instrumentation. Shader compilation is synchronous in the maximum-quality configuration because asynchronous compilation can temporarily omit draws. First-use compilation may pause; do not label that behavior as verified stutter-free rendering.

## 8. First steps for the incoming developer

1. Read this handoff, `README.md`, `docs/BUNDLING.md`, `docs/COD4.md`, and the repository's current instructions.
2. Inspect `git status`, current branches, and `~/Desktop/The_Board`. Coordinate before modifying shared files or runtimes. The board uses compact JSONL messages; append to an owned file and do not overwrite another worker's log.
3. Identify any running game before testing. The user prefers to perform menu navigation and gameplay checks. Explain the exact check and wait for the result. Do not take over a live race or campaign.
4. Preserve original games, original Gigi profiles, their backups, the current released apps, and retained build inputs.
5. Use a uniquely named temporary support directory/prefix for experiments. Record ownership and cleanup only that directory. Stop only your own prefix's wineserver. Never issue a global Wine kill as routine cleanup.
6. Build and test the native code before spending time on large archives.

```sh
cd ~/Games/NFSMW-tools/macos-app
xcrun swift test
xcrun swift build -c release -Xswiftc -warnings-as-errors
xcrun swift-format lint --strict --recursive Sources Tests
python3 Packaging/check_app_archive.py
```

The project declares Swift 6 and macOS 15. The current development Mac uses Xcode 27 beta / Swift 6.4, Apple M1, and macOS 27 beta. Do not silently raise the deployment floor. Python 3.11 or newer is required by packaging. Avoid introducing a new dependency until existing native APIs and project tools have been considered.

Build examples use a new output location to preserve usable apps:

```sh
python3 Packaging/build.py --game nfsmw --game-data bundled --output "Build/NFSMW Candidate.app"
python3 Packaging/build.py --game nfsmw --game-data import --output "Build/NFSMW Import Candidate.app"
python3 Packaging/build.py --game cod4 --game-data bundled --output "Build/CoD4 Candidate.app"
python3 Packaging/build.py --game cod4 --game-data import --output "Build/CoD4 Import Candidate.app"
```

`--no-archive` avoids allocating a ZIP during iteration. `--input NAME=/absolute/path` relocates declared recipe inputs. `--recipe` selects another recipe. Both editions currently require external assembly inputs, including the game inventory source; cloning GitHub alone is insufficient. The delivered app must not depend on those build-machine paths.

Default builds use ad-hoc signing. Distribution requires `--identity` with the local authorized Developer ID, followed by notarization. The existing Keychain profile is `nfs-macos`; credentials must remain in Keychain. Use the shared archive writer for large apps. After stapling, rebuild the ZIP and checksum so the downloadable artifact contains the accepted ticket.

## 9. Immediate roadmap: finish this release

### Phase A — close the remaining release gates

- Obtain the user's corrected CoD4 campaign result: menu, resume Gigi, several minutes of movement, correct textures/shadows, keyboard/mouse, save, quit, relaunch and resume.
- Verify the temporary game drive is removed after exit and no unexpected game/runtime processes remain.
- Test the import edition and a relocated installation using private disposable player data; preserve the authoritative saves.
- Run a short NFSMW regression using a copied career against the refreshed runtime: menu, race, analog throttle, stick dead zones, controller labels and vibration where supported.
- Integrate the completed ZIP64 packaging change into a scoped commit; update stale release notes with the machine-readable results.
- Submit both CoD4 editions to Apple after the campaign gate, then staple, assess with Gatekeeper, rebuild the final ZIPs and record checksums.

Acceptance: four clearly labelled deliverables, accurate test/notarization records, successful required manual checks, source updates pushed, and owned temporary artifacts removed. A failed gameplay check is a release blocker to investigate, not a reason to describe the build as verified.

### Phase B — make adding games predictable

- Formalize a small game-adapter contract covering install inventory, mode/executable, startup directory, settings, persistent data, profile operations and capabilities.
- Keep game-specific save/config parsers separate from shared installer/runtime/signing/archive code.
- Add schema validation and useful errors for recipes, unsupported game versions, missing external inputs and unavailable features.
- Reuse native UI sections where the underlying behavior is shared. Only show settings that the selected adapter can validate and apply.
- Document one complete example of adding a game, including tests and manual acceptance criteria.

Acceptance: a new compatible game reuses the packaging pipeline and shared lifecycle while adding its explicit adapter; existing games continue passing their gates. No generic promise that every Windows game will work.

### Phase C — improve product completeness and measured quality

- Qualify Xbox and PlayStation mappings for each game, including analog triggers, dead zones, button symbols and rumble. The working NFSMW mapping does not automatically establish CoD4 support.
- Investigate the NFSMW added-car crash before broadening or advertising arbitrary garage editing. Keep granular cheats and save backups explicit.
- Validate maximum-quality presets against actual accepted game settings and display modes. Offer separate quality/performance choices when measurements justify them.
- Test Rosetta onboarding on a Mac without Rosetta and app updates against existing player data.
- Verify actual macOS Game Mode behavior; metadata alone is insufficient evidence.
- Investigate stronger process confinement separately, including Wine/JIT/helper/file-access requirements.

## 10. How to measure performance without misleading results

Use the same game version, save/checkpoint, camera path, graphics options, output resolution, render scale, focus state and display refresh for each comparison. Separate cold shader compilation from warm-cache gameplay. Record concurrent system activity and repeat samples.

Measure CPU frame work, GPU duration, presentation cadence, median and slow-tail frame times, memory, and input latency where equipment permits. Separate real rendered FPS from displayed/generated FPS. A menu, parked car, or microbenchmark does not establish campaign/race performance.

The retained renderer passed 923 tests with zero failures and 11 ignored benchmark cases. Prior CoD4 samples observed higher FPS with x87sidecar, but background activity contaminated the comparison. Do not turn those observations or upstream microbenchmark multipliers into a guaranteed game speedup.

Keep source branches and artifacts traceable. Both runtime forks already use `development` with `upstream` configured. Integrate upstream updates on an appropriate separate branch, resolve and test deliberately, then update artifact pins. Never reset another developer's worktree or silently replace a shared working runtime.

## 11. Future expansion: temporal upscaling and frame generation

This is a proposed follow-up program. The user explicitly excluded it from the current release.

### What these features mean

- **Spatial upscaling:** enlarges the current image using its own pixels. This exists today. `render.scale=1` uses native rendering and bypasses the upscaler; a supported smaller scale can activate spatial MetalFX.
- **Temporal upscaling:** reconstructs detail from the current frame and previous frames, using motion and depth to align history and reject invalid samples.
- **Frame generation/interpolation:** synthesizes additional display frames between real frames. It does not run the game's simulation or sample input again for each synthesized image.

A native capability probe on this Apple M1/macOS 27 reported support for spatial scaling, temporal scaling, and frame interpolation. The result establishes reported device support, not a functioning integration or any performance/quality improvement. Apple's temporal API is available from macOS 13; frame interpolation requires macOS 26 and a supported device. Retain the app's macOS 15 floor with OS/device checks and a reliable fallback. A Metal 4 migration is not required merely to use the ordinary MetalFX interfaces.

The current mtld3d presentation path carries final color and sequencing/timing information. It does not provide the complete verified temporal scene data. D3D9 resource bindings and shader constants expose raw data but do not identify each game's camera, scene depth or object motion automatically.

The hard integration work includes:

1. Identify the correct scene color and depth before HUD composition or later destructive passes.
2. Supply current-to-previous motion vectors, including independently moving objects and animated geometry; camera motion alone is incomplete.
3. Apply and report known projection jitter for temporal reconstruction.
4. Handle depth conventions, MSAA resolves, texture formats, dimensions, color/exposure conventions and resource synchronization.
5. Reset history after camera cuts, resize, loading, scene changes and other discontinuities.
6. Preserve HUD readability and handle transparency, particles, reflections and newly revealed surfaces.
7. Schedule presentation so generated frames do not cause excessive queueing, judder or input latency.

Use `docs/METALFX-ROADMAP.md` for the inspected source locations and Apple references. Do not expose an enabled temporal/frame-generation switch before the necessary inputs and fallback behavior are implemented and verified.

## 12. Proposed request to mtld3d maintainers

**Request:** add an optional, capability-gated temporal reconstruction interface and MetalFX backend, then add frame interpolation after one game's temporal path is validated.

### Deliverable 1 — frame data contract and capture tools

Define typed metadata for real-frame identity/timing, render/output dimensions, scene color, scene depth and its convention, motion-vector texture and convention, jitter, exposure mode, history resets, and UI handling. Specify ownership, lifetimes, synchronization, format constraints and missing-input behavior. Keep Windows and Unix structure layouts compatible and tested.

Provide bounded opt-in captures/visualizations for depth, motion, jitter and history validity. A per-game adapter should only activate for a verified game/version; unsupported configurations retain native/spatial rendering. Diagnostics must be off during normal play unless requested.

Starting points in the pinned renderer:

- `unix/shared/src/params.rs`: `SubmitFrameParams`, crossing the Windows/native boundary.
- `unix/unix/src/metal/command.rs`: `PresentEncode` and `encode_present`.
- `unix/unix/src/metal/upscale.rs`: current spatial scaler and resource/cache handling.
- `unix/unix/src/metal/presenter.rs`: frame queue and presentation scheduling.
- `windows/d3d9/src/device.rs`: depth bindings, transforms and shader constants.

### Deliverable 2 — one verified temporal game adapter

Choose NFSMW or CoD4 after inspecting which offers a reliable scene/depth/camera path. Build a reversible adapter that supplies the needed inputs and handles unsupported scenes explicitly. Verify moving objects as well as camera motion. Do not guess constant-buffer meanings or treat one attractive screenshot as validation.

Integrate the guarded MetalFX temporal scaler, bound history allocation, handle resize/device teardown and reset, and retain a native/spatial fallback. Validate 4× MSAA and other supported quality combinations rather than assuming all resolve/format combinations work.

### Deliverable 3 — frame interpolation and pacing

After temporal inputs are reliable, integrate the supported MetalFX frame interpolator. Define real versus generated frame counters, ordering, queue bounds, display deadlines, frame caps/vsync behavior, interruption/resize handling, and treatment of the UI. Disable interpolation in unsupported states, including any menus/cuts/loading paths that fail validation.

Measure end-to-end behavior. Report latency alongside displayed FPS and real-frame production. A higher displayed counter alone is not sufficient acceptance evidence.

### Acceptance criteria for this request

- Capability and OS checks select supported implementations without raising the global deployment floor unnecessarily.
- Automated tests cover metadata layout/validation, lifecycle, reset, missing inputs and fallback.
- Captured depth and motion are correct for camera and moving-object test scenes.
- Motion, occlusion/disocclusion, transparency, HUD, cuts, resize and focus changes have repeatable visual checks.
- CPU/GPU/memory overhead and frame-time distributions are measured against native/spatial baselines.
- Frame generation reports real and generated FPS separately, with documented latency and artifacts.
- Existing D3D8/D3D9 behavior and games remain covered by their regression/conformance gates.

## 13. Proposed request to x87sidecar maintainers

**Request:** improve and measure the CPU translation work that supplies real game frames, and make its diagnostics easy to correlate with renderer timing during the temporal/frame-generation investigation.

x87sidecar owns CPU translation and profiling. Metal textures, motion-vector reconstruction and MetalFX execution belong in mtld3d and game adapters. The sidecar can help prevent CPU stalls from starving the renderer; it cannot turn missing scene data into valid temporal inputs.

The existing sidecar already uses an IR translation pipeline, ARM64 emission, guarded runtime discovery, sampling, and an execution-counted block profiler. Begin with these facilities rather than replacing the design wholesale.

### Deliverable 1 — reproducible CPU evidence

For copied NFSMW and CoD4 scenes, collect guest-address samples, hot x87 block profiles, cold translation costs and steady-state costs. Rank translation/emission overhead separately from frequently executed generated code. Identify stalls at native-state conversion, cooperative startup, translation-buffer growth or IPC only when captures support that diagnosis.

Use the existing `profile_analyze` tooling and documented profiling modes. Correlate their intervals with mtld3d CPU/GPU/presentation timings. If a shared timing/marker interface is needed, specify clock conversion, process identity and optional bounded records, then measure its overhead. Avoid adding per-frame IPC or always-on logging without evidence that it is necessary.

### Deliverable 2 — targeted, semantics-preserving optimization

Select a measured hotspot before changing allocation, emission, fusion, register handling, boundary conversion or generated assembly. Preserve the project's existing arithmetic precision model and observable flags/state; do not assume it provides full native 80-bit x87 equivalence.

Test exceptional values, signed zero, rounding modes, denormals, x87 stack/tag state, signal contexts, bounds and buffer-growth failure paths as applicable. Use differential and existing regression tests plus sanitizers for relevant native code. Retain the verified parent-thread allocator ownership/locking contract described in `docs/investigations/native-buffer-reserve.md`; re-audit changed Rosetta code before enabling hooks.

### Deliverable 3 — supportable deployment

Keep cooperative Wine startup through `ROSETTA_X87_PATH` working with the flat notarizable sidecar. Preserve runtime probing, explicit compatibility errors and safe fallback/failure behavior for unsupported Rosetta changes. Test signed-app startup and clean shutdown with the renderer enabled.

### Acceptance criteria for this request

- Before/after measurements use the same copied workload and distinguish CPU-bound from GPU-bound scenes.
- Improvements include slow-tail frame times, not just translator microbenchmarks.
- No correctness, signal handling, allocator ownership or save/gameplay regression is observed in the required tests.
- Instrumentation overhead is measured and normal builds keep it disabled.
- Runtime compatibility checks remain effective after macOS/Rosetta changes.
- Any contribution to temporal/frame-generation work is explained through real-frame timing and latency, without claiming generated frames improve simulation or input frequency.

## 14. Suggested order and ownership for the expansion

1. **Bundler/app developer:** finish the current release and preserve the native/spatial baseline.
2. **Renderer developer:** inspect one game, implement temporal metadata and validate depth/motion/jitter captures.
3. **CPU/runtime developer:** profile the same real-frame workload with x87sidecar, coordinate quiet measurements, and optimize only evidenced CPU costs.
4. **Renderer developer:** qualify temporal reconstruction for that game, then implement interpolation and presentation pacing.
5. **App developer:** expose supported quality modes, explain trade-offs, persist per-game choices and supply safe defaults/fallbacks.
6. **Both runtime developers and tester:** evaluate image stability, frame times, latency, memory and compatibility before enabling the features by default.

This order allows the CPU and renderer investigations to run in parallel once their test scene and measurement contract are shared. Their changes must stay in separate owned branches/artifact directories until compatible candidate builds are ready.

## 15. The target in one paragraph

Deliver dependable macOS apps for NFSMW 2005 and CoD4, with their complete compatibility runtime, native settings and safe profile management, in both bundled-data and import-data editions. Finish and document the remaining gameplay/release gates, retain the original games and saves, and turn the packaging infrastructure into a reusable recipe-plus-adapter system. Then pursue temporal MetalFX and frame interpolation as a separate measured renderer project, supported by targeted x87 CPU work and honest reporting of image quality, real FPS, generated FPS, and input latency.
