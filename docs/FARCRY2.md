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

Build inputs move: on 2026-10-01 the retained Most Wanted v5 app was no longer on the Desktop, and
`~/Developer/mtld3d` had advanced past the pinned `5f5331a`, which the pin check rejects. The
import app was built with `--input baseApp="<Game Builds>/Most Wanted Bundled.app"` (its retained
`Sources` and `Licenses`) and `--input mtld3dSource=<clean clone checked out at 5f5331a>`. No source
tree was modified.

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
| Shader cache kept in the player folder, keyed to the renderer build, reset, exported and imported; default `mtld3d.conf` with a source and a verification state for every option | **Implemented**, tested with synthetic caches (real mtld3d writers, no game data) and on the bundled Wine with a stand-in executable (`tools/farcry2/smoke_session.py`) |
| That a warm cache removes the first-run pauses, how long a cold run compiles, start-up time with a full cache | **Unverified**: needs a game session; the earlier numbers are leads only (see "Shader cache") |
| Compile during the loading screen, bounded prewarm, `shaderCache.dir` | **Proposed** for mtld3d (see "Shader cache"); nothing in mtld3d was changed |
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
  ShaderCache/<build id>/             the saved shader cache (mtld3d_shaders.bin, info.json), see below
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
a host alias in the profile stops the session before play. The Saves & backups page tells the player
how many set-aside folders exist.

`GamerProfile.xml` is edited **in place**: a byte-level tokenizer finds start tags and replaces only
attribute values, so comments, whitespace, attribute order, unknown elements and UTF-8, BOM or UTF-16
encoding are kept. A file that is not well-formed, declares a DOCTYPE or has no `RenderProfile` is
reported as unrecognised and never modified; renderer settings still apply. The first time the
starter edits the profile it saves the game's untouched copy to `Backups/FarCry2/GamerProfile.original.xml`.
Settings and the renderer file change in one recoverable transaction. A backup copies both
player folders (at most 4,096 files and 512 MiB each, no links), a restore first backs up the current
data (that safety copy may take the count one above the limit of 20, so a full set can still be
restored), and an interrupted restore is completed or reversed at the next session.

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
executable's directory. The shader cache `bin/mtld3d_shaders.bin` is placed there from the saved copy
before play and taken back after it (see "Shader cache"); logs `bin/mtld3d-logs/` appear there too. None
of them is imported or verified. `tools/farcry2/Play_FarCry2.command` is the developer
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

## Shader cache and first-run compile pauses

