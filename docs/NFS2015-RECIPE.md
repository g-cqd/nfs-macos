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
| `WINE_COMPATDB` | `dxgi=dxvk`, per executable | Chosen after D3DMetal was measured to fault; see below |
| `WINE_TF_EMULATION` | `1` | Required; recipe configuration |
| `WINE_TF_MAX_STEPS` | `0` | Required; recipe configuration |
| `WINE_TF_MAX_NS` | `0` | Required; recipe configuration |

### Direct3D: DXVK, not mtld3d and not D3DMetal

`NFS16.exe` is a 64-bit Direct3D 11 binary. mtld3d implements Direct3D 9 and 8, so it plays no
part in this game's renderer: the recipe declares no `renderer`, `rendererEvidence` or
`mtld3dSource` input, the packager neither verifies nor stages mtld3d for it, and the bundle
carries no mtld3d source archive.

The DXGI backend is **DXVK**, selected per executable:

```json
{"api": "dxgi", "backend": "dxvk", "executable": "NFS16.exe"}
{"api": "dxgi", "backend": "dxvk"}
```

**This reverses an earlier decision in this document.** D3DMetal was chosen first, on the
reasoning that the runtime selects D3DMetal for 64-bit DXGI and that DXVK had been reported as
fragile. A measured crash overruled it, reported by the startup worker:

- On the patched CX 11.0 runtime with D3DMetal the game clears Denuvo — zero TF emulation stops,
  no `-6` exit — and then dies at about 2:52 with `c0000005`, a wild-pointer read at `NFS16.exe`
  RVA `0x341FB95`, immediately after the runtime logs `[D3DMetal] Unsupported: D3D11 timestamp
  query`. Frostbite uses GPU timestamp queries.
- The control: the same game and the same TF settings on Wine 11.18 with DXVK reached the full
  main menu and rendered correctly.

**Strong inference, not proof.** That RVA has not been disassembled and sits inside the
protected image, so the link from the unsupported query to the fault is circumstantial, however
closely the two coincide. What is settled is the choice: a backend that reaches a menu beats one
that faults, so DXVK it is.

Because this is a measured failure rather than a performance difference,
`GameKind.nfs2015.deniedRendererBackends` records `gptk` with its reason, and
`RendererSelection.compatibilityDatabase` refuses to build an environment that selects it. The
same contradiction is refused statically in `recipes.py`, so a recipe naming it cannot even be
loaded, and a manifest naming it fails validation on the player's machine. The denial is per
game: `gptk` remains a legitimate choice for a title with no such measurement.

Selecting per executable means one runtime can serve the EA client and the game, which is
preferable to shipping a second runtime. Both rules currently name `dxvk`; if the client turns
out to need a different backend, only the first rule changes.

Retention follows the backend. The packager prunes a fixed list of runtime paths, and
`runtimeRetention` names what a title keeps; this recipe keeps DXVK's libraries and the Vulkan
loader:

```text
lib/wine/dxgi/dxvk  lib/wine/x86_64-windows/dxvk
lib/external/libMoltenVK.dylib  lib/external/libvulkan.1.dylib  lib/external/vulkan
```

Those names are **unconfirmed**: `src/wine-cx/runtime-dxvk` does not exist yet, so the layout
has not been inspected. What has been inspected is the D3DMetal build beside it, which finished
at `src/wine-cx/runtime/wine` — note the nested `wine` directory, so a recipe's `runtime` input
needs that suffix. It reports `wine-11.0`, its `lib/wine/x86_64-unix/ntdll.so` does contain the
`WINE_TF_EMULATION`, `WINE_TF_MAX_STEPS` and `WINE_TF_MAX_NS` strings, and it offers
`lib/wine/dxgi/{dxmt,gptk,wined3d}` with **no `dxvk`**. That confirms both that the trap-flag
gate is real in a built runtime and that a separate Vulkan-preserving build is genuinely
required rather than a configuration change.

It also means a third backend is sitting unused: `dxmt` is a Metal-backed Direct3D 11
implementation already present in that runtime. It was tried once and produced no window, but
that was before the trap-flag work let the game clear Denuvo at all, so the result says nothing
about the renderer. Measuring it would cost one run and no new runtime, and if it implements
timestamp queries it would remove the need for DXVK and MoltenVK entirely. That is a question
for whoever owns the runtime, not a change made here. Retaining a path that does not exist is a no-op, and the pruning list
does not currently name any DXVK path, so a wrong name here cannot delete the wrong thing — but
check them against the runtime before trusting the first build.

One consequence is welcome: the recipe no longer retains `D3DMetal.framework`, so the question
of redistributing an Apple-signed framework under Apple's licence **no longer arises for this
recipe**. The `vendorRuntimePaths` mechanism that made retaining it safe stays in the packager,
unused by any recipe, for whenever a vendor-signed artifact does have to be kept.

### Runtime capability gate

A runtime without execution-breakpoint delivery produces a silent relaunch loop rather than an
error, which is the worst possible failure. The recipe therefore declares
`requiredRuntimeCapabilities`, each runtime profile in `runtime-inputs.json` declares what it
`capabilities` provides, and `verify_inputs` refuses to assemble a mismatch. A profile marked
`pending` is refused outright with its `blockedBy` text.

**This is the current blocker.** `nfs2015-tf-cx11` is `pending`: the Vulkan-preserving CX 11.0
runtime carrying the `WINE_TF_*` gate is still being built, and
`src/wine-cx/runtime-dxvk` does not exist yet. To finish a build, pin that runtime's
`bin/wine`, `bin/wineserver`, `lib/wine/x86_64-unix/{ntdll.so,wine}` and
`lib/wine/i386-windows/ntdll.dll` under that profile and remove `pending`.

## Prefix settings the game needs

Some values this game depends on are Wine's, not the game's, so the game's own file cannot
hold them. A bundle that owns its prefix imports them once through `Defaults/settings.reg`
during `wineboot`; this recipe owns no prefix and never runs `wineboot`. It therefore declares
`prefixSettings`, and the session checks each one against the prefix's own `user.reg` or
`system.reg` and imports only what is missing — a prepared prefix starts no Wine process and is
left completely untouched.

| Value | Why |
|---|---|
| `HKCU\Software\Wine\Mac Driver` `RetinaMode="Y"` | Without it the Mac driver advertises the scaled logical desktop instead of the native panel, so the full-screen mode the game asks for does not exist and Wine substitutes the nearest one |

**Strong but unverified**, reported by the startup worker: on a 2560×1600 Retina display the
game's own options were already correct (`FullscreenEnabled 1`, `2560×1600`, `60`) yet the
window came up wrong until windowed mode was toggled to force a re-query, and this key was
absent from the prefix. The diagnosis matches the key's documented effect and the absent key was
confirmed in this tree's prefix, where `Mac Driver` holds only `AllowSetGamma`. It is not yet
confirmed that setting it makes the window correct on the first launch.

Note that the existing bundles disagree about this value, so it is not a blanket default:
`Packaging/CoD4Defaults/settings.reg` sets `"Y"`, while `Packaging/settings.reg` for Most Wanted
sets `"N"`. Wine accepts `y`, `Y`, `t`, `T` or `1` as true. Making it per-recipe configuration
rather than a shared default is deliberate.

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
DXVK-over-D3DMetal choice rests on a measured crash whose exact mechanism is inferred, and the
readiness child count and the detail-level domain are reasoned from local evidence rather than
measured. Treat a successful build as a successful build and nothing
more.
