import Foundation

/// Options backed by public evidence of Far Cry 2's `GamerProfile.xml` and by mtld3d's configuration.
///
/// Detail levels (textures, shadows, environment, HDR and the like) are deliberately absent: reports
/// show the attributes exist but not their value ranges. The starter leaves them as the game wrote
/// them; the player chooses them in the game's own Video options.
package enum FarCry2Catalog {
  package static let graphicsGroups = ["Display", "Image quality", "Renderer"]
  private static let toggle: FarCry2Setting.Kind = .choices([.init("0", "Off"), .init("1", "On")])
  private static let render = ["RenderProfile"]
  private static let customQuality = ["CustomQuality", "quality"]

  /// The renderer the game must use; written to the profile on every launch.
  package static let requiredPlatform = "d3d9"
  package static let platform = GamerProfileDocument.Target(render, "Platform")
  package static let quality = GamerProfileDocument.Target(render, "Quality")
  /// Direct3D 10 profiles carry a `d3d10` suffix on the quality id (for example `customd3d10`).
  package static let direct3D10Suffix = "d3d10"

  package static let settings: [FarCry2Setting] = [
    .init(
      "resolution", "Resolution", "Display", "2560x1600", .resolution,
      storage: .profile([
        .init(render, "ResolutionX"), .init(render, "ResolutionY"),
        .init(customQuality, "ResolutionX"), .init(customQuality, "ResolutionY"),
      ]),
      help:
        "Written to the render profile and every custom quality entry. The game must offer this display mode."
    ),
    .init("fullscreen", "Fullscreen", "Display", "1", toggle, storage: single("Fullscreen")),
    .init("vsync", "Vertical sync", "Display", "0", toggle, storage: single("VSync")),
    .init(
      "refreshRate", "Refresh rate", "Display", "0",
      .choices([.init("0", "Display default"), .init("60", "60 Hz"), .init("120", "120 Hz")]),
      storage: single("RefreshRate")),
    .init("showFPS", "Show frame rate", "Display", "0", toggle, storage: single("ShowFPS")),
    .init(
      "antialiasing", "Anti-aliasing", "Image quality", "4",
      .choices([.init("0", "Off"), .init("2", "2× MSAA"), .init("4", "4× MSAA")]),
      storage: single("MultiSampleMode")),
    .init(
      "alphaToCoverage", "Alpha to coverage", "Image quality", "1", toggle,
      storage: single("AlphaToCoverage"),
      help: "Smooths foliage edges with multisampling. Needs anti-aliasing on."),
    .init(
      "skipTopMip", "Skip highest texture detail", "Image quality", "0", toggle,
      storage: single("DisableMip0Loading"),
      help: "Off keeps the game's highest texture level; on trades detail for memory."),
    .init(
      "asyncShaders", "Game shader loading in background", "Image quality", "1", toggle,
      storage: single("AllowAsynchShaderLoading"),
      help: "The game's own loader. The renderer's pipeline compilation is set separately below."),
    .init(
      "render.scale", "Rendering scale", "Renderer", "1",
      .choices([.init("0.5", "0.5"), .init("0.67", "0.67"), .init("0.75", "0.75"), .init("1", "1")]
      ),
      storage: .renderer,
      help: "1 renders at the full selected resolution. Lower scales use MetalFX spatial upscaling."
    ),
    .init(
      "shader.asyncCompile", "Compile shaders asynchronously", "Renderer", "false",
      .choices([.init("false", "Off"), .init("true", "On")]), storage: .renderer,
      help: "Off preserves every draw while a pipeline is compiled and may pause on first use."),
    .init(
      "present.maxFps", "Frame limit", "Renderer", "0",
      .choices([
        .init("0", "No limit"), .init("30", "30"), .init("60", "60"), .init("120", "120"),
      ]), storage: .renderer,
      help: "Public reports mention a cutscene problem at high frame rates; 30 or 60 is a fallback."
    ),
  ]

  package static func setting(_ id: String) -> FarCry2Setting? {
    settings.first { $0.id == id }
  }

  private static func single(_ attribute: String) -> FarCry2Setting.Storage {
    .profile([.init(render, attribute)])
  }
}
