# Need for Speed (2015) recipe

The Import edition does not contain the game, and neither edition replaces any part of EA's
software. The Import edition supplies a Wine runtime, a starter and a session helper, and runs
the player's own installation where that installation already is. The Bundled edition adds the
user's own game files and a prefix of its own (see [NFS2015.md §13](NFS2015.md#13-the-bundled-edition)).

## Why this recipe is different

Need for Speed (2015) is protected by Denuvo and is activated by EA's client. **Verified:**
starting `NFS16.exe` with no EA process running exits `170` and spawns
`Core/ActivationUI.exe` together with `EALauncher.exe` carrying an empty `authCode`. The EA
app is therefore a hard dependency. Nothing in this recipe substitutes for it, emulates it,
or supplies a token; the player installs the EA app and signs in themselves.

Because the account session, the client's registry state and the activation state all live in
one Windows prefix, that prefix is never copied. EA invalidates a session when the same token
appears from more than one prefix. The app records where the player's prefix is and uses it
in place. `GameKind.nfs2015.copiesGameData` is false, so `GameInstaller` refuses to publish a
generation for this game at all, and `BundleManifest` accepts an empty inventory only for a
manifest that declares `referencesInstallation`.

Two consequences follow, and both are deliberate:

- Guest drive isolation does **not** apply. `GuestIsolation` only restricts a prefix the app
  owns; stripping drive mappings from the player's own prefix would damage their installation.
- An import build carries no per-file inventory, so an app update cannot re-verify game bytes.
  The recognition rules in the manifest are what the app checks instead.

## Verified launch sequence

1. Start the client **directly**:
   `wine 'C:\Program Files\Electronic Arts\EA Desktop\<version>\EA Desktop\EADesktop.exe' --in-process-gpu`

   `--in-process-gpu` is required: without it the EA interface renders blank, because
   Chromium's separate GPU process crashes in D3DMetal's
   `WineSwapchainCallbacks::InitializeForHWND`. Passing the flag to `EALauncher.exe` does
   **not** work — the stub does not forward it to the `EADesktop` child it creates.
2. Wait until the client is up.
3. Hand it the launch request:
   `wine '…\EA Desktop\EALauncher.exe' 'origin2://game/launch/?offerIds=1024486'`

The offer identifier `1024486` is confirmed by the activation log the installation itself
wrote (`ProgramData/Origin/Logs/NFS16_1024486_OnlineActivation_Log.html`).

The stable `EA Desktop\EA Desktop` junction the installer registers is **not** used: it is
absent in a prefix whose client has updated itself, and the host sees it as a link that need
not resolve. `NFS2015Locator` discovers the newest version folder that actually contains the
client.

### Readiness

Step 2 is two bounded host observations, both declared in the recipe, and both must hold:

- the client has at least `readinessChildren` live descendant processes (it renders its
  interface in separate `EACefSubProcess` children; a client without them is wedged), and
- a timestamp under `readinessEvidence` has advanced past the moment the client was started.

No credential, cookie or account file is ever read. If either signal does not appear within
`readinessSeconds`, the session stops and tells the player to open the EA app themselves.

## Runtime

| Setting | Value | Status |
|---|---|---|
| `WINEDLLOVERRIDES` | `IGOProxy32.exe=d;winemenubuilder.exe=d;mscoree,mshtml=` | `IGOProxy32` verified: EA's 32-bit overlay faults in wined3d |
| `WINE_COMPATDB` | `dxgi=dxmt`, for both the game and the client | Measured; see below |
| `WINE_TF_EMULATION` | `1` | Required; recipe configuration |
| `WINE_TF_MAX_STEPS` | `0` | Required; recipe configuration |
| `WINE_TF_MAX_NS` | `0` | Required; recipe configuration |

### Direct3D: dxmt, for both the game and the client

`NFS16.exe` is a 64-bit Direct3D 11 binary. mtld3d implements Direct3D 9 and 8, so it plays no
part here: the recipe declares no `renderer`, `rendererEvidence` or `mtld3dSource` input, the
packager neither verifies nor stages mtld3d, and the bundle carries no mtld3d source archive.

Both programs are served by **dxmt**, a Metal-backed Direct3D 11 implementation, selected per
executable:

| Executable | Backend | Why |
|---|---|---|
| `NFS16.exe` | `dxmt` | Measured: reaches menus and compiles shaders, where D3DMetal faults |
| `EADesktop.exe` | `dxmt` | Measured: renders the full client interface with none of the shared-handle failures D3DMetal logs |