Far Cry 2 asks mtld3d for shaders while it plays, and mtld3d compiles each new shader and pipeline for
the Mac's GPU the first time a draw needs it. The renderer keeps what it compiled so a later run can skip
that work. This section records how that works (read from mtld3d's source, not measured on this game),
what the starter does about it, and what it cannot do.

### Leads from an earlier run (not reproduced here)

A previous run without `mtld3d.conf` reported gameplay and loading frames that were CPU bound, 946 shaders
compiled over 38.9 s on the first run (one burst of 655 in 23.8 s, others of 6.4 s and 4.7 s), 15 pre-warmed,
a persistent cache of 2 MB afterwards, and a shipped `bin/mtld3d_shaders.bin` of 15 KB. No game was
available to check them, so they are not evidence for any claim below; they only show the order of
magnitude worth measuring. Two parts of the brief were corrected by reading the source: the cache switch
is `shaderCache.enable` (not `shader.cache`), and the cache is not keyed to GPU, driver or macOS.

### What mtld3d does (source read at b22073b; the pinned 5f5331a has the same container format 20 and shader schema 79)

| Question | Answer | Where |
| --- | --- | --- |
| Where is the cache? | `mtld3d_shaders.bin` in the directory of the running executable, plus `mtld3d_shaders.bin.lock` (a lock sidecar) and `mtld3d_shaders.bin.<pid>-<n>.tmp` during compaction. For this game that is `C:\FarCry2\bin`, which is the active generation's `bin`. The path is fixed; no option moves it. | `windows/d3d9/src/encoder.rs` (`EncoderThread::spawn`), `windows/core/src/shader_cache.rs` (`lock_path`, `temp_sibling`) |
| What is in it? | A 16-byte header (`MTLD3DSH`, container format, shader schema), then zstd chunks, each with an xxh3 checksum. Records hold MSL text; for programmable shaders also the **DXSO bytecode** and every specialization input; and pipeline recipes made of logical state (formats, blend, vertex layout), never handles. | `shader_cache.rs`, `shader_cache/source.rs` |
| What invalidates it? | (1) A different container format or shader schema in the header: the **whole file is deleted** when the renderer loads it (`SHADER_CACHE_SCHEMA_VERSION`, bumped by hand, is 79). (2) A different **emitter fingerprint** (xxh3 over `src/dxso/**`, `dxso.rs`, `vs_draw.rs`, `ps_draw.rs` and `unix/shared/src/mtl.rs`, computed in `windows/core/build.rs`) in a record: programmable shaders are regenerated from their retained DXSO during prewarm; fixed-function shaders and their pipelines are dropped. (3) Damage: reading stops at the first chunk with a bad checksum or a torn tail, and the tail is cut. | `shader_cache.rs` (`load`, `parse_records`), `unix/unix/src/shader_prewarm.rs` |
| Is it keyed to the mtld3d commit, GPU, driver or macOS? | **No.** Nothing in the file or in the load path reads any of them. The cache holds source and recipes; the renderer recompiles them on the Mac that loads it, and a record that fails to compile there is skipped, not mis-rendered. `GpuCaps` (unified memory, alignment) affects buffer storage, not shader text. | `shader_cache.rs`, `windows/core/src/gpu_caps.rs`, `shader_prewarm.rs` |
| Can it move to another Mac? | Yes, as a file, between builds with the same format, schema and emitter. A build with a different emitter loads it and regenerates; a different schema deletes it. Hence the starter's own key (below). | as above |
| What does "process-start prewarm" do? | It runs when the device is created, not literally at process start. A prewarm thread loads the cache under the lock, regenerates stale MSL, compiles every recorded library (up to eight workers), then every recorded pipeline, and hands the handles to the encoder, which waits for them **before it accepts the first frame**. It then compacts the file into one bundle. Start-up therefore grows with the cache. | `shader_prewarm.rs`, `docs/ARCHITECTURE.md` (shader cache) |
| What is `shader.asyncCompile`? | With either value, four worker threads build first-use shaders and pipelines. With `true` a draw whose build is still running can be left out of its frame; with `false` it is kept and the frame waits. | `mtld3d.conf`, `docs/ARCHITECTURE.md` |

The cache contains the game's own shader bytecode. **Do not ship a pre-generated cache.** It would embed
game data, so no cache is packaged: the recipe never includes one, `Packaging/audit.py` fails an app that
contains any `mtld3d_shaders*` file, `check_shader_cache.py` fails a tracked cache or export file, and the
import rules skip the cache, its lock and its marker if they appear in a player's folder.

### What the starter does (implemented)

- **Storage.** The saved cache lives in `ShaderCache/<build id>/` in the player folder, outside the Wine
  prefix and outside every game generation. A new generation (app update, re-import), a rebuilt prefix or
  an app update therefore keeps it.
- **Key.** The packager writes `Contents/Resources/renderer-cache-key.json` for recipes with
  `"shaderCache": true` (Far Cry 2 only): the pinned mtld3d revision, the container format and shader
  schema read from `shader_cache.rs`, and a SHA-256 over the same files and in the same order as
  mtld3d's emitter fingerprint (`Packaging/shader_cache_key.py`; the file set and order were checked
  against the `rerun-if-changed` list of a real mtld3d build). The build id is a hash of all of them.
  Another pin, schema, format or emitter gets a new, empty folder; the old one is never loaded and the
  newest two are kept before the oldest is removed. GPU and macOS are recorded for information, not keyed.
  Carrying a cache across pins by relying on mtld3d's regeneration is possible but is **not enabled**.
