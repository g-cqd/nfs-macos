# Third-party components

This file lists the software that the apps built from this repository contain or run, with the
licence, the pinned version, where its source lives and which app carries it. It is a working
inventory, not legal advice. Licence texts that must travel with a copy are in [`Licenses/`](Licenses/)
and in each app's `Contents/Resources/Licenses`. The written offer of source for the copyleft
components is in [docs/SOURCE-OFFER.md](docs/SOURCE-OFFER.md); open questions are in
[docs/LICENSING.md](docs/LICENSING.md). The licence of this repository's own code is **not yet
decided** (see `docs/LICENSING.md`).

The apps are: **NFSMW** (Need for Speed Most Wanted), **CoD4** (Call of Duty 4), **FC2** (Far Cry 2,
import and bundled editions), **NFS2015** (Need for Speed 2015, import and bundled editions) and,
not yet shipped, the **arm64 route** described in [docs/ARM64ROUTE.md](docs/ARM64ROUTE.md).
No game data, no EA software and no Apple framework is covered here; see "Not covered" below.

## Components our apps ship or run

| Component | Version / pin | Licence (SPDX) | Source | Shipped in |
|---|---|---|---|---|
| **Wine**, x86_64 runtime built for Rosetta (NFSMW line) | `g-cqd/wine` branch `nfsmw-macos`, `f064add996bbf4819acf49f48bab263735279800` (Wine 11.0 stable `db11d0fe6a16` + 13 commits: CrossOver 26.2.0 and 26.3.0 source changes, macOS driver and cursor fixes, documentation) | `LGPL-2.1-or-later` (parts of Wine's `libs/` carry other licences, below) | https://github.com/g-cqd/wine/tree/nfsmw-macos; the app also carries `Resources/Sources/wine-source.tar.gz` | NFSMW |
| **Wine**, x86_64 runtime, `cod4-tested` profile | CX26.3 / Wine 11.0 with the cooperative x87 handshake. Exact source commit **not recorded** in this repository | `LGPL-2.1-or-later` | Same lineage as the row above; correspondence **unconfirmed** (open item 3 in `docs/LICENSING.md`) | CoD4, FC2 |
| **Wine**, x86_64 runtime, NFS2015 profile | `athei/wine` `cx-26-patched` `1a7b0c766262276e7e7bb50c80abe5ccd08e292b` (tag `athei-cx-26-patched-1a7b0c76` on `g-cqd/wine`) + 4 patches, built tree `1e98e299ad2900fce2ab4f103cc1f98608fc7bfa` | `LGPL-2.1-or-later` | [`Packaging/NFS2015Runtime/`](Packaging/NFS2015Runtime/) (`BUILD.md`, `patches/`, `rebuild-deviations/`) and `Resources/Sources/wine-nfs2015-source.tar.gz` in the app. Commit `1e98e299` is **not published** on GitHub | NFS2015 |
| **Wine**, native arm64 (`arm64-macos`) | `g-cqd/wine` branch `arm64-macos`, `89a212b2895086361159e5a38036bf70f4d13267` = `development` + 12 commits | `LGPL-2.1-or-later` | https://github.com/g-cqd/wine/tree/arm64-macos | arm64 route (not yet shipped) |
| **Wine**, WoW64 x86 CPU hook (`wow64-cpu`) | `g-cqd/wine` branch `wow64-cpu`, `c92ef791ef93c6e177821278c89769e2ead02be9` = `arm64-macos` + 1 commit | `LGPL-2.1-or-later` | https://github.com/g-cqd/wine/tree/wow64-cpu | arm64 route (not yet shipped) |
| **Wine base** | `athei/wine` `cx-26-patched`, tip `d23b3977452` (Wine 11.0 stable + 15 commits), carried by `g-cqd/wine` `development` `9bd6d74b374` | `LGPL-2.1-or-later` | https://github.com/athei/wine; upstream https://gitlab.winehq.org/wine/wine | all Wine rows |
| **rosetta3** (translator, CPU backend, `r3wow64.dll`, tools) | `g-cqd/rosetta3` | `MIT`, Copyright (c) 2026 g-cqd | https://github.com/g-cqd/rosetta3 | arm64 route (not yet shipped) |
| **mtld3d** (Direct3D 9 to Metal) | `g-cqd/mtld3d` `7d108a4a7bf983cb0f993ffae2aa39ca159f2c6f` (fork of `athei/mtld3d`); FC2 bundled still pins `845b6c914a55633cbe099a076432d2dbe3656d1d` | `Zlib` (Copyright (c) 2026 Alexander Theissen) | https://github.com/g-cqd/mtld3d; the app carries `Resources/Sources/mtld3d-source.tar.gz` | NFSMW, CoD4, FC2; NFS2015 carries an **unpinned** build under `lib/wine/d3d9/mtld3d` (see `docs/UPSTREAMS.md`) |
| mtld3d's Rust crates (statically linked) | locked in `windows/Cargo.lock` and `unix/Cargo.lock` at `7d108a4`; listed in the next table | see next table | crates.io | wherever mtld3d ships |
| **x87sidecar** | `g-cqd/x87sidecar` `c3969379750531fb124859ae742ab4f727f54f9c` (fork of `athei/x87sidecar`, itself derived from `Lifeisawful/rosettax87_jit`); binary `sidecarSHA256` in `Packaging/runtime-inputs.json` | `MIT` (Copyright (c) 2025 Lifeisawful) | https://github.com/g-cqd/x87sidecar | all four apps (`Contents/Helpers/x87sidecar`) |
| **DXMT** (Direct3D 11 to Metal) | `v0.80`, release asset `dxmt-v0.80-builtin.tar.gz`, tag commit `589adb780354b461645b29999cefaf533594ee99`, used unmodified | `MIT` (Copyright (c) 2023 Feifan He); the published build also contains `Zlib` code from DXVK (`src/util/dxvk.LICENSE`), `MIT` DXBC parser code from Microsoft, and, per its build files, statically linked LLVM libraries (`Apache-2.0 WITH LLVM-exception`; LLVM version not established) | https://github.com/3Shain/dxmt/tree/v0.80; text in [`Packaging/Licenses/dxmt-v0.80-LICENSE.txt`](Packaging/Licenses/dxmt-v0.80-LICENSE.txt). DXMT `main` has been LGPL since 2026-04-25: a newer DXMT needs a new licence review | NFS2015 only |
| **Wine Mono** | `10.4.1`, `wine-mono-10.4.1-x86.msi`, SHA-256 `071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23` | A mix of projects. Per the release's `COPYING`: most of Mono is available as LGPL or MIT X11, `ICSharpCode.SharpZipLib` is GPL with an exception, the winforms, WPF, monoDX and System.Speech libraries are `MIT`, FNA is `MS-PL`/`MIT`, FAudio, FNA3D, MojoShader and SDL3 are `Zlib`. The `COPYING` file of the source release is the authority | Installer https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.msi; **complete source** https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-src.tar.xz | NFS2015 bundled edition only (installed into the app's own prefix; `Licenses/wine-mono.txt`) |
| **Ultimate ASI Loader** (`dinput8.dll`) | binary copied from the retained NFSMW base app; version **not recorded** | `MIT` (Copyright (c) 2023 ThirteenAG) | https://github.com/ThirteenAG/Ultimate-ASI-Loader | NFSMW |
| **WidescreenFixesPack** (`NFSMostWanted.WidescreenFix.asi`) | reference `e9550ff793a50744b6569f3cace8ca551680b861` plus our patch [`Packaging/widescreen-light-streaks.patch`](Packaging/widescreen-light-streaks.patch) | `MIT` (Copyright (c) 2018 ThirteenAG); its submodules (injector, IniReader, Hooking.Patterns, spdlog, filewatch, ModUtils, ...) carry their own licences | https://github.com/ThirteenAG/WidescreenFixesPack | NFSMW |
| **XtendedInput** (`NFS_XtendedInput.asi`) | `xan1242/NFS-XtendedInput` `60958fc1928308023457e3ae94a2f3e79cf3c9b5`; includes `pulzed/mINI` | `MIT` (Copyright (c) 2022-2023 Lovro Pleše, 2023 Berkay Yiğit); `mINI` `MIT` | https://github.com/xan1242/NFS-XtendedInput; the app carries `Resources/Sources/XtendedInput-source.tar.gz` | NFSMW |
| NFSMW rumble helper and unlocks plugin (`NFSMW_RumbleHelper.exe`, `Z_NFSMW_Rumble.asi`, `Z_NFSMW_Unlocks.asi`) | sources in the retained base app's `Resources/Sources/rumble` and `unlocks` | **Our own code; licence undecided** (open item 1). The helper uses SDL3 (`Zlib`) | not yet in this repository | NFSMW |