**This settled after two reversals, and both had the same cause: naming a backend before
measuring it.** The first choice was D3DMetal, reasoned from the runtime selecting it for 64-bit
DXGI. The second was DXVK, after D3DMetal was measured to fault. The answer was `dxmt`, which was
in the runtime the whole time.

What was measured, on the CX 11.0 runtime at `src/wine-cx/runtime/wine`:

- **D3DMetal, game:** clears the protection — zero trap-flag stops, no `-6` exit — then dies at
  about 2:52 with `c0000005`, a wild-pointer read at `NFS16.exe` RVA `0x341FB95`, immediately
  after the runtime logs `[D3DMetal] Unsupported: D3D11 timestamp query`. Frostbite uses GPU
  timestamp queries.
- **dxmt, game:** no fault at that address, 3.4 MB of compiled Metal shaders, `lsof` confirms
  `lib/wine/dxgi/dxmt/x86_64-windows/d3d11.dll` is the mapped library, full screen at 2560×1600
  matching the game's own options file, title and controller-layout screens reached.
- **D3DMetal, client:** worked, but logged 4–10 `Could not get offscreen texture shared handle`
  errors per session, and those dropped the EA session and killed the game.
- **dxmt, client:** full Home interface in 30 s — sidebar, store banner, artwork, avatar, the
  game under Installed, signed in — with **zero** such errors.

The mechanism of the D3DMetal fault remains **inferred**: that RVA was not disassembled and sits
inside the protected image. The choice between backends is not inferred.

Because the game's failure was measured rather than suspected, `gptk` is *denied* rather than
merely unselected. `GameKind.nfs2015.deniedRendererBackends` records it with the reason;
`RendererSelection.compatibilityDatabase` refuses it; `recipes.py` refuses to load a recipe
naming it; manifest validation refuses it on the player's machine. The denial is scoped two ways,
and both still matter even though nothing selects it now:

- **Per game.** `gptk` stays a legitimate choice for a title with no such measurement, and is
  still the right backend for others.
- **Per executable.** The denial applies to any rule that would serve the game's own executable,
  named or catch-all. A rule naming another program is judged on its own evidence — which is how
  the client's rule was free to differ before it was measured onto dxmt. A catch-all is refused
  for this recipe, so no later edit can quietly route the game back onto a faulting backend.

Retention follows the backends, and now needs only one path, `lib/wine/dxgi/dxmt`. dxmt carries
its own `winemetal.so` and links no Apple framework.

**The Apple licensing question is closed, by measurement rather than by a licence judgement.**
Nothing selects `gptk`, so `D3DMetal.framework` and `libd3dshared.dylib` are no longer retained
and no Apple-signed artifact ships. The `vendorRuntimePaths` mechanism that made retaining one
safe stays in the packager, unused by any recipe, for whenever a vendor-signed artifact does have
to be kept — and the findings that motivated it still stand for any recipe that does so.

### Measuring the runtime instead of trusting it

Two renderer reversals were both caused by naming a backend the runtime did not contain, so the
gate no longer takes a profile's word for it. Before staging, `verify_runtime_provides` requires:

- every selected backend to exist as a real directory at `lib/wine/<api>/<backend>` in the
  runtime being staged, listing what the runtime actually offers when it does not; and
- a recipe needing the trap-flag gate to find `WINE_TF_EMULATION`, `WINE_TF_MAX_STEPS` and
  `WINE_TF_MAX_NS` in the built `lib/wine/x86_64-unix/ntdll.so`.

Both pass against the pinned runtime. The first check is what would have caught `dxvk`.

### Runtime capability gate

A runtime without execution-breakpoint delivery produces a silent relaunch loop rather than an
error, which is the worst possible failure. The recipe therefore declares
`requiredRuntimeCapabilities`, each runtime profile in `runtime-inputs.json` declares what it
`capabilities` provides, and `verify_inputs` refuses to assemble a mismatch. A profile marked
`pending` is refused outright with its `blockedBy` text.

The pinned runtime is `src/wine-cx/runtime/wine` — note the nested `wine` directory, which is
how this tree installs. It reports `wine-11.0`, and five artifacts are pinned by digest:
`bin/wine`, `bin/wineserver`, `lib/wine/x86_64-unix/{ntdll.so,wine}` and
`lib/wine/i386-windows/ntdll.dll`. Three of those digests were reported independently by the
startup worker and recomputed here; they match.

**Recorded caveat:** this runtime's PE builtins were built with Homebrew mingw-w64 GCC 16.1.0
rather than llvm-mingw clang. That is a known parity gap with CI which was deliberately not
rebuilt for, and it is carried in the profile's `toolchainNote` so the bundle's provenance states
it rather than implying a CI-matching build.

## Settings