- **Launch.** Because the renderer reads a fixed path, the session copies the saved cache into `bin` before
  play with a marker naming the build id, and after the game exits (and at the start of every session, so
  a crash loses nothing) takes the file back. Only a regular file with the marker is taken; a link, a file
  the starter did not place, another build's file, an empty file, a file with another schema or one over
  256 MiB never replaces the saved cache. A torn tail is cut. Cache problems are logged and never stop
  the game.
- **Integrity.** `ShaderCacheFormat` walks the chunks as mtld3d does and checks each xxh3 (`XXH3` is
  reproduced and tested against the `xxhash-rust` crate for every length class), so the starter keeps only
  what the renderer would accept. Records are not decompressed; this app never reads the bytecode.
- **Reset, export, import.** *Shader cache* in the starter shows the state and offers reset (confirmed),
  export and import. An export is one `.fc2shadercache` file: a manifest (renderer key, SHA-256, size,
  GPU and macOS as information) followed by the cache. Import refuses a damaged file, a file over the
  limit, another renderer build (naming both), a payload the renderer would delete or that holds no records,
  and a destination or source that is a link. It joins the chunks of both caches under one header, which
  mtld3d accepts and compacts at its next start (checked with the real parser). Importing the same
  file again is recognised and changes nothing. Exports stay outside the player folder.
  An export holds shader data generated on your Mac; it is for your own use. The starter never uploads it.
- **First-run notice.** While there is no cache, the Play page and the cache page explain the one-time
  compile pause. The session log says whether a launch starts cold or from N saved bytes.
- **Defaults.** `bin/mtld3d.conf` is documented option by option with its evidence and what is
  unverified (`shaderCache.enable=true`, `shader.asyncCompile=false`, `render.scale=1`, `present.maxFps=0`,
  `memory.vramBudgetMB` left at mtld3d's 1024 for a 32-bit game, telemetry off through `RUST_LOG`).
  `check_farcry2_recipe.py` requires every active key to be a key mtld3d documents, to be justified by
  the comment above it and to state what is unverified.

### Compile during the loading screen: what can and cannot be done

mtld3d only learns of a shader when the game creates it, and of a pipeline when a draw uses it. A
pipeline needs the vertex layout, the render target formats, blend state and sample count of that draw,
and a pixel shader's emitted text depends on what is bound to its samplers (schema 66 types the sampler
slots from the bound textures). So the renderer cannot compile what a game has not yet asked for, and
nothing outside the game knows the list in advance. What is sound:

| Option | Effect | Cost and status |
| --- | --- | --- |
| Persistent cache and prewarm at device creation | Combinations from earlier sessions are compiled before the first frame, in parallel, instead of one by one in play. | Longer start-up that grows with the cache; the first session still compiles. **Implemented** in mtld3d; the starter keeps the file alive. Gain **unverified**. |
| Compile synchronously (`shader.asyncCompile=false`) | A first-use compile pauses the frame instead of dropping draws. If the game touches a shader during a loading screen, the pause is hidden there. | Only helps if Dunia uses its shaders while loading, which is **unverified**. **Implemented** as the default. |
| Warm-up before the player cares | Play once past the first scenes, then export the cache for other Macs. | The notice says so; nothing to build. |
| Ship a generated cache | Would remove first-run pauses for everyone. | **Rejected**: it embeds game bytecode. |
| Compile from the starter | Would need the game's bytecode and the renderer. | **Rejected**: not possible without the game running. |
| Guess a loading screen | Compile only while the game looks idle. | **Rejected**: unsound heuristics, and the game still asks later. |

### Proposals for mtld3d (not applied; mtld3d was not edited)

1. **`shaderCache.dir`, like `log.dir`.** Today the starter copies the file in and out. A key accepting a
   directory (relative to the executable or absolute) would let the starter point it at the saved
   folder and delete the copy and the crash recovery. Files: `windows/d3d9/src/encoder.rs` (the path built
   in `EncoderThread::spawn`), `windows/core/src/config.rs`, `mtld3d.conf`, `docs/ARCHITECTURE.md`. Behaviour:
   an absolute Windows path is translated with `wine_path::unix_path`; an unusable directory logs once and
   disables the cache as a missing path does today. Test: a host unit test of path resolution for relative,
   absolute, empty and untranslatable values, plus the existing e2e cold-start test with the key set.
   The sidecar lock and `compact`'s rename must stay in the same directory.