### Wine's bundled libraries

Wine's source tree carries libraries under their own licences in `libs/`; they are compiled into the
Wine modules we ship. At `1a7b0c766262276e7e7bb50c80abe5ccd08e292b` the directories are `capstone`,
`faudio`, `fluidsynth`, `gsm`, `jpeg`, `jxr`, `lcms2`, `ldap`, `mpg123`, `musl`, `png`, `tiff`,
`tomcrypt`, `vkd3d`, `xml2`, `xslt`, `zlib` (plus Wine's own small GUID and compiler-support
libraries). Each has its own licence file (`LICENSE`, `COPYING`, `COPYRIGHT` or `LICENSE.TXT`); the
ones whose first lines name the licence are: `zlib` (zlib licence), `ldap` (OpenLDAP Public
License 2.8), `fluidsynth` (LGPL, per its `COPYING.md`), `musl` (MIT), `lcms2` (Little CMS, MIT-style),
`tomcrypt` (dual: public domain / WTFPL), `vkd3d` (LGPL-2.1-or-later), `mpg123` (LGPL-2.1, per its
`LICENSE`). For the rest (`capstone`, `faudio`, `gsm`, `jpeg`, `jxr`, `png`, `tiff`, `xml2`, `xslt`) the
licence file in the Wine source archive is authoritative; this summary does not restate it. The
Wine source archives that travel with the apps include all of those files.

