# Written offer of source code (draft)

This is a draft prepared for the project owner to review; it is not legal advice. It covers the
components of the apps built from this repository that are licensed under the GNU Lesser General
Public License (LGPL), the GNU General Public License (GPL) or a similar copyleft licence. The
inventory is [THIRD_PARTY.md](../THIRD_PARTY.md).

## The offer

For every app we distribute that contains the components below, we provide the complete
corresponding source code: the source of the component as built, our modifications as patches,
and the scripts used to control compilation and installation. We provide it three ways:

1. **Inside the app.** Each app carries source archives in `Contents/Resources/Sources`: the modified
   Wine (`wine-source.tar.gz` in the Most Wanted app, `wine-nfs2015-source.tar.gz` plus
   `wine-nfs2015/` with patches and `BUILD.md` in the Need for Speed (2015) app), the sources of the
   libraries Wine loads (`Wine-dependencies/`, pinned in
   [`Packaging/dependency-sources.json`](../Packaging/dependency-sources.json)), and the sources of
   mtld3d, x87sidecar and the game modifications.
2. **Online, in the public repositories named below**, at the exact commits listed.
3. **On request.** Anyone who has received one of these apps may ask for the corresponding source at
   any time within **three years** after our last distribution of that version (and for as long as we
   provide support or spare parts for it). Ask by opening an issue at
   https://github.com/g-cqd/nfs-macos/issues. We will send the source on a download link, or on
   physical media for no more than the cost of performing the distribution. *(The contact point and
   the term are open decisions for the owner, see [LICENSING.md](LICENSING.md).)*

Nothing in the app's terms restricts the rights the LGPL gives you: you may modify Wine and the other
libraries, rebuild them, and run the app with your rebuilt copy (see "Replacing a library" below).

## Wine

Wine is licensed under the LGPL, version 2.1 or later. The modifications in the branches below are
licensed under the same terms. Licence text: [`Licenses/Wine-COPYING.LIB.txt`](../Licenses/Wine-COPYING.LIB.txt);
notice: [`Licenses/Wine-LICENSE.txt`](../Licenses/Wine-LICENSE.txt).

### Lineage

* WineHQ upstream: https://gitlab.winehq.org/wine/wine (Wine 11.0 stable, `db11d0fe6a16`).
* CodeWeavers' CrossOver-based tree, maintained by `athei`: https://github.com/athei/wine, branch
  `cx-26-patched`. Its history has been rewritten at least once, so we keep the exact commit we built
  from as a tag on our fork: `athei-cx-26-patched-1a7b0c76` = `1a7b0c766262276e7e7bb50c80abe5ccd08e292b`
  on https://github.com/g-cqd/wine. The later tip `d23b3977452` (Wine 11.0 stable + 15 commits) is the
  base of our `development` branch.

### What each app was built from

| App | Built from | Where | Patches |
|---|---|---|---|
| Need for Speed Most Wanted (x86_64 / Rosetta) | `g-cqd/wine` `nfsmw-macos` `f064add996bbf4819acf49f48bab263735279800` | https://github.com/g-cqd/wine/tree/nfsmw-macos; archive in the app | `git log db11d0fe6a16..f064add996bb`: 13 commits (CrossOver 26.2.0 / 26.3.0 source changes, macOS driver and cursor fixes, integration notes in `UPSTREAM.md`) |
| Need for Speed (2015) (x86_64 / Rosetta) | `athei/wine` `1a7b0c766262276e7e7bb50c80abe5ccd08e292b` + the 4 patches below, tree `1e98e299ad2900fce2ab4f103cc1f98608fc7bfa` | [`Packaging/NFS2015Runtime/`](../Packaging/NFS2015Runtime/); archive `wine-nfs2015-source.tar.gz` in the app | [`patches/0001`..`0004`](../Packaging/NFS2015Runtime/patches/) (execution-breakpoint delivery by trap-flag emulation, its budgets, `PUSHF`/`POPF` prefixes, a regression fixture), applied with `git am` |
| Call of Duty 4, Far Cry 2 (x86_64 / Rosetta, profile `cod4-tested`) | **Not recorded**: described as CX26.3 / Wine 11.0 with the cooperative x87 handshake. The `nfsmw-macos` source above is the same lineage, but the match of the shipped binaries is unverified | see the open item in [LICENSING.md](LICENSING.md) | |
| Native arm64 (not yet shipped) | `g-cqd/wine` `arm64-macos` `89a212b2895086361159e5a38036bf70f4d13267` | https://github.com/g-cqd/wine/tree/arm64-macos | 12 commits on `development` `9bd6d74b3745e5755657afeec333cdcbba14f4da` (below) |
| Native arm64 with the translator as the x86 CPU (not yet shipped) | `g-cqd/wine` `wow64-cpu` `c92ef791ef93c6e177821278c89769e2ead02be9` | https://github.com/g-cqd/wine/tree/wow64-cpu | `arm64-macos` + 1 commit |

