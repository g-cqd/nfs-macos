# Compatibility source forks

| Component | Fork branch | Verified revision / base |
|---|---|---|
| mtld3d | [g-cqd/mtld3d: nfsmw-upstream-update](https://github.com/g-cqd/mtld3d/tree/nfsmw-upstream-update) | Source `d45ead863eb48a127b8e8a939a8d0c5ad22af790`; docs head `251360250aa3713f27ac9447d51da52c0cdfdc2a`; upstream base `1b0bf1f40c8bfeecb4b0c5a2c8182ef6893edd76` |
| x87sidecar | [g-cqd/x87sidecar: nfsmw-macos](https://github.com/g-cqd/x87sidecar/tree/nfsmw-macos) | `f979c236fc2250fd107422d60fdc673a26749502` |
| Wine | [g-cqd/wine: nfsmw-macos](https://github.com/g-cqd/wine/tree/nfsmw-macos) | `f064add996bbf4819acf49f48bab263735279800` |
| WidescreenFixesPack | [ThirteenAG/WidescreenFixesPack](https://github.com/ThirteenAG/WidescreenFixesPack) | Reference `e9550ff793a50744b6569f3cace8ca551680b861`; local compatibility patch under `Packaging` |

Keep upstream tracking branches unchanged. Fetch upstream, create a candidate branch from the current patch branch, rebase the scoped patches, then run that project's complete compatibility tests before replacing a packaged runtime. Preserve the previously installed runtime until the candidate has passed a game test. Never use a source update alone as evidence of a performance gain.

The mtld3d update passed 1,557 Windows-host and 642 Unix-host tests. Per-Wine-architecture runs reported 892 tests, 881 passed and 11 ignored. These are renderer correctness gates, not a 120 FPS game benchmark.
