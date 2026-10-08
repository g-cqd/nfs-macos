# Licensing: open decisions

Status of 2026-10-08. The inventory is [THIRD_PARTY.md](../THIRD_PARTY.md), the notices are in
[NOTICE](../NOTICE) and [Licenses/](../Licenses/), the source offer is in
[SOURCE-OFFER.md](SOURCE-OFFER.md). These are drafts for the owner; none of this is legal advice.

## Decided

* `rosetta3` (translator, CPU backend, loader, tools, `r3wow64.dll`): **MIT**, Copyright (c) 2026 g-cqd.
* The Wine patches we carry (`arm64-macos`, `wow64-cpu`, `development`, `nfsmw-macos`, the NFS2015
  patch series) stay **LGPL-2.1-or-later**, because they are part of Wine. `r3wow64.dll` is a separate
  MIT module that Wine loads through its public WoW64 CPU interface.

## Open

1. **Licence of this repository's own code (the launcher, sessions, packaging scripts, docs, the NFSMW
   rumble helper and unlocks plugin). Not decided; no `LICENSE` file has been added.** Until it is, the
   code is all rights reserved by default, which also means third parties cannot lawfully reuse it.
   The choice interacts with: the LGPL parts that travel with it (the NFS2015 patch series is LGPL by
   necessity), the permissively licensed code we copy (mtld3d is zlib, x87sidecar MIT), and whether the
   packaging scripts should match `rosetta3` (MIT).
2. **Who answers a source request, and for how long.** The draft offer names the issue tracker of
   `g-cqd/nfs-macos` and a three-year term. Confirm both, or give an address, and decide how physical
   media would be handled.
3. **Source of the Wine in the Call of Duty 4 and Far Cry 2 apps.** The runtime profile `cod4-tested`
   has different `bin/wine`, `bin/wineserver`, `ntdll.so` and `ntdll.dll` hashes from the Most Wanted
   profile (`Packaging/runtime-inputs.json`), and no recipe records which commit it was built from.
   Their corresponding source is therefore not established. Either find and publish the tree, or
   rebuild those apps from a published commit.
4. **The Need for Speed (2015) Wine tree is not published.** Commit
   `1e98e299ad2900fce2ab4f103cc1f98608fc7bfa` exists only in the local build tree and in the archive
   shipped inside the app. Decide whether to push it as a branch or tag of `g-cqd/wine` (for example
   `nfs2015-fix`).
5. **The native arm64 build scripts are not published.** `scripts/build-arm64.sh` and the bring-up notes
   are in the unpublished *wine-arm64* working repository. Publish it, or move the scripts into
   `g-cqd/wine` next to the branches, before an arm64 app is distributed.
6. **`athei/wine-build` has no licence file.** The build scripts we used (and the retained
   `wine-build-source.tar.gz` that the Most Wanted app ships) are therefore
   unlicensed as published. Ask the author for a licence, or stop shipping the scripts and describe the
   configure flags instead.
7. **mtld3d in the Need for Speed (2015) runtime is unpinned.** The runtime profile carries
   `lib/wine/d3d9/mtld3d` from its own build; no revision is claimed for it (`docs/UPSTREAMS.md`). The
   licence (zlib) only needs a notice, but the notice should name a revision. Remove the directory or
   pin it.
8. **The game modifications are copied binaries.** `dinput8.dll` (Ultimate ASI Loader), the widescreen
   `.asi`, and `NFS_XtendedInput.asi` come from the retained base app with no recorded version or
   SHA-256. Pin each to the release or commit it was built from. The widescreen binary also embeds
   the submodules of WidescreenFixesPack, whose licences should be listed.
9. **`x87sidecar` interoperates with Apple's Rosetta at run time** (it locates and patches handlers in
   the system's Rosetta runtime). It is MIT and derived from `Lifeisawful/rosettax87_jit`; no Apple code
   is distributed with it as far as we can tell, but nobody has audited that. Decide whether this needs
   a legal read before wider distribution.
10. **Notices do not travel with the apps yet.** `Packaging/runtime_inputs.py` (`archive_launcher`)
    archives `Package.swift`, `Sources`, `Tests`, `Packaging`, `README.md`, `docs`, `tools` and two plan
    files, but not `THIRD_PARTY.md`, `NOTICE` or `Licenses/`. A packaging change should copy them into
    `Contents/Resources`, and `check_notice_licences.py` should assert it. Not done here (docs only).
11. **Rust crate notices.** mtld3d statically links 47 crates under MIT, Apache-2.0, Zlib, ISC,
    BSL-1.0, BSD-3-Clause, Unlicense and Unicode-3.0 terms. Generate a notice file from the lockfiles
    (for example with `cargo about`) and ship it; THIRD_PARTY.md only lists the crates.
12. **DXMT v0.80 includes LLVM** (statically linked, per its build files). Apache-2.0 asks that its text
    accompany copies; the LLVM version is not established. Check the release's notices, or ship the
    Apache-2.0 text with the DXMT licence. DXMT `main` is LGPL since 2026-04-25: any upgrade past v0.80
    needs a new review and a new pin.
13. **Wine Mono's source is linked, not mirrored.** The offer points to `dl.winehq.org`. If a three-year
    commitment is wanted, mirror the source tarball with the app's other sources.
14. **A third party's e-mail address is in `Licenses/XtendedInput.txt`.** It is the upstream author's
    copyright line, copied verbatim as the MIT licence requires (`xan1242/NFS-XtendedInput` `LICENSE`).
    Everything else in this change avoids e-mail addresses; confirm this one is acceptable in a public
    repository, or replace the file with a pointer to upstream.
15. **Two licence expressions need a second look against upstream:** libunistring (`GPL-2.0-only OR
    LGPL-3.0-or-later` per the Homebrew formula metadata that ships with the app; the upstream wording has not been
    checked here) and the statements for Wine's bundled `libs/` directories,
    which this change reads from the directories' first lines only.
16. **Names.** Product names (Need for Speed, Call of Duty, Far Cry), "CrossOver" and "Wine" are
    trademarks of their owners. The README and app names should keep saying the packages are
    unofficial and not endorsed by those owners; check the app display names with that in mind.

## Checks run for this draft

Licence texts in `Licenses/` are the bytes of the upstream files at the pinned commits (the Wine files at
`1a7b0c766262276e7e7bb50c80abe5ccd08e292b`, mtld3d at `7d108a4`, x87sidecar at `c396937`, WidescreenFixesPack
at `e9550ff`, XtendedInput at `60958fc`, Ultimate ASI Loader at `master`, rosetta3 at `main`); they equal
the copies in the retained Most Wanted app where it has one. Branch and commit facts were read from the
GitHub API on 2026-10-08. Nothing was built.
