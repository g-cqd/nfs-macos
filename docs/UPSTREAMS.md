# Compatibility source forks

| Component | Fork branch | Pinned revision |
|---|---|---|
| mtld3d | [g-cqd/mtld3d: development](https://github.com/g-cqd/mtld3d/tree/development) | `b22073b4fe835ec4beb7017898b4593be2f3a018` |
| x87sidecar | [g-cqd/x87sidecar: development](https://github.com/g-cqd/x87sidecar/tree/development) | `8aa4d308d90c3cc5ebf873db8c3e851848a332db` |
| NFS Wine | [g-cqd/wine: nfsmw-macos](https://github.com/g-cqd/wine/tree/nfsmw-macos) | `f064add996bbf4819acf49f48bab263735279800` (CX26.3 / Wine11.0, cursor recovery) |
| WidescreenFixesPack | [ThirteenAG/WidescreenFixesPack](https://github.com/ThirteenAG/WidescreenFixesPack) | Reference `e9550ff793a50744b6569f3cace8ca551680b861`; retained NFS compatibility patch |

Both development forks are clean at the revisions above as of 2026-10-02, and each one
already contains its upstream's tip: mtld3d's `b22073b` descends from `athei/mtld3d`
`main` at `f4b18f4`, and x87sidecar's `8aa4d30` contains `athei/x87sidecar` `master` at
`4048fcf`. Neither fork has been pushed from this machine.

The renderer was rebuilt for this pin at the mtld3d revision above, into
`~/Games/renderer-pins-20261002`, whose `source-sha256.json` records all 631 files
tracked at that revision. Its i386 Windows DLLs and x86_64 Unix bridge passed 966
end-to-end tests per Windows architecture, with zero failures and 11 benchmark tests
ignored, beside 2,549 host unit tests. These tests establish renderer correctness
coverage. They are not a game performance measurement and not a claim of game-level
compatibility.

**The build is now `PROD=1 PERF=0`, not `PERF=1`.** The previous artifacts were built
with `PERF=1`, so `cfg(perf_tracking)` was compiled in and its counters ran on every
API call; `RUST_LOG=…,mtld3d::perf=off` silenced the output but not the instrumentation.
That code path held its counters in `Rc<RefCell<_>>`, which a game calling Direct3D from
several threads could trip into a `BorrowMutError` panic, ending the process. mtld3d
`b22073b` makes those counters thread-safe, and this pin additionally compiles them out:
a bundle needs no telemetry, and `core/src/perf.rs` no longer appears in the shipped PE
DLLs. A build for measurement is a separate, separately identified build.

The flat arm64 x87sidecar artifact was rebuilt at the pinned fork revision: SHA-256
`cbc236c4dfc78fa466a52f1a7cc322f6733d44ceebe02ac493314a8fffdb2291`. The pinned head adds
the `fyl2x`/`fyl2xp1` domain correction on top of the documentation at `dbd680d`. Its
differential matrix was reported as 1,037 passed, 0 failed and 2 known stock divergences
of 1,039 by the workers that produced the fix; that matrix was not re-run against this
exact binary here, because re-running it rebuilds the artifact being pinned. The
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
