# Call of Duty 4 bundle

The CoD4 recipe packages the local PC single-player and multiplayer installation with
the tested production mtld3d renderer, cooperative x87sidecar and its own Wine runtime.
The app uses `CoD4Launcher`, `CoD4Session` and the separate `CoD4Mac` support directory.
Its first-run prefix is new; the existing CoD4 prefix and Gigi progress are not bundled.

```sh
python3 Packaging/build.py --game cod4 --game-data bundled --output "Build/CoD4 Bundled.app"
python3 Packaging/build.py --game cod4 --game-data import --output "Build/CoD4 Import.app"
```

Python3.11 or newer is required. Use `--no-archive` to avoid allocating a ZIP and
`--input NAME=PATH` to relocate declared inputs. The shared pipeline and recipe extension
instructions are in [Bundling](BUNDLING.md). A source checkout alone does not contain
the external game, Wine, renderer, dependency-source and retained-license inputs.

## Payload and player data

The original payload includes `iw3sp.exe`, `iw3mp.exe`, `binkw32.dll`, `mss32.dll`,
`localization.txt`, `main` archives/videos, `zone` fastfiles and `miles` audio plug-ins.
The supplied executable reports CoD4 1.0 build 525. Both executable hashes are pinned;
packaging does not alter them. Original files remain unchanged in their installation.

The manifest records each path, size and SHA-256, `gameID=cod4`, `gameDataIncluded`,
`supportsSP`, `supportsMP` and the compatibility-file list. Import builds retain this
inventory and `mtld3d.conf` but omit original bytes. SP/MP support flags mean their
assets and launch entries are included; they do not assert multiplayer authentication,
server availability or a successful multiplayer session.

Player profiles, campaign saves, product keys, logs, shader caches and mod development
tools are excluded. `Resources/Defaults` contains clean `config.cfg`, `config_mp.cfg`,
`mtld3d.conf` and `settings.reg`. The two engine configs share one source template,
while profile creation supplies standard keyboard/mouse bindings. No initial resolution is fixed in that
template: the launcher supplies the selected display resolution. `Game/players` points
to the app's persistent `Data/Saves` players tree after preparation.

During play, a temporary `G:` drive maps only the private game directory. Wine cannot
reverse-map the native working directory through `C:\CoD4` alone; without this drive
it starts in `C:\windows` and fails to find `fileSysCheck.cfg` inside `main/iw_00.iwd`.
The helper removes `G:` after stopping Wine. The next setup also removes a mapping
left by an interrupted session. No host home or filesystem-root drive is exposed.

The fresh prefix enables Wine Retina mode and Windows 10. The existing working prefix
has no native DLL override or Activision install registration to reproduce.
`d3dx9_34.dll` comes from the bundled Wine builtin; its bytes match the working prefix.
The original Miles/Bink libraries are part of the selected game payload. No additional
VC/DirectX installer or existing user registry is copied.

## Rendering and retained evidence

Native maximum quality uses `render.scale=1`, synchronous shader compilation, 4× MSAA,
supersampled alpha AA, 16× anisotropy, Extra textures and the installed maximum
shadow/effect/model settings. The clean template disables vsync and the frame cap,
matching the retained maximum-quality setup. Users can select a cap in the launcher.
First-use synchronous pipeline compilation may pause.

Reduced `render.scale` uses MetalFX **spatial** upscaling when supported. Values above 1
are rejected; native scale does not invoke upscaling. No temporal upscaling or frame
generation is claimed. Normal launch disables the Metal HUD, renderer performance
logging and inherited instrumentation options.

The exact retained production renderer passed 923 tests with 0 failures and 11 ignored
benchmark cases. Earlier windowed training-checkpoint observations recorded median
146.1 FPS with x87sidecar and 79.2 FPS without it, with background interference. Those
observations are not a controlled campaign speedup. Native 2560×1600 rendering was
inspected windowed; the prior worker did not relaunch the final fullscreen settings
after the user stopped repetitions. The new app requires its own relocated first-run
verification; no new game-run result is implied by packaging.

The retained demo fixture crashes with x87 both enabled and disabled and was excluded
from timings. It is not part of this bundle's payload. Source pins and artifact
provenance are documented in [Upstreams](UPSTREAMS.md).