The `g-cqd/wine` `development` branch (`9bd6d74b3745`) is `cx-26-patched` `d23b3977452` plus 9 commits:
the four execution-breakpoint commits above (as `8ae387826`, `b9092a790`, `c2b26552a`, `f7f4dfe32`), a
macOS cursor fix, `get_thread_times()` on macOS, a vkd3d MSL cache change, an x86_64 build helper and
integration notes. `arm64-macos` adds, in this order: the arm64 loader links with the default 4 GiB soft
page zero (`5d7981d1c`); the loader reports the soft page zero as the reserved low area (`97912fefa`);
arm64 spawn/exec of wineserver and the loader carries the 4 KiB page attribute (`088bc1377`);
`CAMetalLayer` instead of the x86_64-only D3DMetal hook (`aa92ca9b6`, `e32c89c71`); the macOS arm64 `x18`
TEB protocol (`409b66066`); wineserver stays on 16 KiB pages (`ba034d110`); Darwin-ABI stack-slot adapters
for syscalls with more than eight arguments (`f1938cfc1`); host address-space limit from `task_info`
(`c99e04773`); page-permission faults reported as `SIGBUS` are routed by ESR (`f8bf2bae0`); RWX memory
mapped RW and toggled on execute faults (`de9dfb24c`); and no `x87sidecar` lookup on arm64
(`89a212b28`). `wow64-cpu` adds `c92ef791e`, which makes `r3wow64.dll` the x86 CPU module of arm64 WoW64
prefixes. `git log development..arm64-macos` lists them with their full messages.

> **NFS2015 runtime source, published:** `g-cqd/wine` branch `nfs2015-runtime-0005` holds the base commit
> `1a7b0c766262276e7e7bb50c80abe5ccd08e292b` plus the NFS patches, with two tags. `nfs2015-runtime-20261008`
> (`c810543e64b`, git tree `217bbb407f32f54a0d83987784d838b1fca4b1c3`) is the source of the runtime in the
> Need for Speed (2015) apps built on 2026-10-08 (the original build tree `1e98e299` has the same git tree; only
> the commit identities differ because author e-mail addresses were replaced by the GitHub noreply address
> before publication). `nfs2015-runtime-0005-20261008` (`f4fc43f2e04`, tree
> `9adc5dd4ad152cf9f241e7c3695854bd4d5850b3`) adds the crash-context patch (kernelbase `wine-crash:` log block) and
> is the source of the `-0005` apps. Both trees were compared byte for byte with the shipped source archives.
>
> The later runtimes (patches 0006 to 0010, see [ROSETTA-SMC.md](ROSETTA-SMC.md)) are published as the tags
> `nfs2015-runtime-0007-20261008` (`8f9700351c48`), `nfs2015-runtime-0008-20261008` (`581eafadc35f`),
> `nfs2015-runtime-0009-20261008` (`3f203054cb86`) and `nfs2015-runtime-0010-20261008` (`7550ccae4d0b`) of `g-cqd/wine`,
> and the branch `nfs2015-runtime-0010` holds the newest. Each tree includes every earlier patch; the patch 0006 is in
> every tree from 0007 on, and all ten patch files are in [`Packaging/NFS2015Runtime/patches/`](../Packaging/NFS2015Runtime/patches/).

