# Compatibility source forks

| Component | Fork branch | Pinned revision |
|---|---|---|
| mtld3d | [g-cqd/mtld3d: development](https://github.com/g-cqd/mtld3d/tree/development) | `7d108a4a7bf983cb0f993ffae2aa39ca159f2c6f` |
| x87sidecar | [g-cqd/x87sidecar: development](https://github.com/g-cqd/x87sidecar/tree/development) | `c3969379750531fb124859ae742ab4f727f54f9c` |
| NFS Wine | [g-cqd/wine: nfsmw-macos](https://github.com/g-cqd/wine/tree/nfsmw-macos) | `f064add996bbf4819acf49f48bab263735279800` (CX26.3 / Wine11.0, cursor recovery) |
| NFS (2015) Wine, from 2026-10-08 | local patched tree, not published: `athei/wine` `cx-26-patched` `1a7b0c76` plus seven patches | HEAD `c2afb959160c39e98b4e329d558b05b45da37c42` (base + 7 commits; profile `nfs2015-tf-cx11-rebuild-0007-20261008`; NFS2015.md §25) |
| WidescreenFixesPack | [ThirteenAG/WidescreenFixesPack](https://github.com/ThirteenAG/WidescreenFixesPack) | Reference `e9550ff793a50744b6569f3cace8ca551680b861`; retained NFS compatibility patch |

**Repin of 2026-10-02 (third), the release line.** One integration line, `release-latest`, repins every shipped
app together. Old -> new:

| Pin | Was | Now |
|---|---|---|
| mtld3d revision | `845b6c914a55633cbe099a076432d2dbe3656d1d` | `7d108a4a7bf983cb0f993ffae2aa39ca159f2c6f` |
| x87sidecar revision | `c3969379750531fb124859ae742ab4f727f54f9c` | unchanged (`c396937` is still the tip of `development`) |
| `sidecarSHA256` | `160e06be2c8ef21ac40cfddcbf408494cc08ae517997c10240aa450b5498bae5` | unchanged at that date; **moved on 2026-10-08 to `3ca9cc724b2e4685c271ed6af187f73f147b38ae3e4521793b978c9f09d3a628`, same revision (NFS2015.md §22.2)** |
| `rendererSourceManifestSHA256` | `2fa01910...2e23` | `fd47420c1ba3c0c51b9b9c2fcb6c4f5efcf94c9acf6894bc6df3ef1683fd445f` |
| `d3d9/mtld3d/i386-windows/d3d8.dll` | `24493c04...b27a` | `e2ad9398...4344` |
| `d3d9/mtld3d/i386-windows/d3d9.dll` | `f3a1551a...463e` | `5f0c974c...0abf` |
| `d3d9/mtld3d/i386-windows/mtld3d.dll` | `b5066539...ec5f` | `396e7bb2...23f0` |
| `d3d9/mtld3d/x86_64-unix/mtld3d.so` | `2fb0c4c0...2710` | `2d8e2cc5...6d26` |
| `i386-windows/d3d8.dll` | `37f18535...303f` | `2ec14095...1afa` |
| `i386-windows/d3d9.dll` | `22f0d972...e0cb` | `2ae214f2...73d5` |
| `i386-windows/mtld3d.dll` | `4b6db9df...1c72` | `82280e97...56e1` |

mtld3d `development` is `7d108a4`: `845b6c9` merged with upstream through `b93e752`, with the 1.99 clippy lints
satisfied. It was built from a scratch `git clone --local` of the developer checkout, detached at exactly that
commit, `PROD=1 PERF=0 FP=0 CRUMB=0`, non-telemetry, Rust 1.99.0 and nightly-2026-10-02, with the same recipe as
the `d5fc324` build (`pentium4` for i686, `x86-64-v2` for x86_64, the read-only xwin sysroot and Wine SDK). 631
source hashes, seven artifact hashes. Measured on that build's tree: 1,849 core and 714 Unix host unit tests (714
passed, 2 skipped) and, per Windows architecture, 1,004 end-to-end tests passed, 0 failed, 11 ignored (benchmarks).
Neither the shipped renderer nor its Unix bridge contains `mtld3d_shaders*` or any `perf_tracking` string. These
tests establish renderer correctness coverage, not game performance or game-level compatibility; no game was
played on this build.

x87sidecar `c396937` is unchanged. Its matrix at that commit was 1,059 passed, 0 failed and 2 stock divergences
of 1,061; it was not re-run, because the revision did not move, but the binary was rebuilt in a new scratch clone
and equals the pinned `sidecarSHA256`.

The recipes' renderer, evidence, sidecar and source inputs now point at `~/Games/release-build`. The Far Cry 2
Bundled recipe (`farcry2-bundled.json`) was deliberately not touched: it still names the `845b6c9` inputs under
`tools-integrate` and needs its own repoint before it can be built against these pins.

**Need for Speed (2015) provenance.** That app is a Direct3D 11 title served by dxmt and pins no renderer, so it has
no mtld3d revision. Its `runtime-provenance.json` used to inherit `2513602...` from the Most Wanted base app, together with an
`mtld3d` source archive and a renderer test claim that described that other app. The packager now drops a pinned
source whose input the recipe does not declare, records it under `sourcesNotApplicable` with the reason, deletes the
inherited archive and patch, and makes the renderer claim only for an app that installs the pinned renderer.
`check_runtime_inputs.py` pins this. The Wine runtime profile still carries mtld3d files from its own build: in
the built app they are `lib/wine/d3d9/mtld3d`, and the runtime's `compatdb` log names them as the default Direct3D 9
backend for a process with no renderer rule. They were not built, verified or pinned here, so no revision is claimed for
them. `NFS16.exe` and the EA client are served by dxmt through renderer rules and are Direct3D 11 programs; no
Direct3D 9 use by either was observed, and none was looked for on this build. The `wine`, `wine-build` and
`XtendedInput` entries inherited from the same base app are unchanged and still describe the Most Wanted base, not
the Need for Speed (2015) runtime, whose own source is `runtimeSource`; correcting those is a follow-up.

**Repin of 2026-10-02 (second).** mtld3d `development` is now `845b6c9` (`d5fc324` plus the unpublished upstream
commits through `5287496` and a built-in Far Cry 2 profile that reports an NVIDIA adapter, which makes tree leaves
cut out under anti-aliasing and alpha to coverage) and x87sidecar `development` is `c396937` (`12afdc2` plus the
`fld_gap_fstp` fusion: a float copy through the x87 stack with up to four independent instructions between the load
and the store becomes one plain copy; 13x faster than the isolated path in probes, 1059 of 1059 tests passing).
Both were published to GitHub as plain fast-forwards. The renderer was built `PROD=1 PERF=0` with Rust 1.99.0 from a
clean checkout (`~/Games/tools-integrate/renderer-845b6c9`, 631 source hashes, seven artifact hashes) and the sidecar
binary is `160e06be2c8ef21ac40cfddcbf408494cc08ae517997c10240aa450b5498bae5`
(`~/Games/tools-integrate/sidecar-c396937/x87sidecar`). Verified: 1837 mtld3d unit tests, the fusion proof script
and the sidecar suite. **Not verified:** neither change has run in a game; the mtld3d `unix/` tests and end-to-end
suite were not run.

Both development forks are clean at the revisions above as of 2026-10-02, and each one
already contains its upstream's tip: mtld3d's `d5fc324` descends from `athei/mtld3d`
`main` at `f4b18f4` through `b22073b`, and x87sidecar's `12afdc2` contains
`athei/x87sidecar` `master` at `4048fcf` through `8aa4d30`. Neither fork has been pushed
from this machine.

Both pins moved by their own repositories' dependency work, not by anything in this one.
mtld3d `b22073b -> d5fc324` adds the Rust pin 1.98.1 -> 1.99.0 (and nightly 2026-10-02),
zstd 0.13 -> 0.14, snmalloc 0.7.5 -> 0.7.6, a lockfile refresh and a CI-actions bump, so
the renderer is now built with Rust 1.99.0. x87sidecar `8aa4d30 -> 12afdc2` is a single
commit, "Bump the CI actions to their current majors", touching only
`.github/workflows/ci.yml` and `.github/workflows/release.yml`.

The renderer was rebuilt for this pin at the mtld3d revision above, into
`~/Games/rebuild-bundles/renderer-20261002-d5fc324`, whose `source-sha256.json` records
all 631 files tracked at that revision. It was built from a scratch `git clone --local`
of the fork, detached at the pinned revision, so no developer checkout was written to. Its i386 Windows DLLs and x86_64 Unix bridge passed 966
end-to-end tests per Windows architecture, with zero failures and 11 benchmark tests
ignored, beside 2,549 host unit tests. These tests establish renderer correctness
coverage. They are not a game performance measurement and not a claim of game-level
compatibility.

**The build is now `PROD=1 PERF=0`, not `PERF=1`.** The previous artifacts were built
with `PERF=1`, so `cfg(perf_tracking)` was compiled in and its counters ran on every
API call; `RUST_LOG=…,mtld3d::perf=off` silenced the output but not the instrumentation.
That code path held its counters in `Rc<RefCell<_>>`, which a game calling Direct3D from
several threads could trip into a `BorrowMutError` panic, ending the process. mtld3d
`b22073b` makes those counters thread-safe, and this pin, like the one before it, also
compiles them out: a bundle needs no telemetry, and `core/src/perf.rs` appears in none of
the shipped PE DLLs or the Unix bridge. A build for measurement is a separate, separately
identified build.

The one `perf`-shaped string that *does* remain in `x86_64-unix/mtld3d.so` is the log
target `"mtld3d::perf"` from `unix/shared/src/tsc.rs`, which is not behind
`cfg(perf_tracking)` because the TSC is also used for timeouts. It labels a single
"tsc calibrated" line. The previous accepted non-telemetry artifact carries exactly the
same one string, so its presence is not telemetry.

The flat arm64 x87sidecar artifact was rebuilt at the pinned fork revision: SHA-256
`cbc236c4dfc78fa466a52f1a7cc322f6733d44ceebe02ac493314a8fffdb2291`. **`sidecarSHA256` does
not move with this pin, and that is the expected result, not a stale value.** `12afdc2`
changes only two CI workflow files, so the artifact is byte-identical to the one built at
`8aa4d30`; `cmp` reports no difference between the two builds made here. The revision pin
still moves, because the pin records which commit the shipped corresponding source archive
comes from.

The build was also shown to be path-independent: the same procedure in a second scratch
clone at `8aa4d30` reproduced
`cbc236c4dfc78fa466a52f1a7cc322f6733d44ceebe02ac493314a8fffdb2291` exactly, the hash this
file already recorded. `8aa4d30` adds the `fyl2x`/`fyl2xp1` domain correction on top of the
documentation at `dbd680d`. The differential matrix was reported as 1,037 passed, 0 failed
and 2 known stock divergences of 1,039 by the workers that produced the fix and by the one
that bumped CMake to 4.4.3 at this revision; that matrix was not re-run against this exact
binary here, because re-running it rebuilds the artifact being pinned. The
cooperative Wine handshake uses `ROSETTA_X87_PATH`; the entitled attachment helper is not
bundled.

`Packaging/runtime-inputs.json` records exact input hashes. Signing and safe removal
of debug information can change packaged hashes; the final `runtime-files.json` is
generated after signing. Corresponding fork archives, retained Wine/dependency sources
and component notices accompany each app. The current renderer needs macOS15 and
matching i386 PE / x86_64 Unix components under the bundled x86_64 Wine.

Fetch future source updates without resetting users' working trees. Stage candidate
artifacts separately, retain the previous app, verify the required compatibility gates,
and update pins only with evidence. A source update alone is not evidence of improved
frame rate. The retained CoD4 result and its limits are summarized in [CoD4](COD4.md).

## Repin of 2026-10-08 (runtime with patch 0005), Need for Speed (2015) only

| Pin | Was (profile `nfs2015-tf-cx11-rebuild-20261008`) | Now (profile `nfs2015-tf-cx11-rebuild-0005-20261008`) |
|---|---|---|
| Wine source revision | `1e98e299ad2900fce2ab4f103cc1f98608fc7bfa` (base `1a7b0c76` + 4 commits) | `ce7b8eaa908e2cf4f91450f50c4e4694e21a6674` (base `1a7b0c76` + 5 commits) |
| Source archive in the app | `wine-nfs2015-source.tar.gz`, `e3c8c7ce…bf7fe` | `wine-nfs2015-source-0005.tar.gz`, `25f91e0791942a350c1acb2cf9caffb83be44d5e7bc840c43d992d6337ad8919` |
| `lib/wine/x86_64-windows/kernelbase.dll` | `4cdca0f5…39b6` (not pinned before) | `14e82c52ff0494287f3b2e921647a45254d20b7a2cf2b730f17df5f8092356e5` |
| `lib/wine/i386-windows/kernelbase.dll` | `c1efceb5…1a726` (not pinned before) | `09ce21ffa620c7195dd400f1aa10e10e5451fdcc765ff2b9c651c5dc1d289c2c` |
| The five earlier pinned files, `sidecarSHA256`, mtld3d, EA client layer | | unchanged |

## Repin of 2026-10-08 (runtime with patches 0006 and 0007), Need for Speed (2015) only

| Pin | Was (profile `nfs2015-tf-cx11-rebuild-0005-20261008`) | Now (profile `nfs2015-tf-cx11-rebuild-0007-20261008`) |
|---|---|---|
| Wine source revision | `ce7b8eaa908e2cf4f91450f50c4e4694e21a6674` (base + 5 commits) | `c2afb959160c39e98b4e329d558b05b45da37c42` (base `1a7b0c76` + 7 commits) |
| Source archive in the app | `wine-nfs2015-source-0005.tar.gz`, `25f91e07…8919` | `wine-nfs2015-source-0007.tar.gz`, `b0d61a3be8a2fff1a20c7c604998824098e683105577d5d70924e12384eb58a6` |
| `lib/wine/x86_64-windows/kernelbase.dll` | `14e82c52…56e5` | `ec494aca12cac61e4236c27692fc467ce12a24dd4943a6035b873563e5882f66` |
| `lib/wine/i386-windows/kernelbase.dll` | `09ce21ff…289c2c` | `15c1001c859753a3f70a1c54292b04ace79a404dfbb8195ac4b959917b52b4a3` |
| `lib/wine/x86_64-unix/ntdll.so` | `82cf3d48…7689` | `b1bddee45bbc61a74486464e842c739f68b489d0da29ef458210985ca6340de4` |
| Capabilities added | | `crashContextCodeWindows`, `rosettaPageExperiments` |
| `bin/wine`, `bin/wineserver`, `x86_64-unix/wine`, `i386-windows/ntdll.dll`, sidecar, mtld3d, EA client layer | | unchanged |

