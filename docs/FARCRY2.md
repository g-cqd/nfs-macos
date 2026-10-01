# Far Cry 2 recipe (import edition only)

Far Cry 2 (Ubisoft Montreal, Dunia engine, PC, 2008) is packaged with the same method as
Need for Speed: Most Wanted and Call of Duty 4: the app ships the native starter and session
helper, the pinned Wine 11.0 runtime, mtld3d (Direct3D 9 to Metal), x87sidecar and its compatibility
files. It ships **no game files**. The player selects their own installed Windows game folder; the
session recognises it, copies it into private player storage and verifies every copied byte.

```sh
python3 Packaging/build.py --game farcry2 --game-data import --output "Build/Far Cry 2 Import.app" --no-archive
```

Python 3.11 or newer is required. The shared pipeline, input names and signing are in
[Bundling](BUNDLING.md); runtime pins are in [Upstreams](UPSTREAMS.md). Far Cry 2 reuses the
`cod4-tested` runtime profile (CX26.3 / Wine 11.0 with the cooperative x87 handshake). The profile
name is historical; its hashes are shared and must be updated together.

**There is no bundled edition.** `Packaging/Recipes/farcry2.json` declares `"editions": ["import"]`;
`build.py --game-data bundled` and `assemble.stage_game(..., include_game_data=True)` refuse it. A
bundled edition needs pinned executable hashes of a verified build, and none exists for this game
(see "What is not verified"). Adding one later is a recipe decision, not a code change.

## Status at a glance

| Area | State |
| --- | --- |
| Install recognition, verified import, app-update re-verification | **Implemented**, tested with synthetic trees only |
| `GamerProfile.xml` in-place editor, settings catalog, Maximum Quality preset | **Implemented**, tested with an invented profile built from public attribute names |
| Player data outside the prefix, links, backups and restore | **Implemented**, tested against a synthetic Wine profile layout |
| Direct3D 9 forced (profile attribute and hidden D3D10 libraries) | **Implemented**; effect on the real game **unverified** |
| Session helper, SwiftUI starter, developer launcher script | **Implemented**; never run against the real game |
| Import, links, `G:` working directory, cleanup on the real bundled Wine | **Demonstrated** with a synthetic game tree (`tools/farcry2/smoke_session.py`, 22 checks): a stand-in executable ran as `C:\FarCry2\bin\FarCry2.exe` with `G:\bin` as its working directory, then `G:` and the lease were removed and no wineserver remained |
| mtld3d profile for `FarCry2.exe` | **Proposed** only (below); mtld3d was not edited |
| Known-build digests, exact file list, exact setting value ranges | **Unverified**: need a legitimate install |
| Start-up, rendering, input, audio, saves, x87 use, stutter | **Unverified**: no game run exists |

Nothing here shows that Far Cry 2 runs. A recipe alone does not prove compatibility.

## How a legitimate installation is recognised

The rules live only in the recipe (`importRules`), are copied into `game-manifest.json` by the
packager and are evaluated by `InstallScanner` on the player's Mac. The same JSON is loaded by the
Swift tests, so the packager and the scanner cannot drift apart.

| Check | Rule |
| --- | --- |
| Folder | The selected folder is a real directory, not a link, and contains `bin` and `Data_Win32` (matched case-insensitively; the on-disk spelling is kept). |
| Executable | `bin/FarCry2.exe`, at least 1 MiB, a valid PE image, machine i386, not a DLL. |
| Engine library | `bin/Dunia.dll`, at least 1 MiB. |
| Data | `Data_Win32` totals at least 1 GiB and every `.fat` has a `.dat` and the reverse, so a half-copied install is rejected. |
| Safety | No symbolic links or special files anywhere in the copied folders, at most 20,000 files and 16 GB, depth at most 10, no two names differing only by case. |
| Copied | Everything under `bin` and `Data_Win32`, except `mtld3d.conf`, `mtld3d_shaders.bin`, `mtld3d-logs/`, `*.log` and `*.tmp`. Installer leftovers (`unins000.*`, `goggame-*.info`, `Support/` redistributables, manuals, bonus content) are never copied. |
| Recorded | SHA-256 of every copied file, the executable's `VS_FIXEDFILEINFO` version and `CompanyName`, `ProductName`, `OriginalFilename` and similar strings, and informational store hints (`gog`, `steam`, `uplay`). |

