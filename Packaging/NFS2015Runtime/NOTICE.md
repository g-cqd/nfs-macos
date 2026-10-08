# Licences and source availability for the Need for Speed (2015) runtime

This app is an unofficial local package. The Import edition contains no game data and no part
of EA's software: the game and the EA app are the user's own installation, run in place. A
Bundled edition carries the user's own, unmodified game files, and the complete portable edition
also carries EA's own client as EA's official installer made it, for the user's personal use;
`Contents/Resources/Licenses/ea-client.txt` says exactly what it is and where it came from.

## Wine — LGPL-2.1-or-later

The runtime under `Contents/SharedSupport/Wine` is a modified Wine. Wine is distributed under
the GNU Lesser General Public License, version 2.1 or later, which requires that the complete
corresponding source for the modified library be made available to anyone who receives the
binary.

That obligation is met by the material shipped in `Contents/Resources/Sources`:

- `wine-nfs2015/BUILD.md` — the exact upstream repository, branch and commit the build starts
  from, the configure flags, and the toolchain that produced the delivered binaries.
- `wine-nfs2015/patches/*.patch` — every modification applied to that base, as
  `git format-patch` files that apply cleanly with `git am`.
- `wine-nfs2015-source.tar.gz` — the complete source tree of the modified Wine at the exact
  revision built, so the source is present in the package and not only by reference.

- `wine-nfs2015/rebuild-deviations/` — every change made to the upstream build scripts for the
  rebuild of 2026-10-07/08 that produced these binaries, as diffs.

Together these allow anyone holding this app to reproduce the runtime it contains, although the
rebuilt binaries are not bit-identical to those of the earlier apps (`BUILD.md` says which files
differ and what is not known about why). A copy of the LGPL text ships in
`Contents/Resources/Licenses`.

## dxmt — the Direct3D 11 backend used by the game

`dxmt` v0.80 is used unmodified, as the published `dxmt-v0.80-builtin.tar.gz` release asset
from `3Shain/dxmt`, pinned by SHA-256. It is released under the MIT licence, which asks that its
copyright and permission notice accompany copies; that text is in
`Contents/Resources/Licenses/dxmt.txt`, verbatim from the `LICENSE` file of the `v0.80` tag
(commit `589adb780354b461645b29999cefaf533594ee99`, SHA-256
`6b928413c6308c106f3e0080bd94b6427b56d587d400fd40e6cbfbab7d9c4ae1`, pinned in the recipe and
checked by the audit). Nothing in this project modifies dxmt. It implements Direct3D 11 on Metal
and needs no Apple framework and no Vulkan. The `main` branch of dxmt has been LGPL since
2026-04-25, so a newer dxmt must come with its own licence text and a new pin.

## Apple D3DMetal — not shipped

Earlier revisions of this bundle retained Apple's `D3DMetal.framework` and `libd3dshared.dylib`
from the Game Porting Toolkit evaluation environment, because the `gptk` backend was what the EA
client had been measured on. **They are no longer retained.** The client was then measured on
`dxmt`, where it renders its full interface and logs none of the shared-handle failures D3DMetal
produced, so nothing in this recipe selects `gptk` and no Apple-signed artifact is included.

The redistribution question those terms would have raised therefore does not arise for this
package. It was closed by measurement, not by interpreting Apple's licence.

## Everything else

Component notices for the remaining bundled libraries, and for the retained sources of the
other games' runtimes, are in `Contents/Resources/Licenses` as they are for every bundle this
packager produces.