### `r3wow64.dll` and the licences

`r3wow64.dll` (rosetta3's PE shim) is a separate module that Wine loads through its public WoW64 CPU
interface. It is licensed under the MIT licence (source: https://github.com/g-cqd/rosetta3) and is not a
derivative of Wine. The Wine patches in `arm64-macos` and `wow64-cpu` that load it are part of Wine and
stay under the LGPL-2.1-or-later with the rest of the Wine they modify.

### How to rebuild

* **Need for Speed (2015) runtime:** follow [`Packaging/NFS2015Runtime/BUILD.md`](../Packaging/NFS2015Runtime/BUILD.md)
  exactly: it records the base commit, the `git am` step, the configure flags, the toolchain that
  actually produced the shipped binaries (Apple clang 21.0.0 for the Mach-O files, Homebrew mingw-w64 GCC
  16.1.0 for the PE builtins) and every deviation from the upstream build scripts
  ([`rebuild-deviations/`](../Packaging/NFS2015Runtime/rebuild-deviations/)). The build scripts are
  `athei/wine-build` (https://github.com/athei/wine-build) at `0813ba8`. The result is not bit-identical
  to earlier apps; `BUILD.md` says which files differ.
* **Most Wanted runtime:** check out `nfsmw-macos`, read its `UPSTREAM.md`, and build with the same
  recipe as above: `athei/wine-build` scripts, x86_64 configure under `arch -x86_64` with Apple clang,
  `--without-vulkan`, `--without-x`, `--with-gnutls --with-sdl --with-coreaudio`, `--enable-archs=i386,x86_64`.
  The retained `wine-build-source.tar.gz` in that app holds the scripts it used.
* **Native arm64 runtime:** configure `--enable-archs=aarch64,i386 --with-mingw=llvm-mingw` with the same
  `--without-*` list as above and `CC="/usr/bin/clang -arch arm64"`, with llvm-mingw 20261006
  (https://github.com/mstorsjo/llvm-mingw, Apache-2.0 with LLVM exceptions) for the PE side. The build
  script and notes live in the *wine-arm64* bring-up repository (`scripts/build-arm64.sh`,
  `docs/BRINGUP.md`, `SOURCES.md`), **which is not published yet**; the flags above are the complete
  set it uses. Publishing it is an open item.
* **Replacing a library:** Wine loads GnuTLS, FreeType, SDL, libpng and the other libraries in
  `Contents/SharedSupport/Wine/lib/external` as separate dynamic libraries. To use your own build,
  replace the file in a copy of the app. A copy that you modify cannot keep the original code signature;
  re-sign it with your own identity (`codesign --force --sign - <path>` for local use).

## Other copyleft components

| Component | Licence | Source |
|---|---|---|
| GnuTLS 3.8.13 | LGPL-2.1-or-later | URL and SHA-256 in `Packaging/dependency-sources.json`; tarball in the app |
| Nettle 4.0, GMP 6.3.0, libidn2 2.3.8, libunistring 1.4.2 | LGPL-3.0-or-later (or GPL-2.0-or-later, as listed in THIRD_PARTY.md) | same |
| libtasn1 4.21.0, GNU gettext 1.0 (`libintl`) | LGPL-2.1-or-later | same |
| FreeType 2.14.3 | FTL or GPL-2.0-or-later (we use the FTL) | same |
| Wine Mono 10.4.1 (NFS2015 bundled edition) | several, including LGPL and GPL-with-exception parts | https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-src.tar.xz |
| FluidSynth, mpg123 and vkd3d inside Wine | LGPL-2.1 | part of the Wine source |

The permissively licensed components (mtld3d, x87sidecar, DXMT v0.80, the game modifications, rosetta3)
need no source offer; their sources are linked in [THIRD_PARTY.md](../THIRD_PARTY.md) anyway.