The scan is **edition tolerant**. It does not require a specific patch level, language or edition; a
GOG "Fortune's Edition", a Steam or a disc install passes if it has this shape. `knownBuilds` is
**empty**: the recipe contains no executable digest because none can be derived from public
information, so every build is reported as "not on the verified list" in the starter and the session
log. To pin a build, hash `bin/FarCry2.exe` of a legitimate install and add
`{"name": "...", "executableSHA256": "..."}` to `importRules.knownBuilds`; builds then show their
name. The thresholds (1 MiB, 1 GiB) and the exclusion list are conservative guesses from public
reports and must be revisited with a real file list.

Every selected file is hashed once during recognition and verified again while it is copied (cloned
with APFS where possible), so a file that changes in between is rejected. The inventory is saved next
to the generation (`inventory.json`, `origin.json`), so an app update re-verifies the private copy
without needing the original folder. A failed import leaves the active game and saves untouched.

## Player data and what is preserved

```text
~/Library/Application Support/FarCry2Mac/
  Data/Versions/import-<id>/Game      verified working copy (bin, Data_Win32, bin/mtld3d.conf)
  Data/Current                        points to the active generation
  Data/Prefix                         private Wine prefix; drive_c/FarCry2 -> ../../Current/Game
  Data/Saves/FarCry2/Documents        the game's "My Games\Far Cry 2" (GamerProfile.xml, Saved Games)
  Data/Saves/FarCry2/LocalAppData     the game's "AppData\Local\My Games\Far Cry 2" (input map)
  Data/Backups/FarCry2/<uuid>/        bounded backups, plus GamerProfile.original.xml
  Logs/ RuntimeHome/ Temporary/
```