2. **Bounded prewarm.** Prewarm blocks the first frame until every recorded shader is compiled. A time
   budget (`shaderCache.prewarmBudgetMs`, 0 meaning unbounded as today) would compile in file order, which is
   first-use order, until the budget ends, hand the partial warm cache to the encoder, and give the rest to
   the existing compile workers. The invariant to keep: a draw that needs a key still queued must wait for
   that job, never start a second build of the same key. Files: `unix/unix/src/shader_prewarm.rs`,
   `unix/unix/src/encoder/compile.rs`, `windows/core/src/config.rs`, `docs/ARCHITECTURE.md`. Tests: a unit
   test with a fake clock (budget 0 returns at once with the rest queued; unbounded matches today), a test that a
   live miss on a queued key adds no second job, and an e2e that counts builds per key. Worth doing only
   if a real session shows a long start-up with a large cache.
3. **Cache carry-over across pins** that share the container format and schema. mtld3d already regenerates
   programmable MSL when only the emitter changed, so a starter could seed a new build's cache from the
   newest old one. Not enabled here because the brief asks for a pin-keyed cache; it needs a real
   session to show the regenerated cache is complete enough to be worth the risk.

Measure before any of these: a session log with the `shader_cache: pre-warmed` and `shaders: N compiled`
lines, a first run and a second run, and the frame times of both. Dumping DXSO with
`debug.bytecodeDumpDir` would show whether Dunia creates its shaders during loading.

## Known risks

- **Copy protection and activation.** The 2008 retail disc used SecuROM, with online activation; the
  Steam build uses Steam, and the Ubisoft/Uplay build injects `uplay32.dll` (public reports of the
  community Multi-Fixer, which distinguishes Steam, "Retail (GOG)" and Uplay builds). GOG's build is
  advertised as DRM-free. The recipe patches nothing and bundles no crack, so SecuROM, Steam or Uplay
  builds may refuse to start. The import reports store hints (`gog`, `steam`, `uplay`) as information
  only and never blocks.
- **x87.** Whether Dunia executes x87 in hot code is unknown. The sidecar is on by default as in the
  tested recipes; use `FARCRY2_X87=0` to compare.
- **Shader compile stutter.** Pipelines compile on first use and are cached; the starter keeps the cache
  across updates (see "Shader cache"). Synchronous compilation preserves draws but can pause, most on the
  first run. No frame-time measurement exists.
- **Many CPU cores.** Public reports (the Multi-Fixer adds a process-affinity option) describe crashes
  on CPUs with many logical processors. The pinned Wine has no `WINE_CPU_TOPOLOGY` (checked with
  `strings`); it does contain `WINENCPU`, whose meaning here is unknown. No mitigation is applied.
- **Save-slot limit.** A Lutris note says more than 27 saves crash the game under Wine. Unverified,
  and the starter cannot enforce it; the manual quicksave creates a new save each time.
- **Profile layout.** Element and attribute names come from public samples. If the real file differs,
  the profile is reported as unrecognised and left alone.
- **Runtime libraries.** The 2008 build probably expects VC9 runtimes and `d3dx9_*`; Wine's builtins
  are used and nothing is installed. A missing-DLL failure would appear in the session log.
- **Disk use.** Every import creates a new generation (a full copy unless APFS can clone it) and old
  generations are not pruned, as for the other games.
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
- frame time, shader-stutter behaviour and `present.maxFps` effects;
- that mtld3d writes `mtld3d_shaders.bin` into the generation's `bin` when the game is started as
  `C:\FarCry2\bin\FarCry2.exe` (the smoke test uses a stand-in executable that writes no cache);