The installed game writes `Documents/Need For Speed/settings/PROFILEOPTIONS_profile` below the
Windows user profile: 376 lines of plain ASCII `Key Value`, LF-terminated, with no header.
`ProfileOptionsDocument` replaces only the values asked for, on lines that already carry those
keys, and refuses to invent a key the game has not written. `PROFILEOPTIONS` beside it is a
packed `FBCHUNKS` blob of gameplay options and is never touched.

The catalog holds `GstRender.*` display and quality keys and `GstInput.DeadZonePad*` keys read
back from the installed game. `GstRender.AmbientOcclusion` and `GstRender.AntiAliasingPost` are
deliberately excluded: the game wrote one value for each and their domains are not established,
so they stay under the game's own Video menu. The four-step detail domain (`0`–`3`) is inferred
from that menu, not measured.

The game's file is the **only** record of these settings. The app keeps no copy of its own, so
a change the player makes in the game's own Video menu is what the starter shows, and the
starter can never overwrite a player's choice with a stale cache. `--configure` writes the
requested values into the game's file and then reads that file back, so the snapshot reports
what the game now holds rather than what was asked for. Before the game has written its file
there is nothing to change, and the app says so instead of inventing one.

A real Windows profile usually links `Documents` at the player's own folder, so that link is
followed on purpose. This is the one file the app changes outside its own folder:
`PlayerFileEdit` journals the previous bytes inside the app's folder and writes in place, so a
linked folder keeps its file, and an interrupted edit is replayed before anything reads it.

### What does not apply

- **mtld3d renderer options.** Direct3D 9 only; see above. The `mtld3d.conf` panel the other
  two starters offer has no counterpart here, because no mtld3d is loaded.
- **Most Wanted's widescreen and simulation-rate patches.** Those patch a 2005 Direct3D 9
  executable. Nothing is patched here: the game executable is Denuvo-protected and is the
  player's own file.
- **Controller remapping through `XtendedInput`.** That is an ASI plugin loaded through
  Direct3D 9. This game reads XInput natively and writes its own `GstKeyBinding.*` lines.
  What does apply is one Wine bus setting: Wine marks only Xbox vendor products as gamepads,
  so a Sony pad reached through the host HID layer never binds to XInput. Setting `Hidraw` to
  `0` for a declared `VID/PID` keeps Wine's SDL-backed, Xbox-mapped device. Because that writes
  to a prefix the app does not own, it is a separate button the player presses, never part of a
  launch.
- **Save editing and career cheats.** Progress is in EA's cloud and in a Frostbite blob; this
  app does not edit either.
- **Prefix initialization.** `wineboot --init` and `Defaults/settings.reg` belong to a prefix
  the app owns. This recipe declares no defaults and initializes nothing.

## Build

```sh
python3 Packaging/build.py --game nfs2015 --game-data import \
  --output "/Users/gc/Games/nfs2015-bundled/out/Need for Speed Import.app" --no-archive
python3 Packaging/build.py --game nfs2015 --game-data bundled \
  --output "/Users/gc/Games/nfs2015-bundled/out/Need for Speed Bundled.app" --no-archive
```

`--game-data bundled` packages the user's own verified installation (the recipe's `game` input,
pinned file by file) for a prefix the app creates itself; see
[NFS2015.md §13](NFS2015.md#13-the-bundled-edition). It is refused before anything is staged unless
every pinned file matches and the whole payload inventory equals `inventorySHA256`. `--no-archive`
is the supported way to build: the packager would otherwise write a `.zip` and a `.sha256`, and the
audit refuses either inside the app.

## What is verified and what is not

Verified: the game reaches its title and controller-layout screens on `dxmt`, at 2560×1600 full
screen matching its own options file, with no fault and no trap-flag stops; the mapped
`d3d11.dll` comes from the `dxmt` tree; and the runtime carries the trap-flag switches and both
selected backends. Also verified on this machine: the `170` exit and `ActivationUI`/`EALauncher` spawn without EA
running; the `--in-process-gpu` requirement and that the stub does not forward it; the
`IGOProxy32` fault; the offer identifier; the absence of the client junction in this prefix;
the Windows user profile being named `crossover`; the options file's format and key set; and
that the game wrote display settings at 2560×1600.

Not verified: that a complete session reaches gameplay. The runtime that delivers execution
breakpoints is not built yet, and no game or EA app was run while writing this recipe. The
mechanism of the D3DMetal fault is inferred rather than proven, and the readiness child count and
the detail-level domain are reasoned from local evidence rather than measured. Gameplay beyond
the controller-layout screen is unverified, as is the EA client's behaviour on any backend other
than D3DMetal. Treat a successful build as a successful build and nothing
more.
