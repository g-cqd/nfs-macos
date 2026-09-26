# Most Wanted tuning record

All observations below were collected on 2026-09-26. Configuration values are recorded separately from measured results.

## Renderer and x87

- The original mtld3d 0.7.0 path produced pink cars. Updating to the 0.11 series corrected car colors in the tested scenes.
- The vertex layout bug widened a nonzero stream stride from 12 to 44 bytes when an attribute extended past the stride. Metal accepts the overlap; widening changes vertex addresses. The fix preserves the stride and increases the staged GPU read span for the last vertex. It keeps CPU user-pointer reads within their original bounds. A pixel regression failed before the complete fix and passed afterward.
- The CPU frame-cap correction changed a controlled main-menu observation from about 60 to 120 FPS. Early free-roam windows showed roughly 65–72 FPS. This does not establish sustained 120 FPS racing.
- The x87 sidecar caches empty tags and provides guarded exact f80 conversion paths for normal values and signed zero. Special values retain the original handling. Boundary microbenchmarks improved 20–28% for normal/zero/mixed values; special-value input cost 9.6% more. A preliminary same-scene observation was 54.07 versus 55.77 FPS; repeatable racing evidence remains incomplete.
- A separate guarded SSE2 geometry routine reduced a routine-only benchmark from median 44.6280 to 2.6466 ms per 100,000 calls. The first game comparison was 48.721 versus 47.338 FPS and did not show a benefit. That candidate is not the production game executable.
- Native D3DX effect-call comparison fixtures pass for builtin and native implementations. No game-speed benefit was established, and native D3DX was not installed as an optimization.

## Maximum quality and MetalFX

The maximum preset detects the display's maximum supported pixel resolution, uses native rendering scale 1, applies the highest supported game settings, enables 4x MSAA (game index 2), and uses 8192 shadow maps. It preserves the chosen FPS cap and controller settings. The tested display mode was 2560×1600.

mtld3d integrates MetalFX spatial upscaling when the presentation resolution exceeds the rendered resolution. Native scale 1 does not upscale. Temporal scaling, frame interpolation, temporal denoising, and ray tracing are not integrated into this game path. Hardware/API capability queries alone do not establish a working temporal integration. Motion vectors, depth, history, UI treatment, and frame pacing would require further renderer work.

The maximum light-streak option originally caused a startup crash at 0x76ba6511 in WidescreenFix. Its rendering patch removes a store that a later resolution pattern expects, leaving an empty match. `Packaging/widescreen_compat.py` replaces the string with a unique prefix unaffected by that edit. The patch checks the exact original/updated plugin SHA-256, preserves PE layout, and rejects unknown builds. Offline before/after regressions pass; the user verified the maximum-quality menu and car after the patch.

The Metal HUD and profiling counters stay off in ordinary launches. A configured 120 FPS cap is a limit, not a promise of 120 FPS.

## Controllers and cursor

- Raw DualShock DirectInput reported zero Rx/Ry, which the old mapping interpreted as full camera deflection. WineBus `DisableHidraw=1` produced a mapped XInput pad and centered axes in this setup.
- XtendedInput owns gamepad mapping; overlapping WidescreenFix mapping is disabled. Keep its XtendedInput camera compatibility enabled.
- R2/RT maps to analog throttle and L2/LT to analog brake/reverse. XtendedInput normalizes trigger values by 255. Both the defaults and per-profile mapping files must agree; a stale profile map can override corrected defaults.
- Measured resting stick drift was 4.3% left and 2.7% right. The tested steering/stick deadzones are 12%; the camera deadzone is 10% normalized. WidescreenFix expresses the latter as 20.0 because its code divides by 200.
- The user confirmed partial/full throttle and released-stick behavior. PlayStation and Xbox button presentation are selectable in the starter.
- XtendedInput's normal vibration entry points are empty. The separate rumble bridge and helper provide the tested output path. Wine returning success did not prove physical vibration; the user confirmed two distinct stronger pulses after the bridge correction.
- The macOS cursor could reappear on stationary focus changes while Win32 considered it hidden. The Wine cursor recovery patch refreshes the target and reapplies the cursor after activation. Test focus changes without moving the pointer; a controller or cursor diagnostic can itself change native focus.

## Profiles and unfinished garage work

Save edits validate the fixed-size PC 1.3 format, MD5 and EA CRCs, native car numbering, ownership slots, and capacities. These checks detect format corruption; they do not make arbitrary serialized car states valid in the game. Always back up the latest save after the user quits. Never reapply a money multiplier or car duplication from old instructions.

Fresh careers use a clean game-created template. Synthetic test saves must never enter the playable profile folder. A synthetic TestDriver profile previously caused a load failure; removing it preserved the real profile and restored menu entry.

The car catalog contains 101 signatures. Native `RideInfo_SetStockParts` capture produced 139 visual-part indices per signature. The generated Swift table matches that capture. However, a newly added Porsche Carrera GT still crashes at game PC 0x45d380 (read of address 0xC). The native visual table is necessary but is not a proven complete new-car initializer. Do not advertise arbitrary-car addition as verified until this fault is understood and a user-driven race passes.
