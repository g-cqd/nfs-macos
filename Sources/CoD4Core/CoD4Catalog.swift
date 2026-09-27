/// Editable fields supported by the installed PC configuration and retained engine dvar capture.
package enum CoD4Catalog {
  package static let graphicsGroups = [
    "Display", "Textures & filtering", "Lighting & effects", "World detail", "Renderer",
  ]
  package static let otherGroups = ["Audio", "Gameplay", "Mouse"]
  private static let toggle: CoD4Setting.Kind = .choices([.init("0", "Off"), .init("1", "On")])
  private static func choices(_ values: [String]) -> CoD4Setting.Kind {
    .choices(values.map { .init($0, $0) })
  }
  package static let settings: [CoD4Setting] = [
    .init(
      "r_mode", "Resolution", "Display", "2560x1600", .resolution,
      help:
        "The game must expose this display mode. Unsupported modes may fall back; confirm in the game."
    ),
    .init("r_fullscreen", "Fullscreen", "Display", "1", toggle),
    .init("r_vsync", "Vertical sync", "Display", "0", toggle),
    .init(
      "com_maxfps", "Frame limit", "Display", "0",
      choices(["0", "30", "60", "90", "120", "144", "165", "240"]),
      help: "0 lets the game run without its frame limiter."),
    .init("r_gamma", "Brightness", "Display", "0.8", .number(0.5...1.5)),
    .init(
      "r_aaSamples", "Anti-aliasing", "Display", "4",
      .choices([.init("1", "Off"), .init("2", "2× MSAA"), .init("4", "4× MSAA")])),
    .init(
      "r_aaAlpha", "Alpha-edge smoothing", "Display", "supersample (nice)",
      choices(["off", "dither (fast)", "supersample (nice)"])),
    .init("r_picmip_manual", "Manual texture quality", "Textures & filtering", "1", toggle),
    .init(
      "r_picmip", "Color textures", "Textures & filtering", "0", choices(["0", "1", "2", "3"]),
      help: "0 retains the highest texture detail."),
    .init(
      "r_picmip_bump", "Normal textures", "Textures & filtering", "0",
      choices(["0", "1", "2", "3"])),
    .init(
      "r_picmip_spec", "Specular textures", "Textures & filtering", "0",
      choices(["0", "1", "2", "3"])),
    .init(
      "r_picmip_water", "Water textures", "Textures & filtering", "0",
      choices(["0", "1", "2", "3"])),
    .init(
      "r_texFilterAnisoMin", "Minimum anisotropy", "Textures & filtering", "16",
      choices(["1", "2", "4", "8", "16"])),
    .init(
      "r_texFilterAnisoMax", "Maximum anisotropy", "Textures & filtering", "16",
      choices(["1", "2", "4", "8", "16"])),
    .init(
      "r_texFilterMipMode", "Mip filtering", "Textures & filtering", "Force Trilinear",
      choices(["Unchanged", "Force Trilinear"])),
    .init("sm_enable", "Shadows", "Lighting & effects", "1", toggle),
    .init(
      "sm_maxLights", "Shadow lights", "Lighting & effects", "4", choices(["1", "2", "3", "4"])),
    .init(
      "r_dlightLimit", "Dynamic lights", "Lighting & effects", "4",
      choices(["0", "1", "2", "3", "4"])),
    .init("r_specular", "Specular lighting", "Lighting & effects", "1", toggle),
    .init("r_dof_enable", "Depth of field", "Lighting & effects", "1", toggle),
    .init("r_glow_allowed", "Glow", "Lighting & effects", "1", toggle),
    .init("r_distortion", "Distortion", "Lighting & effects", "1", toggle),
    .init("r_zFeather", "Soft particle edges", "Lighting & effects", "1", toggle),
    .init("r_drawWater", "Water", "World detail", "1", toggle),
    .init("r_drawDecals", "Decals", "World detail", "1", toggle),
    .init("r_drawSun", "Sun", "World detail", "1", toggle),
    .init(
      "animated_trees_enabled", "Animated trees", "World detail", "1", toggle, campaignOnly: true),
    .init(
      "r_lodScaleRigid", "Object detail scale", "World detail", "1", choices(["1", "2", "4"]),
      help: "1 uses the detailed model selection from the game's high-quality preset."),
    .init(
      "r_lodScaleSkinned", "Character detail scale", "World detail", "1", choices(["1", "2", "4"])),
    .init("r_lodBiasRigid", "Object detail bias", "World detail", "0", choices(["-100", "0"])),
    .init(
      "r_lodBiasSkinned", "Character detail bias", "World detail", "0", choices(["-200", "0"])),
    .init(
      "r_fastSkin", "Fast skinning", "World detail", "0", toggle,
      help: "Off matches the game's highest CPU-quality preset."),
    .init(
      "ai_corpseCount", "Retained bodies", "World detail", "64",
      choices(["5", "10", "16", "32", "64"])),
    .init("ragdoll_enable", "Ragdolls", "World detail", "1", toggle),
    .init(
      "ragdoll_max_simulating", "Simultaneous ragdolls", "World detail", "16",
      choices(["0", "6", "8", "16"])),
    .init("fx_marks", "Impact marks", "World detail", "1", toggle),
    .init("fx_marks_ents", "Marks on characters", "World detail", "1", toggle),
    .init("fx_marks_smodels", "Marks on objects", "World detail", "1", toggle),
    .init(
      "render.scale", "Rendering scale", "Renderer", "1", choices(["0.5", "0.67", "0.75", "1"]),
      help:
        "1 renders at the full selected resolution. Lower scales trade detail for less rendering work."
    ),
    .init(
      "shader.asyncCompile", "Compile shaders asynchronously", "Renderer", "false",
      choices(["false", "true"]),
      help: "Off preserves every draw while a shader is compiled. On can temporarily omit draws."),
    .init("snd_volume", "Master volume", "Audio", "0.8", .number(0...1)),
    .init("snd_cinematicVolumeScale", "Cinematic volume", "Audio", "0.85", .number(0...1)),
    .init(
      "snd_khz", "Audio sample rate", "Audio", "44",
      .choices([.init("22", "22 kHz"), .init("44", "44 kHz")])),
    .init("snd_enableEq", "Equalization", "Audio", "1", toggle),
    .init("cg_subtitles", "Subtitles", "Gameplay", "1", toggle, campaignOnly: true),
    .init("cg_blood", "Blood effects", "Gameplay", "1", toggle),
    .init("cg_brass", "Ejected casings", "Gameplay", "1", toggle),
    .init("cg_crosshairAlpha", "Crosshair opacity", "Gameplay", "1", .number(0...1)),
    .init(
      "sensitivity", "Mouse sensitivity", "Mouse", "5", .number(0.1...30),
      help: "The starter offers 0.1–30; this is a UI limit, not the engine's full range."),
    .init(
      "m_pitch", "Vertical look", "Mouse", "0.022",
      .choices([.init("0.022", "Normal"), .init("-0.022", "Inverted")])),
    .init("m_filter", "Mouse smoothing", "Mouse", "0", toggle),
    .init("cl_mouseAccel", "Mouse acceleration", "Mouse", "0", .number(0...5)),
    .init("in_gpuSync", "Input / GPU synchronization", "Mouse", "1", toggle),
  ]

  package static func setting(_ id: String) -> CoD4Setting? {
    settings.first { $0.id == id }
  }
}