### Libraries loaded by Wine (`lib/external`, all Wine apps)

Pinned in [`Packaging/dependency-sources.json`](Packaging/dependency-sources.json) (URL and SHA-256 of the
source tarball). The apps copy the source tarballs into `Resources/Sources/Wine-dependencies` and the licence
files into `Resources/Licenses/Wine-dependencies`. SPDX ids follow the Homebrew formula metadata and the
`COPYING` files that travel with the libraries; where they differ from upstream wording the upstream
file governs.

| Library | Version | Licence of the shipped library (SPDX) | Notes |
|---|---|---|---|
| GnuTLS | 3.8.13 | `LGPL-2.1-or-later` | its command-line tools (`GPL-3.0-only`) are not shipped |
| Nettle (also `libhogweed`) | 4.0 | `GPL-2.0-or-later OR LGPL-3.0-or-later` | |
| GMP | 6.3.0 | `LGPL-3.0-or-later OR GPL-2.0-or-later` | |
| libtasn1 | 4.21.0 | `LGPL-2.1-or-later` | |
| libidn2 | 2.3.8 | `GPL-2.0-or-later OR LGPL-3.0-or-later` | plus Unicode data terms (`COPYING.unicode`) |
| libunistring | 1.4.2 | `GPL-2.0-only OR LGPL-3.0-or-later` per the formula metadata | upstream states `GPL-2.0-or-later OR LGPL-3.0-or-later`; **confirm** |
| GNU gettext (`libintl`) | 1.0 | `LGPL-2.1-or-later` for `libintl`; the gettext programs are `GPL-3.0-or-later` and not shipped | |
| p11-kit | 0.26.5 | `BSD-3-Clause` | |
| FreeType | 2.14.3 | `FTL OR GPL-2.0-or-later` | the FreeType licence asks for a credit; see `NOTICE` |
| libpng | 1.6.58 | `libpng-2.0` | |
| SDL3 | 3.4.14 | `Zlib` | |
| sdl2-compat | 2.32.70 | `Zlib` | |

### Rust crates statically linked into mtld3d (`7d108a4`)

Taken from `cargo tree -e normal` on the shipped targets (`i686` and `x86_64` Windows, `x86_64` macOS) with
the committed lockfiles; development and test-only crates are not listed.

| Licence expression | Crates |
|---|---|
| `MIT OR Apache-2.0` | anstream, anstyle, anstyle-parse, anstyle-query, anstyle-wincon, bitflags, cfg-if, colorchoice, env_filter, env_logger, heck, is_terminal_polyfill, libc, log, once_cell_polyfill, proc-macro2, quote, syn, windows-link, windows-sys |
| `Apache-2.0 OR MIT` | rustc-hash, utf8parse |
| `MIT` | block2, objc2, objc2-encode, objc2-foundation, snmalloc-rs, snmalloc-sys (snmalloc itself, Microsoft, `MIT`), strum, strum_macros, xbr |
| `Zlib OR Apache-2.0 OR MIT` | dispatch2, objc2-app-kit, objc2-core-foundation, objc2-core-graphics, objc2-core-video, objc2-metal, objc2-metal-fx, objc2-quartz-core |
| `Unlicense OR MIT` | jiff, jiff-core |
| `ISC` | libloading |
| `BSL-1.0` | xxhash-rust |
| `BSD-3-Clause` | zstd, zstd-safe, zstd-sys (bundles zstd 1.5.7) |
| `(MIT OR Apache-2.0) AND Unicode-3.0` | unicode-ident |

These licences ask that their notices accompany binary copies. The crate sources and licence files are
in the published crates; `NOTICE` records the obligation and `docs/LICENSING.md` lists producing a
generated notice file (for example with `cargo about`) as an open item.

## Not covered

* **Game data** (Need for Speed Most Wanted, Call of Duty 4, Far Cry 2, Need for Speed 2015) belongs to its
  publishers. Import editions contain none; bundled editions carry the player's own, unmodified copy.
* **EA's client** (portable NFS2015 edition) is EA's proprietary installer output, shipped unmodified for the
  player's own use; `Licenses/ea-client.txt` in that app says where it came from.
* **Apple D3DMetal / Game Porting Toolkit** is **not** shipped. Earlier revisions retained it; the NFS2015
  recipe no longer does and no recipe selects the `gptk` backend.
* **MoltenVK and the Vulkan loader are not shipped.** The runtimes are configured `--without-vulkan`; Wine's
  own `winevulkan` import libraries and stubs are part of Wine. Checked 2026-10-08 against the staged runtime
  inputs: no `MoltenVK` or Vulkan loader library is present in any of them.
* **Apple Rosetta** is used on the user's Mac as the system provides it; nothing of it is distributed.
  `x87sidecar` interoperates with it at run time (see `docs/LICENSING.md`).
* **Provisioning profiles, certificates and keys** are never part of the repository or of a source archive.
