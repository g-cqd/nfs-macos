# Licences and source availability for the Need for Speed (2015) runtime

This app is an unofficial local package. It contains no game data and no part of EA's
software. The game and the EA app are the user's own installation, run in place.

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

Together these allow anyone holding this app to reproduce the runtime it contains. A copy of
the LGPL text ships in `Contents/Resources/Licenses`.

## dxmt — the Direct3D 11 backend used by the game

`dxmt` v0.80 is used unmodified, as the published `dxmt-v0.80-builtin.tar.gz` release asset
from `3Shain/dxmt`, pinned by SHA-256. Its own licence and notices travel with it; nothing in
this project modifies it. It implements Direct3D 11 on Metal and needs no Apple framework and
no Vulkan.

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