Locations of the game's own files come from public reports (PCGamingWiki as quoted by search results;
the page itself returned HTTP 403 to the fetch tool): `%USERPROFILE%\Documents\My Games\Far Cry 2\GamerProfile.xml`,
`...\Saved Games\` and `%LOCALAPPDATA%\My Games\Far Cry 2\InputUserActionMap.xml`.

Measured on the pinned Wine in a throwaway prefix: Wine 11.0 (CrossOver lineage) names the single
Windows user **`crossover`** whatever `USER` says and creates real `Documents` and `AppData\Local`
folders with no host aliases. The adapter therefore discovers the one non-`Public` folder under
`drive_c/users` instead of assuming a name, and refuses an ambiguous prefix.

Both game folders are symbolic links, with relative targets, from the Wine profile into
`Data/Saves`. Deleting or rebuilding the prefix, or updating the app, keeps saves and settings. An
existing real folder is moved into `Data/Saves`; if both exist, the real one is moved aside to
`Saves/FarCry2/Conflicts` and nothing is deleted. A link that points elsewhere, a file in the way or
a host alias in the profile stops the session before play.

`GamerProfile.xml` is edited **in place**: a byte-level tokenizer finds start tags and replaces only
attribute values, so comments, whitespace, attribute order, unknown elements and UTF-8, BOM or UTF-16
encoding are kept. A file that is not well-formed, declares a DOCTYPE or has no `RenderProfile` is
reported as unrecognised and never modified; renderer settings still apply. The first time the
starter edits the profile it saves the game's untouched copy to `Backups/FarCry2/GamerProfile.original.xml`.
Settings and the renderer file change in one recoverable transaction. A backup copies both
player folders (at most 4,096 files and 512 MiB each, no links), a restore first backs up the current
data, and an interrupted restore is completed or reversed at the next session.

## Launch

The session runs `C:\FarCry2\bin\FarCry2.exe` with the working directory `bin`, after mapping a
**game-only `G:` drive** (the same fix as CoD4's `fileSysCheck.cfg` / `C:\windows` failure: Wine cannot
reverse-map a native working directory through the `C:` link). `G:` points only at the private game
folder, is removed after Wine stops, and a leftover is removed at the next session. No host home or
root drive is exposed. Environment (`LaunchEnvironment`):

- `WINEDLLPATH` to the bundled `lib/wine/d3d9/mtld3d`, `WINE_COMPATDB` `d3d9=mtld3d`, `WINEMSYNC=1`.
- `ROSETTA_X87_PATH` to the bundled x87sidecar (always on in the app; `FARCRY2_X87=0` in the developer
  script for an A/B run).
- `WINEDLLOVERRIDES=mscoree,mshtml=;d3d10,d3d10_1,d3d10core,dxgi=` (see below).
- Metal HUD and mtld3d performance logging off, as in the other apps.

`bin/mtld3d.conf` (renderer settings) sits next to the executable because mtld3d reads it from the
executable's directory; the shader cache `bin/mtld3d_shaders.bin` and logs `bin/mtld3d-logs/` appear
there and are never imported or verified. `tools/farcry2/Play_FarCry2.command` is the developer
equivalent of `Play_CoD4.command`; it was syntax-checked only.

## Direct3D 9 versus Direct3D 10

Far Cry 2 offers DirectX 9, 10 and 10.1 renderers. mtld3d implements Direct3D 9 (and 8) only. A
Direct3D 10 path in this runtime would be Wine's wined3d; DXMT and D3DMetal are removed from the
bundle, and that route is **untested and unsupported**. The DX9 path is forced twice:

1. **Profile.** On every launch the starter writes `Platform="d3d9"` on `RenderProfile` and, if the
   quality id carries the `d3d10` suffix (public samples show `customd3d10`), removes the suffix. Public
   samples show the values `d3d9` and `d3d10a`.
2. **Libraries.** For this game only, `d3d10`, `d3d10_1`, `d3d10core` and `dxgi` are hidden from the
   process. The game supported Windows XP, which has none of them, and mtld3d's `d3d9.dll` and
   `mtld3d.dll` import none of them (checked with `strings`). This also covers the first launch, before
   any profile exists. **Not verified on the real game**; if the game needs `dxgi.dll` for something
   unexpected, remove the override in `LaunchEnvironment`.

## Settings and the Maximum Quality preset

Only options with public evidence of their attribute name and values are exposed. They are read from
reports of the game's `GamerProfile.xml` (AnandTech thread, Steam and PCGamingWiki posts) and are the
starter's limits, not claims about the engine's full range.

| Option | Stored as | Values offered |
| --- | --- | --- |
| Resolution | `RenderProfile` `ResolutionX/Y` **and** every `CustomQuality/quality` `ResolutionX/Y` | `WxH`, 640 to 7680 by 480 to 4320 |
| Fullscreen, vertical sync, show frame rate | `Fullscreen`, `VSync`, `ShowFPS` | 0, 1 |
| Refresh rate | `RefreshRate` | 0 (display default), 60, 120 |
| Anti-aliasing | `MultiSampleMode` | 0, 2, 4 |
| Alpha to coverage | `AlphaToCoverage` | 0, 1 |
| Skip highest texture detail | `DisableMip0Loading` | 0, 1 |
| Game shader loading | `AllowAsynchShaderLoading` | 0, 1 |
| Rendering scale | `render.scale` in `bin/mtld3d.conf` | 0.5, 0.67, 0.75, 1 |
| Compile shaders asynchronously | `shader.asyncCompile` | false, true |
| Frame limit | `present.maxFps` | 0, 30, 60, 120 |

Options whose attribute is absent from a profile are reported and **not created**. Detail levels
(`EnvironmentQuality`, `TextureQuality`, `ShadowQuality`, HDR, bloom and the like) are deliberately
not exposed because public reports show the attributes but not their value ranges; the starter keeps
whatever the game wrote.

**Maximum Quality** sets: the display's native pixel size, fullscreen, vertical sync off, 4x MSAA with
alpha to coverage, the highest texture level (`DisableMip0Loading=0`), `render.scale=1` (MetalFX is not
used) and synchronous shader compilation. It does not touch sound, input or detail levels. For the
game's own top preset, choose **Ultra High** in the in-game Video options once; the starter keeps it.
Whether the display mode is offered, and what 4x MSAA with `ATOC` costs, is unverified.

## Proposed mtld3d profile (not applied, not verified)

`windows/core/src/app_profile.rs` matches on the executable name and version-resource strings. A
`farcry2` entry would key on `exe: "FarCry2.exe"`. The version strings are **unknown**: no copy was
read. The session writes them to its log on import (`Version resource: CompanyName=...; ProductName=...`);
pin two of `company`, `product`, `original_filename` from that line so the rule cannot match another
program. Settings worth testing, each a suspicion rather than a finding:

- `present.maxFps=30` or `60`: public Linux reports mention a tutorial cutscene problem at high frame
  rates and a physics glitch; unconfirmed whether the cause applies here.
- `shader.asyncCompile=false` (already in the recipe's `mtld3d.conf`): avoids omitted draws while a
  pipeline compiles.
- Depth and alpha-to-coverage: mtld3d supports INTZ/DF24/RESZ and the `ATOC` extension, which Dunia's
  DX9 path may use; the existing `gta-iv` entry (`caps.dfFormats`, `depth.aliasSameSize`,
  `adapter.spoof`) is the closest analogue if wrong depth or vendor-specific behaviour appears. Only
  change them on evidence from an F12 capture.

## Known risks

- **Copy protection and activation.** The 2008 retail disc used SecuROM, with online activation; the
  Steam build uses Steam, and the Ubisoft/Uplay build injects `uplay32.dll` (public reports of the
  community Multi-Fixer, which distinguishes Steam, "Retail (GOG)" and Uplay builds). GOG's build is
  advertised as DRM-free. The recipe patches nothing and bundles no crack, so SecuROM, Steam or Uplay
  builds may refuse to start. The import reports store hints (`gog`, `steam`, `uplay`) as information
  only and never blocks.
- **x87.** Whether Dunia executes x87 in hot code is unknown. The sidecar is on by default as in the
  tested recipes; use `FARCRY2_X87=0` to compare.
- **Shader compile stutter.** Pipelines compile on first use and are cached in
  `bin/mtld3d_shaders.bin`. Synchronous compilation preserves draws but can pause. No frame-time
  measurement exists.
- **Many CPU cores.** Public reports (the Multi-Fixer adds a process-affinity option) describe crashes
  on CPUs with many logical processors. The pinned Wine has no `WINE_CPU_TOPOLOGY` (checked with
  `strings`); it does contain `WINENCPU`, whose meaning here is unknown. No mitigation is applied.
- **Save-slot limit.** A Lutris note says more than 27 saves crash the game under Wine. Unverified,
  and the starter cannot enforce it; the manual quicksave creates a new save each time.
- **Profile layout.** Element and attribute names come from public samples. If the real file differs,
  the profile is reported as unrecognised and left alone.
- **Runtime libraries.** The 2008 build probably expects VC9 runtimes and `d3dx9_*`; Wine's builtins
  are used and nothing is installed. A missing-DLL failure would appear in the session log.
- **Online and multiplayer.** Not supported (`supportsMP` is false); the game's online services
  are long gone.
- **32-bit address space.** A large game under a 32-bit process; mtld3d's native threads keep their
  stacks outside it, but memory behaviour is untested.
- **Display.** Retina mode is enabled in the prefix registry. The display modes the game will list
  through mtld3d are untested; a mode the game does not offer may fall back or minimise.

## What is not verified without a game install

Every row below needs a legitimate installed copy and a person to play:

- the real file list, sizes and digests (hence `knownBuilds`, thresholds and exclusions);
- the real `GamerProfile.xml` structure, value domains and whether a profile exists before first run;
- that `C:\FarCry2\bin\FarCry2.exe` starts with `G:` as working directory;
- that the game runs with `d3d10` and `dxgi` hidden, and with x87sidecar on and off;
- menu, loading and gameplay rendering, shadows, vegetation, water, HDR, MSAA and alpha to coverage;
- keyboard, mouse and controller input, audio, save, quit, relaunch and resume;
- frame time, shader-stutter behaviour and `present.maxFps` effects.

## Test steps for someone who owns the game

Use a throwaway player folder and keep your own installation untouched:

1. Open the app. If asked, install Rosetta. Choose **Import Game Folder...** and select the folder that
   contains `bin` and `Data_Win32`. Expect an explicit message for a wrong folder, a partial copy or
   a link. Note the "Recognised" line (version, build, store hint) and report it.
2. Open the log. Copy the line `Version resource: ...` and the `Recognised installation` line.
3. In a terminal, hash your executable: `shasum -a 256 "<folder>/bin/FarCry2.exe"`; report it with
   your edition (disc, Steam, GOG, Uplay) and patch level.
4. Press **Play**. First launch with default settings; note whether a window appears, which renderer
   the game reports, and any crash. Quit the game and look for `GamerProfile.xml` under
   `Data/Saves/FarCry2/Documents`.
5. Check that `Platform` in that file reads `d3d9` after the next launch, and that the game's Video
   options offer only DirectX 9.
6. In Graphics choose **Maximum Quality for This Display**, save and play. Select **Ultra High**
   in the game's Video options. Report resolution, anti-aliasing, foliage edges and stutter.
7. Play the tutorial for several minutes; quicksave, quit, relaunch, resume. Use **Saves & backups** to
   back up, change something, restore, and confirm the earlier state.
8. After quitting, confirm `dosdevices/g:` is gone from `Data/Prefix` and no Wine process of this app
   remains.
9. Optional A/B: run with `FARCRY2_X87=0` through `tools/farcry2/Play_FarCry2.command` and compare.

## Automated tests and gates

Run `xcrun swift test` and `python3 Packaging/check_farcry2_recipe.py`. They use synthetic trees,
synthetic PE images and an invented profile only; no game byte exists in the repository, and a gate
fails the packaging checks if a Far Cry 2 executable, engine library or archive file appears in the tree.

| Suite | What it pins |
| --- | --- |
| PE reader | Machine, DLL flag, file version and version strings; every truncation of the header is rejected; hostile resource offsets are ignored |
| Recognition rules and scanner | Required files, exclusions, case-insensitive folders, links, byte and file ceilings, archive pairing, 64-bit or non-PE executables, known builds, store hints, the real recipe's thresholds, an installation that is never modified |
| Scan-based installer | Copy of recognised files, app-owned renderer config wins over a player's, update from the saved inventory after the original is gone, tampered copy blocks an update, rejected imports keep the active game |
| Game kind and environment | Far Cry 2 identifiers, D3D10 hiding, existing games unchanged |
| Game drive | G: maps only the private game, is removed, an unrelated mapping is never removed, stale cleanup (paths outside the mapped C drive) |
| Profile editor | Byte-exact round trip, in-place edits, nested resolution, encodings, DOCTYPE, malformed, NUL, oversized and over-deep input, value injection |
| Settings | Reading, DX9 forcing and quality-id normalisation, absent attributes, rejected values, renderer keys, Maximum Quality |
| Player data and backups | Links, migration, conflicts, rebuilt prefix, host aliases, ambiguity, backup limit, restore and recovery |
| Session options and starter model | Argument parsing; Rosetta gating; import, play, discard and backup requests |
| `check_farcry2_recipe.py` | Schema mutations, manifest content, version changes with rules, `build.py` refusal, no game files in the tree |
| `tools/farcry2/smoke_session.py` | Not part of `swift test`. Runs a built app's session helper against a synthetic tree on the real bundled Wine: import, Wine profile name and links, in-place profile edit, backup, play lifecycle and cleanup |

Seven mutations of the guarded behaviours (ignored exclusions, no archive pairing, forward-order XML
edits, a deleted conflict folder, no saved inventory, visible D3D10 libraries, restore without the
safety backup) were each caught by the suite that owns them.

## Public sources

- PCGamingWiki, [Far Cry 2](https://www.pcgamingwiki.com/wiki/Far_Cry_2): configuration and save paths, renderer entry (as quoted by search results; the page was not retrievable).
- AnandTech forum, [Far Cry 2 / FIXED](https://forums.anandtech.com/threads/far-cry-2-fixed.233887/): a `GamerProfile.xml` `RenderProfile` sample with `Platform="d3d9"`.
- Justin McCandless, [Far Cry 2 Configuration File Help](https://www.justinmccandless.com/post/far-cry-2-configuration-file-help/): file location and the `Fullscreen` fix.
- Helix Mod, [Far Cry 2 (DX9)](https://helixmod.blogspot.com/2013/01/far-cry-2-dx9.html): `bin`, `Data_Win32` and `FarCry2.exe`.
- FoxAhead, [Far Cry 2 Multi-Fixer](https://github.com/FoxAhead/Far-Cry-2-Multi-Fixer/releases): Steam, Retail (GOG) and Uplay builds, `Dunia.dll`, process affinity.
- Lutris, [Far Cry 2](https://lutris.net/games/far-cry-2/) and ProtonDB: Direct3D 10 mode reported as buggy; save-count and frame-rate notes.