- how long a cold run compiles, what a warm run saves, and the start-up time with a full cache;
- whether Dunia creates its shaders during loading (would make a loading-screen pause invisible).

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
10. Shader cache: on the first launch note whether the game pauses while scenes load and keep the session
    log (`Shader cache: none yet`). Quit, relaunch and compare; the log should say `starting from N saved
    bytes`. Look in the log folder of the game (`bin/mtld3d-logs`, copy it before the next launch) for the
    `shader_cache: pre-warmed` and `shaders: N compiled` lines and report both runs. Then export the
    cache, reset it, import the export, and confirm the next launch starts from saved bytes again.

## Automated tests and gates

Run `xcrun swift test`, `python3 Packaging/check_farcry2_recipe.py` and `python3 Packaging/check_shader_cache.py`. They use synthetic trees,
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
| XXH3 | The 64-bit hash against `xxhash-rust` vectors for every length class and the multi-block path |
| Cache format | Real mtld3d-written caches (committed as base64, synthetic entries only): chunk walk, checksums, torn tails, every cut, bit flips, strays, unknown kinds, joins equal to the file the real parser accepted, size limits, slices |
| Cache key and export | The key file the packager writes, identifier changes with every field, unsafe or malformed keys, export round trip, truncation, tampering, extra bytes, lying lengths, newer versions, control characters |
| Cache store | Cold and warm launches, compaction, crash recovery, torn and foreign files, links, size limit, marker links, damaged saved cache, cleanup, storage outside prefix and generation, survival of prefix removal and a new generation, another build starting empty, pruning, reset |
| Cache export and import | Round trip between two player folders, merge, repeated import, import after compaction, other builds, schema and format, unusable payloads, damaged and foreign files, links, destinations, limits, crashed-session recovery |
| Renderer defaults and request | Shipped values equal the catalog defaults; an edit keeps every comment, the cache key and a player's own lines; telemetry off in the launch environment; cache files never imported; request validation; old state files still decode |
| Starter model | First-run notice only while empty, actions gated by state, reset keeps unsaved edits, busy starter ignores actions |
| `check_shader_cache.py` | The packager's key against a synthetic mtld3d tree: file set and order, what changes the digest and what must not, linked or missing sources, malformed constants and revisions, opt-in only, no cache or export file in the tree |
| `tools/farcry2/smoke_session.py` | Not part of `swift test`. Runs a built app's session helper against a synthetic tree on the real bundled Wine: import, Wine profile name and links, in-place profile edit, backup, play lifecycle and cleanup, and, when the app has a renderer key, cold and warm launches, import, repeated and damaged imports, crash recovery, export, reset |

Nine mutations of the cache behaviours (a foreign file taken as ours, an empty file replacing the saved cache, the emitter missing from the key, repeated imports growing the cache, no pruning, an unchecked export digest, unchecked chunk checksums, uncleaned compaction files, an import that ignores the revision) were each caught. Seven mutations of the guarded behaviours (ignored exclusions, no archive pairing, forward-order XML
edits, a deleted conflict folder, no saved inventory, visible D3D10 libraries, restore without the
safety backup) were each caught by the suite that owns them.

## Public sources

- PCGamingWiki, [Far Cry 2](https://www.pcgamingwiki.com/wiki/Far_Cry_2): configuration and save paths, renderer entry (as quoted by search results; the page was not retrievable).
- AnandTech forum, [Far Cry 2 / FIXED](https://forums.anandtech.com/threads/far-cry-2-fixed.233887/): a `GamerProfile.xml` `RenderProfile` sample with `Platform="d3d9"`.
- Justin McCandless, [Far Cry 2 Configuration File Help](https://www.justinmccandless.com/post/far-cry-2-configuration-file-help/): file location and the `Fullscreen` fix.
- Helix Mod, [Far Cry 2 (DX9)](https://helixmod.blogspot.com/2013/01/far-cry-2-dx9.html): `bin`, `Data_Win32` and `FarCry2.exe`.
- FoxAhead, [Far Cry 2 Multi-Fixer](https://github.com/FoxAhead/Far-Cry-2-Multi-Fixer/releases): Steam, Retail (GOG) and Uplay builds, `Dunia.dll`, process affinity.
- Lutris, [Far Cry 2](https://lutris.net/games/far-cry-2/) and ProtonDB: Direct3D 10 mode reported as buggy; save-count and frame-rate notes.
