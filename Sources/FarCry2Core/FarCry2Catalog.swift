import Foundation

/// Every option the starter manages.
///
/// Profile attributes and their defaults come from the `GamerProfile.xml` Far Cry 2 itself wrote on its
/// first launch under the bundled Wine and mtld3d. Value domains come from strings in `Dunia.dll`
/// (the quality ids `low`, `medium`, `high`, `veryhigh`, `ultrahigh`, `optimal`, `custom`) and from the
/// game's own Video options screen. Renderer keys are the ones mtld3d documents. Wine keys are the values the
/// bundled `winemac.so` reads. Console names are strings found in `Dunia.dll`; see `FarCry2Console`.
package enum FarCry2Catalog {
  package static let graphicsGroups = ["Display", "Color", "Image quality", "Detail levels"]
  package static let macGroups = ["Display & MetalFX", "Keyboard", "Renderer"]
  package static let gameGroups = ["Gameplay", "Mouse", "Audio", "Launch options"]
  package static let cheatGroups = ["Player", "Weapons", "World"]

  private static let toggle: FarCry2Setting.Kind = .choices([.init("0", "Off"), .init("1", "On")])
  private static let boolean: FarCry2Setting.Kind = .choices([
    .init("true", "On"), .init("false", "Off"),
  ])
  private static let levels: FarCry2Setting.Kind = .choices([
    .init("low", "Low"), .init("medium", "Medium"), .init("high", "High"),
    .init("veryhigh", "Very High"),
  ])
  /// Fire, real tree and physics use capitalised ids; the game wrote `Low` and `High`, and the engine names `VeryHigh`.
  private static let engineLevels: FarCry2Setting.Kind = .choices([
    .init("Low", "Low"), .init("Medium", "Medium"), .init("High", "High"),
    .init("VeryHigh", "Very High"),
  ])
  private static let render = ["RenderProfile"]
  private static let customQuality = ["CustomQuality", "quality"]
  private static let game = ["GameProfile"]

  /// The renderer the game must use; written to the profile on every launch.
  package static let requiredPlatform = "d3d9"
  package static let platform = GamerProfileDocument.Target(render, "Platform")
  package static let quality = GamerProfileDocument.Target(render, "Quality")
  /// Direct3D 10 profiles carry a `d3d10` suffix on the quality id (for example `customd3d10`).
  package static let direct3D10Suffix = "d3d10"

  private static func single(_ attribute: String, in path: [String] = render)
    -> FarCry2Setting.Storage
  { .profile([.init(path, attribute)]) }

  private static func detail(_ id: String, _ title: String, _ attribute: String, help: String = "")
    -> FarCry2Setting
  {
    .init(
      id, title, "Detail levels", "high", levels,
      storage: .profile([.init(customQuality, attribute)]),
      help: help.isEmpty ? "Applies when Overall is Custom." : help)
  }

  package static let settings: [FarCry2Setting] =
    display + color + imageQuality + detailLevels
    + mac + keyboard + renderer + gameplay + mouse + audio + launchOptions + cheats

  private static let display: [FarCry2Setting] = [
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
    .init("maximized", "Maximized window", "Display", "0", toggle, storage: single("Maximized")),
    .init("vsync", "Vertical sync", "Display", "0", toggle, storage: single("VSync")),
    .init(
      "refreshRate", "Refresh rate", "Display", "0",
      .choices(
        [.init("0", "Display default")]
          + [30, 50, 60, 75, 90, 100, 120, 144, 165, 240].map { .init("\($0)", "\($0) Hz") }),
      storage: single("RefreshRate")),
    .init("showFPS", "Show frame rate", "Display", "0", toggle, storage: single("ShowFPS")),
    .init(
      "forceWidescreen", "Widescreen", "Display", "0", toggle, storage: single("ForceWidescreen"),
      help: "The Widescreen box in the game's Video options."),
    .init(
      "widescreenFOV", "Widescreen field of view", "Display", "0", toggle,
      storage: single("WidescreenFOV"),
      help: "A profile attribute the game writes; its effect has not been verified."),
    .init(
      "driverBuffer", "Frames buffered by the driver", "Display", "0", .integer(0...4),
      storage: single("MaxDriverBufferedFrames"),
      help: "0 lets the game decide. Higher values add latency."),
  ]

  private static let color: [FarCry2Setting] = [
    .init(
      "brightness", "Brightness", "Color", "1", .decimal(0.5...1.5),
      storage: single("Brightness"), help: "The starter offers 0.5–1.5."),
    .init(
      "contrast", "Contrast", "Color", "1", .decimal(0.5...1.5), storage: single("Contrast")),
    .init(
      "gamma", "Gamma", "Color", "1", .decimal(0.5...1.5),
      storage: .profile(
        ["GammaRamp", "GammaRampR", "GammaRampG", "GammaRampB"].map { .init(render, $0) }),
      help: "Written to the gamma ramp and its red, green and blue channels together."),
  ]

  private static let imageQuality: [FarCry2Setting] = [
    .init(
      "antialiasing", "Anti-aliasing", "Image quality", "4",
      .choices([.init("0", "Off"), .init("2", "2× MSAA"), .init("4", "4× MSAA")]),
      storage: single("MultiSampleMode")),
    .init(
      "alphaToCoverage", "Alpha to coverage", "Image quality", "0", toggle,
      storage: single("AlphaToCoverage"),
      help:
        "Keep this off when anti-aliasing is on: together they draw tree leaves as opaque cards under the current renderer. Use one or the other."
    ),
    .init(
      "skipTopMip", "Skip highest texture detail", "Image quality", "0", toggle,
      storage: single("DisableMip0Loading"),
      help: "Off keeps the game's highest texture level; on trades detail for memory."),
    .init(
      "asyncShaders", "Game shader loading in background", "Image quality", "1", toggle,
      storage: single("AllowAsynchShaderLoading"),
      help: "The game's own loader. The renderer's pipeline compilation is set under Mac."),
    .init(
      "hdr", "HDR rendering", "Image quality", "1", toggle,
      storage: .profile([.init(customQuality, "Hdr")]), help: "Applies when Overall is Custom."),
    .init(
      "hdrFP32", "Full-precision HDR", "Image quality", "0", toggle,
      storage: .profile([.init(customQuality, "HdrFP32")]),
      help: "Applies when Overall is Custom."),
    .init(
      "bloom", "Bloom", "Image quality", "1", toggle,
      storage: .profile([.init(customQuality, "Bloom")]), help: "Applies when Overall is Custom."),
  ]

  private static let detailLevels: [FarCry2Setting] = [
    .init(
      "quality", "Overall", "Detail levels", "optimal",
      .choices([
        .init("optimal", "Optimal"), .init("low", "Low"), .init("medium", "Medium"),
        .init("high", "High"), .init("veryhigh", "Very High"), .init("ultrahigh", "Ultra High"),
        .init("custom", "Custom"),
      ]), storage: .profile([quality]),
      help:
        "A preset, or Custom to use the individual levels below. The game's Video options show the same list."
    ),
    .init(
      "realTree", "Real tree", "Detail levels", "Low", engineLevels,
      storage: single("Quality", in: ["RealTreeProfile"])),
    .init(
      "fire", "Fire", "Detail levels", "Low", engineLevels,
      storage: single("QualitySetting", in: ["GameProfile", "FireConfig"])),
    .init(
      "physic", "Physics", "Detail levels", "Low", engineLevels,
      storage: single("QualitySetting", in: ["EngineProfile", "PhysicConfig"])),
    detail("vegetation", "Vegetation", "VegetationQuality"),
    detail(
      "shading", "Shading", "EnvironmentQuality",
      help: "The profile calls this environment quality. Applies when Overall is Custom."),
    detail("terrain", "Terrain", "TerrainQuality"),
    detail("geometry", "Geometry", "GeometryQuality"),
    detail("postFx", "Post-processing", "PostFxQuality"),
    detail("textures", "Textures", "TextureQuality"),
    detail("textureResolution", "Texture resolution", "TextureResolutionQuality"),
    detail("shadow", "Shadows", "ShadowQuality"),
    detail("ambient", "Ambient", "AmbientQuality"),
    detail("water", "Water", "WaterQuality", help: "Not in the game's Video options."),
    detail("depthPass", "Depth pass", "DepthPassQuality", help: "Not in the game's Video options."),
    detail(
      "antiPortal", "Anti-portal culling", "AntiPortalQuality",
      help: "Not in the game's Video options."),
  ]

  private static let mac: [FarCry2Setting] = [
    .init(
      "retina", "Retina output", "Display & MetalFX", "1", toggle, storage: .registry("RetinaMode"),
      help:
        "Wine draws at the display's physical pixels. Takes effect the next time the game starts."
    ),
    .init(
      "render.scale", "MetalFX render scale", "Display & MetalFX", "1",
      .choices([
        .init("1", "100% — native"), .init("0.85", "85%"), .init("0.75", "75%"),
        .init("0.67", "67%"), .init("0.5", "50%"),
      ]), storage: .renderer,
      help:
        "Below 100% the game renders smaller and MetalFX spatial upscaling fills the output. This is not temporal upscaling or frame generation."
    ),
    .init(
      "render.lodBias", "Preserve texture detail when scaling", "Display & MetalFX", "true",
      boolean, storage: .renderer),
    .init(
      "present.maxFps", "Frame limit", "Display & MetalFX", "0",
      .choices(
        [.init("0", "No limit")]
          + [30, 60, 90, 120, 144, 165, 240].map { .init("\($0)", "\($0)") }), storage: .renderer,
      help: "Public reports mention a cutscene problem at high frame rates; 30 or 60 is a fallback."
    ),
    .init(
      "color.hdr.enable", "HDR output", "Display & MetalFX", "true", boolean, storage: .renderer,
      help:
        "Uses the display's extended range when it has headroom. No effect on a standard display."
    ),
    .init(
      "color.space", "Color space", "Display & MetalFX", "passthrough",
      .choices([.init("passthrough", "Display native"), .init("accurate", "sRGB accurate")]),
      storage: .renderer,
      help: "sRGB accurate avoids over-saturated colors on wide-gamut displays."),
    .init(
      "cursor.scale", "Cursor size", "Display & MetalFX", "auto",
      .choices([
        .init("auto", "Automatic"), .init("1", "1×"), .init("2", "2×"), .init("3", "3×"),
      ]), storage: .renderer),
    .init(
      "cursor.software", "Software cursor", "Display & MetalFX", "auto",
      .choices([.init("auto", "Automatic"), .init("true", "Always"), .init("false", "Never")]),
      storage: .renderer),
    .init(
      "hud", "Metal performance overlay", "Display & MetalFX", "0", toggle, storage: .launcher,
      launch: .environment("MTL_HUD_ENABLED"),
      help: "Apple's Metal HUD, drawn over the game."),
  ]

  private static let keyboard: [FarCry2Setting] = [
    .init(
      "leftCommandCtrl", "Left Command acts as Control", "Keyboard", "0", toggle,
      storage: .registry("LeftCommandIsCtrl")),
    .init(
      "rightCommandCtrl", "Right Command acts as Control", "Keyboard", "0", toggle,
      storage: .registry("RightCommandIsCtrl")),
    .init(
      "leftOptionAlt", "Left Option acts as Alt", "Keyboard", "0", toggle,
      storage: .registry("LeftOptionIsAlt")),
    .init(
      "rightOptionAlt", "Right Option acts as Alt", "Keyboard", "0", toggle,
      storage: .registry("RightOptionIsAlt")),
  ]

  private static let renderer: [FarCry2Setting] = [
    .init(
      "shader.asyncCompile", "Compile shaders asynchronously", "Renderer", "false", boolean,
      storage: .renderer,
      help: "Off preserves every draw while a pipeline is compiled and may pause on first use."),
    .init(
      "shaderCache.enable", "Persistent shader cache", "Renderer", "true", boolean,
      storage: .renderer,
      help: "Reuses compiled shaders between launches. Off compiles everything again each time."),
    .init(
      "memory.vramBudgetMB", "Video memory budget (MB)", "Renderer", "1024", .integer(0...4096),
      storage: .renderer,
      help:
        "0 removes the ceiling. Far Cry 2 is a 32-bit game; large values can exhaust its address space."
    ),
    .init(
      "memory.vbibRetentionCapMB", "Vertex and index retention (MB)", "Renderer", "512",
      .integer(0...2048), storage: .renderer, help: "0 disables retention."),
    .init(
      "memory.pageboxPoolCapMB", "Page-box pool (MB)", "Renderer", "128", .integer(0...1024),
      storage: .renderer, help: "0 disables the pool."),
    .init(
      "adapter.spoof", "Report GPU vendor as", "Renderer", "nvidia",
      .choices([.init("none", "Real GPU"), .init("nvidia", "NVIDIA"), .init("amd", "AMD")]),
      storage: .renderer,
      help:
        "For games that choose features by vendor. Far Cry 2 reads a vendor database at start-up."
    ),
    .init(
      "caps.dfFormats", "Offer DF depth formats", "Renderer", "true", boolean, storage: .renderer),
    .init(
      "render.preserveDiscardBackbuffer", "Preserve discarded back buffer", "Renderer", "false",
      boolean, storage: .renderer),
    .init(
      "display.legacy4By3", "List 4:3 display modes", "Renderer", "false", boolean,
      storage: .renderer),
  ]

  private static let gameplay: [FarCry2Setting] = [
    .init(
      "difficulty", "Difficulty level", "Gameplay", "1", .integer(0...3),
      storage: single("DifficultyLevel", in: game),
      help: "The profile's number; the game's menu names for each level are not verified."),
    .init("autosave", "Autosave", "Gameplay", "1", toggle, storage: single("Autosave", in: game)),
    .init(
      "subtitles", "Subtitles", "Gameplay", "1", toggle, storage: single("UseSubtitles", in: game)),
    .init(
      "compass", "Compass and mini-map", "Gameplay", "1", toggle,
      storage: single("UseCompassMiniMap", in: game)),
    .init(
      "roadSigns", "Highlight road signs", "Gameplay", "1", toggle,
      storage: single("UseRoadSignHilight", in: game)),
    .init(
      "crosshair", "Use the crosshair to aim", "Gameplay", "0", toggle,
      storage: single("HelpCrosshair", in: game)),
    .init("ambx", "amBX lighting", "Gameplay", "0", toggle, storage: single("UseAmbx", in: game)),
    .init("machete", "Machete", "Gameplay", "0", toggle, storage: single("Machete", in: game)),
  ]

  private static let mouse: [FarCry2Setting] = [
    .init(
      "sensitivity", "Look sensitivity", "Mouse", "0.9", .decimal(0.1...5),
      storage: single("Sensitivity", in: game), help: "The starter offers 0.1–5."),
    .init(
      "invertY", "Invert vertical look", "Mouse", "0", toggle, storage: single("Invert_y", in: game)
    ),
    .init(
      "mouseSmooth", "Mouse smoothing", "Mouse", "0", toggle,
      storage: single("UseMouseSmooth", in: game)),
    .init(
      "smoothness", "Smoothness", "Mouse", "1", .decimal(0...5),
      storage: single("Smoothness", in: game)),
    .init(
      "smoothnessIronsight", "Smoothness when aiming", "Mouse", "1", .decimal(0...5),
      storage: single("Smoothness_Ironsight", in: game)),
  ]

  private static let audio: [FarCry2Setting] = [
    .init(
      "music", "Music", "Audio", "1", toggle,
      storage: single("MusicEnabled", in: ["SoundProfile"])),
    .init(
      "volume", "Master volume", "Audio", "100", .integer(0...100),
      storage: single("MasterVolume", in: ["SoundProfile"])),
  ]

  private static let launchOptions: [FarCry2Setting] = [
    .init(
      "borderless", "Borderless window", "Launch options", "0", toggle, storage: .launcher,
      launch: .argument("-borderless"),
      help: "The game's own -borderless switch."),
    .init(
      "dock", "Show the game in the Game view", "Launch options", "0", toggle, storage: .launcher,
      help:
        "Runs the game in a borderless window and keeps it over the Game view. Needs Accessibility permission."
    ),
    .init(
      "noSound", "Silent start", "Launch options", "0", toggle, storage: .launcher,
      launch: .argument("-nosound"), help: "The game's -nosound switch."),
    .init(
      "noPad", "Ignore game controllers", "Launch options", "0", toggle, storage: .launcher,
      launch: .argument("-nopad"), help: "The game's -nopad switch."),
    .init(
      "noExMouse", "Shared mouse", "Launch options", "0", toggle, storage: .launcher,
      launch: .argument("-noexmouse"),
      help: "The game's -noexmouse switch; its exact effect is not verified."),
  ]

  private static let cheats: [FarCry2Setting] = [
    .init(
      "cheat.godMode", "God mode", "Player", "0", toggle, storage: .launcher,
      launch: .console("SetSetting cheat_GodMode {value}"), help: "Sets the god mode cheat."),
    .init(
      "cheat.health", "Set health at start", "Player", "0", .integer(0...1000), storage: .launcher,
      launch: .console("set_health {value}"),
      help: "0 leaves health alone. The value's scale is not verified."),
    .init(
      "cheat.noWeapon", "No-weapon mode", "Player", "0", toggle, storage: .launcher,
      launch: .console("set_no_weapon_mode {value}")),
    .init(
      "cheat.diamonds", "Add diamonds at start", "Player", "0", .integer(0...9999),
      storage: .launcher, launch: .console("Cheat_AddDiamonds {value}"),
      help: "0 adds none."),
    .init(
      "cheat.unlimitedAmmo", "Unlimited ammo", "Weapons", "0", toggle, storage: .launcher,
      launch: .console("SetSetting cheat_UnlimitedAmmo {value}"),
      help: "Sets the unlimited ammo cheat."),
    .init(
      "cheat.unlimitedReliability", "Unlimited weapon reliability", "Weapons", "0", toggle,
      storage: .launcher,
      launch: .console("SetSetting cheat_UnlimitedReliability {value}"),
      help: "Sets the unlimited reliability cheat."),
    .init(
      "cheat.allWeapons", "Unlock all weapons", "Weapons", "0", toggle, storage: .launcher,
      launch: .console("SetSetting cheat_AllWeaponsUnlock {value}"),
      help: "Unlocks all weapons at the bazaar."),
    .init(
      "cheat.hour", "Hour of the day", "World", "-1", .integer(-1...23), storage: .launcher,
      launch: .console("SetSetting env_Hour {value}"),
      help: "-1 keeps the game's own clock."),
    .init(
      "cheat.timeScale", "Time speed", "World", "-1", .decimal(-1...100), storage: .launcher,
      launch: .console("SetSetting env_TimeScale {value}"),
      help: "-1 keeps the game's own speed."),
    .init(
      "cheat.windForce", "Wind force (km/h)", "World", "-1", .decimal(-1...600),
      storage: .launcher, launch: .console("SetSetting env_WindForce {value}"),
      help: "Roughly km/h, up to 600. -1 keeps the game's own wind."),
    .init(
      "cheat.windDirection", "Wind direction (degrees)", "World", "-1", .integer(-1...360),
      storage: .launcher, launch: .console("SetSetting env_WindDir {value}"),
      help: "Around the vertical axis. -1 keeps the game's own wind."),
  ]

  package static func setting(_ id: String) -> FarCry2Setting? {
    settings.first { $0.id == id }
  }
}
