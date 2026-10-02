# MetalFX temporal upscaling and frame interpolation

Verified 2026-09-27. This is a feasibility report; the delivered apps still use the existing spatial path. Temporal upscaling and frame interpolation are outside this release, as agreed with the user.

## Actual hardware result

A disposable native arm64 Swift probe queried `supportsDevice` on the system default Metal device. Compilation targeted macOS 15; frame interpolation was guarded with `if #available(macOS 26.0, *)`. Compilation and execution both exited 0, with no compiler warnings.

```json
{
  "device": "Apple M1",
  "os": "Version 27.0 (Build 26A5388g)",
  "spatial": true,
  "temporal": true,
  "frameInterpolation": true
}
```

The calls were `MTLFXSpatialScalerDescriptor.supportsDevice(device)`, `MTLFXTemporalScalerDescriptor.supportsDevice(device)`, and `MTLFXFrameInterpolatorDescriptor.supportsDevice(device)`. This proves that this OS/device reports support. It does not prove a specific descriptor, format combination, rendered output, image quality, frame rate, or latency. No game ran, and no renderer or dependency changed. The probe executable was removed; source and result remain in `~/Library/Caches/metalfx-feasibility-nth5leel`.

Apple's documentation makes the ordinary `MTLFXTemporalScaler` API available on macOS 13+, and `MTLFXFrameInterpolator` on macOS 26+. These APIs accept ordinary Metal command buffers; adopting the separate `MTL4FX…` protocols is not a prerequisite. The app's macOS 15 floor can remain: temporal support requires a device check, while frame interpolation requires both the OS gate and a device check. [Temporal support](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/supportsdevice(_:)), [frame interpolation support](https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatordescriptor/supportsdevice(_:)).

## What the renderer has today

Inspected `~/Developer/mtld3d` at commit `5f5331a2d8762356bd49d128271c1b186c31e7ec`.

| Source | Present behavior and extension point |
| --- | --- |
| `unix/Cargo.toml:85` | The MetalFX binding explicitly selects `MTLFXSpatialScaler`; no temporal or interpolation implementation was found in the inspected renderer sources. |
| `unix/unix/src/metal/upscale.rs:313` | Spatial encode binds a color texture and output texture. The module already provides per-device bounded scaler caches and deferred resource retirement. A temporal implementation needs separate history state and lifetime rules. |
| `unix/unix/src/metal/command.rs:807` | `PresentEncode` carries final color, device/attachment, sequence, and drawable timing. It carries no scene depth, motion vectors, projection jitter, or HUD layer. |
| `unix/unix/src/metal/command.rs:827` | `encode_present` selects copy, spatial upscale, or filtered stretch and applies SDR/HDR presentation. This is an output integration point, but too late to invent reliable scene information. |
| `unix/shared/src/params.rs:974` | `SubmitFrameParams` transports render passes plus a present layer/texture. Any additional temporal frame metadata must cross this PE/Unix boundary with matching layout changes. |
| `unix/unix/src/metal/presenter.rs:1` | Presentation has a per-queue thread, ordered packets, bounded snapshot slots, and explicit resource retirement. Generating extra frames requires changes to this scheduler and its timing/accounting, not just another scaler call. |
| `windows/d3d9/src/device.rs:9320` | Depth-stencil binding is visible, but the final scene depth must be identified and retained before the game clears or replaces it. |
| `windows/d3d9/src/device.rs:9797` and `:13173` | Fixed-function transforms and vertex-shader constants are intercepted. Shader constants do not identify their semantic role as camera, previous transform, or animated-object state. |

`render.scale` already reduces the matching render/depth targets and spatially enlarges the finished frame. It does not add motion vectors or jitter. See `mtld3d.conf:465` and `:485`.

## Inputs still needed

| Input | Why it matters | Current integration gap |
| --- | --- | --- |
| Scene color and consistent color/exposure convention | Temporal history must compare compatible frames. | Final color exists; the correct scene stage before HUD and some post-processing is not identified. Existing HDR presentation is not itself game exposure data. |
| Scene depth, with its depth convention | Supports reconstruction and disocclusion. | D3D9 depth resources exist; the scene buffer, resolve/format conversion, lifetime, and near/far interpretation need verification per game. |
| Current-to-previous motion vectors | Camera motion alone cannot describe cars, characters, skinning, particles, or independently moving objects. | No motion-vector surface or temporal metadata is supplied by the current presentation path. |
| Projection jitter and offsets | Temporal upscaling must know the subpixel offset actually used to render each frame. | No projection-jitter integration exists. Changing arbitrary shader constants would be unreliable. |
| History reset and frame timing | Resize, camera cuts, loading, menus, and discontinuities invalidate history. | Present sequence/timing exists; reliable scene discontinuities and history ownership need a defined contract. |
| HUD/UI treatment and optional reactive mask | HUD should remain legible; alpha-blended effects need appropriate history handling. | The current final color can already contain HUD. The renderer has no identified game HUD layer or reactive-mask input. |

Apple documents the temporal scaler's depth, motion, jitter, exposure and reset properties. Exposure can use the scaler's automatic mode; a separate game exposure texture is not always required. A reactive mask is an additional quality input, not a synonym for a HUD mask. [Temporal scaler inputs](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerbase), [exposure](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerbase/exposuretexture), [jitter](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerbase/jitteroffsetx).

Frame interpolation adds previous-color/history handling, motion, depth, timing and camera parameters. Apple defines motion vectors as pointing from a current pixel to its previous-frame location after applying the supplied scale. It also provides an **optional** `uiTexture` and `isUITextureComposited` flag for UI composition. macOS 27's descriptor can manage previous color internally with `requiresPrevColorTexture = false`; this removes one explicit texture input, not the need for valid temporal scene data. [Frame interpolation inputs](https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatorbase), [motion convention](https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatorbase/motionvectorscalex), [optional UI texture](https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatorbase/uitexture).

Documentation came from apple-docs MCP, then the installed Xcode-beta macOS 27 SDK headers `MetalFX.framework/Headers/MTLFXTemporalScaler.h` and `MTLFXFrameInterpolator.h`. Some individual MCP property pages inherit misleading Metal-texture availability metadata; the enclosing API declarations, SDK headers, and guarded compilation determine the API floors stated above.

## Practical scope

**Generic renderer work is feasible:** capability reporting, guarded MetalFX factories, per-device history allocation, reset/fallback behavior, typed frame metadata, and presentation scheduling can be shared across games.

**Correct game inputs need integration:** Most Wanted and CoD4 cannot gain reliable temporal reconstruction merely by replacing the spatial scaler at `Present`. A game-specific adapter must identify scene color/depth, supply or reconstruct verified camera/object motion, apply known jitter, and separate UI or otherwise validate its treatment. Camera-only reprojection and guessed depth targets would be experimental fallbacks, not equivalent inputs for moving geometry.

Start with temporal upscaling for one verified game scene, keep the current spatial/native path as fallback, and validate motion, disocclusion, transparency, HUD, resize and camera cuts. Then add frame interpolation with separately measured generated-frame cadence and input latency. Generated frames do not advance the game's simulation or input sampling. No FPS multiplier, latency improvement, delivery date, or maximum-quality claim is established by this capability probe.
