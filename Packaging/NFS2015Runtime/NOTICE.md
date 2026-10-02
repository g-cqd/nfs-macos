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

## Apple D3DMetal — an open question, not a decision made here

**This needs a decision from the user before the app is given to anyone else.**

The bundle currently retains Apple's `D3DMetal.framework` and `libd3dshared.dylib`, from the
Game Porting Toolkit 4.0 beta 2 evaluation environment, because the `gptk` backend is what the
EA client's interface was measured to render correctly on. Apple distributes that framework
under its own licence terms for an evaluation environment, and those terms govern whether it
may be redistributed inside a third-party application. This project has not obtained or
interpreted those terms.

The packager treats it as a vendor artifact: it is never re-signed and its search paths are
never rewritten, so it keeps Apple's own signature, and the audit proves that signature is
still present and not ad-hoc. That addresses provenance; it does not address redistribution
rights.

Two ways out, if the answer is that it may not be redistributed:

1. **Measure the EA client on `dxmt`.** The game already runs on it. If the client's interface
   also renders acceptably, the framework leaves the bundle entirely. This is a configuration
   change, not a code change: one line in the recipe's `renderers` list.
2. **Measure the EA client on `wined3d`.** Slower, but it ships with Wine and raises no
   third-party question.

Neither has been measured. Until one is, the framework is required for the client.

## Everything else

Component notices for the remaining bundled libraries, and for the retained sources of the
other games' runtimes, are in `Contents/Resources/Licenses` as they are for every bundle this
packager produces.
