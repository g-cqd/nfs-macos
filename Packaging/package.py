#!/usr/bin/env python3
"""Assemble the pinned local installation; never modify its source directories."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
from widescreen_compat import patched_widescreen
from game_data import omit_original_data
from optimize_runtime import optimize
from rosetta_request import build_rosetta_request

PROJECT = Path(__file__).resolve().parent.parent
TOOLS = PROJECT.parent
GAME = TOOLS.parent / "NFSMW"
RUNTIME = TOOLS / "wine-nfsmw-vertex-20260926"
RENDERER = TOOLS / "public-sources/mtld3d-clean/.wine-isolated/sdk/lib/wine/d3d9/mtld3d"
DESTINATION = PROJECT / "Build/Need for Speed Most Wanted.app"
APP = PROJECT / "Build/.assembling.app"
EXE_HASH = "bde12bdd158b7f861078ad4527f5a656f34c6068e4a2120f28044f92f0fa158c"
DEPS_HASH = "e88f2070e305b29a21cad490cb243bd4e40cbefb570505c9fefc2bc2b1877c6e"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def clone(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/bin/cp", "-cR", str(source), str(target)], check=True)


def source_archive(repo, name, destination):
    revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    subprocess.run(["git", "-C", str(repo), "archive", "--format=tar.gz", "HEAD",
                    "-o", str(destination / (name + "-source.tar.gz"))], check=True)
    patch = subprocess.check_output(["git", "-C", str(repo), "diff", "HEAD"])
    (destination / (name + ".patch")).write_bytes(patch)
    return revision


def collect_sources(resources):
    sources = resources / "Sources"
    notices = resources / "Licenses"
    sources.mkdir()
    notices.mkdir()
    for name in ["WidescreenFixesPack", "Ultimate-ASI-Loader"]:
        shutil.copyfile(PROJECT / "Evidence" / (name + "-license.txt"), notices / (name + ".txt"))
    shutil.copyfile(PROJECT / "Packaging/widescreen-light-streaks.patch", sources / "widescreen-light-streaks.patch")
    revisions = {}
    for directory, name in [("public-sources/mtld3d-clean", "mtld3d"), ("public-sources/x87sidecar", "x87sidecar"),
                            ("public-sources/wine", "wine"),
                            ("wine-build", "wine-build"), ("NFS-XtendedInput", "XtendedInput")]:
        repo = TOOLS / directory
        revisions[name] = source_archive(repo, name, sources)
        license_file = repo / "LICENSE"
        if license_file.exists(): shutil.copyfile(license_file, notices / (name + ".txt"))
    clone(TOOLS / "x87sidecar-src/benchmarks/bench_native_boundary.c", sources / "bench_native_boundary.c")
    clone(PROJECT / "Packaging/WineGameInfo.plist", sources / "WineGameInfo.plist")
    clone(TOOLS / "diagnostics/cursor-source/cursor-recovery.patch", sources / "wine-cursor.patch")
    for name in ["LICENSE", "COPYING.LIB", "AUTHORS"]:
        shutil.copyfile(TOOLS / "wine-cursor-src" / name, notices / ("Wine-" + name + ".txt"))
    for directory, name in [("diagnostics/rumble-lab", "rumble"), ("diagnostics/garage-edit", "unlocks")]:
        target = sources / name
        target.mkdir()
        for item in (TOOLS / directory).iterdir():
            if item.is_file() and item.suffix in {".c", ".h", ".sh"}:
                shutil.copyfile(item, target / item.name)
    deps = PROJECT / "Evidence/wine-deps.tar.xz"
    if digest(deps) != DEPS_HASH: raise ValueError("Dependency source archive checksum mismatch")
    dependency_info = notices / "Wine-dependencies"
    dependency_info.mkdir()
    excluded = {"bison", "ca-certificates", "libtool", "pkgconf", "m4"}
    with tarfile.open(deps, "r:xz") as archive:
        for member in archive:
            parts = Path(member.name).parts
            if not member.isfile() or len(parts) < 4 or parts[0] != "Cellar" or parts[1] in excluded:
                continue
            leaf = parts[-1].upper()
            if not (leaf.startswith(("LICENSE", "COPYING", "COPYRIGHT", "AUTHORS"))
                    or ".brew" in parts and leaf.endswith(".RB")):
                continue
            if member.size > 1024 * 1024: raise ValueError("Unexpected oversized dependency notice")
            target = dependency_info.joinpath(*parts[1:])
            target.parent.mkdir(parents=True, exist_ok=True)
            stream = archive.extractfile(member)
            if stream is None: raise ValueError("Missing dependency notice data")
            target.write_bytes(stream.read())
    clone(PROJECT / "Evidence/DependencySources", sources / "Wine-dependencies")
    clone(PROJECT / "Packaging/dependency-sources.json", sources / "dependency-sources.json")
    subprocess.run(["/usr/bin/tar", "-czf", str(sources / "NFSMW-launcher-source.tar.gz"),
        "-C", str(PROJECT), "Package.swift", "Sources", "Tests", "Packaging", "README.md", "docs", "tools", "PLAN.md", "SETTINGS-PLAN.md"], check=True)
    return revisions


def main(include_game_data=True):
    if digest(GAME / "speed.exe") != EXE_HASH: raise ValueError("Unexpected game executable")
    if DESTINATION.exists(): raise FileExistsError("Keep or move the previous Build app before packaging again")
    if APP.exists(): raise FileExistsError("Keep or move the previous Build app before packaging again")
    contents = APP / "Contents"
    resources = contents / "Resources"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Helpers").mkdir()
    resources.mkdir()
    binary_dir = Path(subprocess.check_output(["xcrun", "swift", "build", "-c", "release", "--show-bin-path"],
        cwd=PROJECT, text=True).strip())
    clone(binary_dir / "NFSMWLauncher", contents / "MacOS/NFSMWLauncher")
    clone(binary_dir / "NFSMWSession", contents / "Helpers/NFSMWSession")
    clone(TOOLS / "x87sidecar-nfsmw-20260926", contents / "Helpers/x87sidecar")
    build_rosetta_request(APP)
    wine = contents / "SharedSupport/Wine"
    clone(RUNTIME, wine)
    clone(TOOLS / "wine-cursor-build/loader/wine", wine / "lib/wine/x86_64-unix/wine")
    shutil.rmtree(wine / "lib/wine/d3d9/mtld3d")
    clone(RENDERER, wine / "lib/wine/d3d9/mtld3d")
    for path in ["include", "share/man", "lib/wine/tests", "lib/wine/d3d9/mtld3d-v0.7.0",
                 "lib/wine/d3d9/mtld3d.before-vertex", "lib/wine/dxgi/gptk", "lib/wine/dxgi/dxmt",
                 "lib/external/D3DMetal.framework", "lib/external/D3DMetal-License.rtf", "lib/external/libd3dshared.dylib"]:
        item = wine / path
        if item.is_dir(): shutil.rmtree(item)
        elif item.exists(): item.unlink()
    for item in (wine / "bin").iterdir():
        if item.name not in {"wine", "wineserver"}: item.unlink()
    for item in wine.rglob("*"):
        if item.is_file() and (item.suffix == ".a" or item.name == ".DS_Store"): item.unlink()
    (resources / "size-optimization.json").write_text(json.dumps(optimize(wine), indent=2) + "\n")

    template = resources / "Game"
    template.mkdir()
    folders = ["CARS", "CREDITS", "FRONTEND", "GLOBAL", "LANGUAGES", "MEMCARD", "MOVIES",
               "NIS", "SOUND", "SUBTITLES", "TRACKS"]
    for name in folders: clone(GAME / name, template / name)
    for name in ["speed.exe", "dinput8.dll", "mtld3d.conf", "bin.dat", "server.cfg", "server.dll"]:
        clone(GAME / name, template / name)
    for name in ["NFSMW_RumbleHelper.exe", "NFSMostWanted.WidescreenFix.asi", "NFSMostWanted.WidescreenFix.ini",
                 "NFSMostWanted.WidescreenFix.tpk", "NFS_XtendedInput.asi", "NFS_XtendedInput.ini",
                 "NFS_XtendedInput.default.ini", "Z_NFSMW_Rumble.asi", "Z_NFSMW_Unlocks.asi", "nfs_cursor.cur"]:
        clone(GAME / "scripts" / name, template / "scripts" / name)
    for item in template.rglob(".DS_Store"): item.unlink()
    plugin = template / "scripts/NFSMostWanted.WidescreenFix.asi"
    plugin.write_bytes(patched_widescreen(plugin.read_bytes()))
    widescreen = template / "scripts/NFSMostWanted.WidescreenFix.ini"
    adjusted, count = re.subn(r"(?m)^SimRate\s*=\s*-2[^\n]*", "SimRate = 120                            ; Fixed rate across monitor refresh rates.", widescreen.read_text())
    if count != 1: raise ValueError("Unexpected simulation rate configuration")
    widescreen.write_text(adjusted)
    entries = []
    for item in sorted(template.rglob("*")):
        if item.is_symlink(): raise ValueError("Unexpected game symlink: " + str(item))
        if item.is_file():
            entries.append(dict(path=item.relative_to(template).as_posix(), size=item.stat().st_size, sha256=digest(item)))
    version = hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()[:24]
    (resources / "game-manifest.json").write_text(json.dumps(dict(version=version, gameFiles=entries,
        gameDataIncluded=include_game_data), indent=2) + "\n")
    if not include_game_data:
        omit_original_data(template, entries)
    defaults = resources / "Defaults"
    defaults.mkdir()
    clone(PROJECT / "Packaging/settings.reg", defaults / "settings.reg")
    fresh = PROJECT / "Packaging/FreshCareer.save"
    if digest(fresh) != "873d10faef46e09ecc8aaa4e8bed3af4aa684e15ab07975f2fd553565aab0846":
        raise ValueError("Unexpected fresh career template")
    clone(fresh, defaults / "FreshCareer.save")
    revisions = collect_sources(resources)
    (resources / "runtime-provenance.json").write_text(json.dumps(dict(
        sources=revisions, gameExecutableSHA256=EXE_HASH,
        wine="cx-26.3.0-6 / d82e36650b0 with cursor recovery",
        renderer="1b0bf1f upstream base plus CPU frame cap and vertex stride/read-span corrections",
        gameModeOptIn=True, appSandboxEnabled=False, hostDriveMappings=False,
        x87="4048fcf plus exact f80 boundary conversion and empty-tag cache",
        minimumMacOS="15.0", architecture="Apple Silicon with Rosetta", capFPS=120,
        sustained120FPSVerified=False, personalSavesIncluded=False,
        gameDataIncluded=include_game_data), indent=2) + "\n")
    info = dict(CFBundleExecutable="NFSMWLauncher", CFBundleIdentifier="local.nfsmw.mac",
        CFBundleName="Most Wanted", CFBundleDisplayName="Need for Speed Most Wanted",
        CFBundlePackageType="APPL", CFBundleShortVersionString="1.0", CFBundleVersion="5",
        LSMinimumSystemVersion="15.0", LSArchitecturePriority=["arm64"], NSHighResolutionCapable=True,
        LSSupportsGameMode=True, LSApplicationCategoryType="public.app-category.racing-games",
        NSHumanReadableCopyright="Unofficial local macOS package. Component notices are included.")
    with (contents / "Info.plist").open("wb") as stream: plistlib.dump(info, stream)
    APP.rename(DESTINATION)
    print(json.dumps(dict(app=str(DESTINATION), gameFiles=len(entries), gameBytes=sum(f["size"] for f in entries), version=version)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--without-game-data", action="store_true",
                       help="Include the runtime and fixes; import the user's PC game folder on first use")
    modes.add_argument("--with-game-data", action="store_true", help="Include the complete game (default)")
    parser.add_argument("--output", type=Path, default=DESTINATION)
    options = parser.parse_args()
    DESTINATION = options.output.resolve()
    if DESTINATION.suffix != ".app": parser.error("--output must end in .app")
    APP = DESTINATION.parent / ("." + DESTINATION.name + "-assembling")
    main(include_game_data=not options.without_game_data)
