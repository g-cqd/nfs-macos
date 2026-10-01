# Need for Speed (2015) recipe

This app does not contain the game, and it does not replace any part of EA's software. It
supplies a Wine runtime, a starter and a session helper, and it runs the player's own
installation where that installation already is.

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
| `WINE_COMPATDB` | `dxgi=gptk` | Inferred from the runtime's `lib/wine/dxgi/{gptk,dxmt,wined3d}` layout and the existing `dxgi=wined3d` rule |
| `WINE_TF_EMULATION` | `1` | Required; recipe configuration |
| `WINE_TF_MAX_STEPS` | `0` | Required; recipe configuration |
| `WINE_TF_MAX_NS` | `0` | Required; recipe configuration |

### Direct3D: this title does not use mtld3d

`NFS16.exe` is a 64-bit Direct3D 11 binary. mtld3d implements Direct3D 9 and 8, so it plays
no part in this game's renderer. The shared packager previously deleted the entire D3D11 path
from every bundle to save space:

```text
lib/wine/dxgi/gptk  lib/wine/dxgi/dxmt
lib/external/D3DMetal.framework  lib/external/libd3dshared.dylib
```

Deleting those for this game would leave it with no renderer. `runtimeRetention` in the recipe
now names what a title keeps, and the Need for Speed recipe keeps the D3DMetal DXGI stack and
its licence file while still dropping `dxmt`. The recipe declares no `renderer`,
`rendererEvidence` or `mtld3dSource` input at all, so the packager neither verifies nor stages
mtld3d for it, and the bundle carries no mtld3d source archive.

**Open licensing question, not resolved here:** retaining `D3DMetal.framework` means the app
would redistribute an Apple-signed framework under Apple's own licence. `BUNDLING.md` already
notes that "Apple runtime licenses/signatures require separate handling in the EA track".
Settle that before distributing a build of this recipe to anyone else; a local build for the
machine's own owner is a different question from redistribution.

### Runtime capability gate

A runtime without execution-breakpoint delivery produces a silent relaunch loop rather than an
error, which is the worst possible failure. The recipe therefore declares
`requiredRuntimeCapabilities`, each runtime profile in `runtime-inputs.json` declares what it
`capabilities` provides, and `verify_inputs` refuses to assemble a mismatch. A profile marked
`pending` is refused outright with its `blockedBy` text.

**This is the current blocker.** `nfs2015-tf-cx11` is `pending`: the CX 11.0 runtime carrying
the `WINE_TF_*` gate is still being built at `~/Games/NFS2015-debug/src/wine-cx`, and
`src/wine-cx/runtime` does not exist yet. To finish a build, pin that runtime's
`bin/wine`, `bin/wineserver`, `lib/wine/x86_64-unix/{ntdll.so,wine}` and
`lib/wine/i386-windows/ntdll.dll` under that profile and remove `pending`.

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

A real Windows profile usually links `Documents` at the player's own folder, so that link is
followed on purpose. This is the one file the app changes outside its own folder:
`PlayerFileEdit` journals the previous bytes inside the app's folder and writes in place, so a
linked folder keeps its file, and an interrupted edit is replayed before anything reads it.

### What does not apply

- **mtld3d renderer options.** Direct3D 9 only; see above.
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
  --output "/Users/gc/Desktop/Game Builds/Need for Speed Import.app" --no-archive
```

`--game-data bundled` is refused before anything is staged, because the recipe's `editions`
list is `["import"]` and a bundled edition would need pinned executable hashes a referencing
recipe cannot have.

## What is verified and what is not

Verified on this machine: the `170` exit and `ActivationUI`/`EALauncher` spawn without EA
running; the `--in-process-gpu` requirement and that the stub does not forward it; the
`IGOProxy32` fault; the offer identifier; the absence of the client junction in this prefix;
the Windows user profile being named `crossover`; the options file's format and key set; and
that the game wrote display settings at 2560×1600.

Not verified: that a complete session reaches gameplay. The runtime that delivers execution
breakpoints is not built yet, and no game or EA app was run while writing this recipe. The
`dxgi=gptk` selection, the readiness child count, and the detail-level domain are reasoned
from local evidence, not measured. Treat a successful build as a successful build and nothing
more.
