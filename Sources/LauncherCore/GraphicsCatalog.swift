package enum GraphicsCatalog {
  private static let toggle = [SettingChoice("0", "Off"), SettingChoice("1", "On")]
  private static let quality = [
    SettingChoice("0", "Off"), SettingChoice("1", "Low"), SettingChoice("2", "Medium"),
    SettingChoice("3", "High"),
  ]
  package static let groups = [
    "Display & MetalFX", "Detail & reflections", "Shadows", "Effects", "Camera & interface",
  ]
  package static let settings: [SettingDefinition] = [
    .init(
      "width", "Resolution width", groups[0], .launcher, "", "", "1680", range: 640...7680,
      help: "Game resolution in pixels. Window size and Retina output also affect the final image."),
    .init("height", "Resolution height", groups[0], .launcher, "", "", "1050", range: 480...4320),
    .init(
      "window", "Display mode", groups[0], .widescreen, "MISC", "WindowedMode", "4",
      choices: [
        .init("4", "Borderless fullscreen"), .init("2", "Window"), .init("3", "Resizable window"),
        .init("1", "Borderless window"), .init("0", "Exclusive fullscreen"),
      ]),
    .init(
      "fps", "Frame rate cap", groups[0], .renderer, "", "present.maxFps", "120", range: 0...240,
      help:
        "0 is uncapped. A cap is a limit, not a guaranteed frame rate. VSync also limits output to the display refresh rate."
    ),
    .init("vsync", "VSync", groups[0], .registry, "", "g_VSyncOn", "0", choices: toggle),
    .init(
      "scale", "MetalFX render scale", groups[0], .renderer, "", "render.scale", "1",
      choices: [
        .init("1", "100% — full render resolution"), .init("0.85", "85%"), .init("0.75", "75%"),
        .init("0.67", "67%"), .init("0.5", "50%"),
      ],
      help:
        "MetalFX spatial upscales when render and output sizes differ. Lower scale also reduces HUD and text resolution. This is not temporal upscaling or frame generation."
    ),
    .init(
      "retina", "Retina output", groups[0], .launcher, "", "", "0", choices: toggle,
      help:
        "Requests high density output from Wine. MetalFX may also upscale at 100% render scale when the output is larger."
    ),
    .init(
      "lodBias", "Preserve texture detail when scaling", groups[0], .renderer, "", "render.lodBias",
      "true", choices: [.init("true", "On"), .init("false", "Off")]),
    .init("hud", "Metal performance overlay", groups[0], .launcher, "", "", "0", choices: toggle),
    .init(
      "msaa", "Multisample antialiasing", groups[1], .registry, "", "g_FSAALevel", "2",
      choices: [.init("0", "Off"), .init("1", "2×"), .init("2", "4×")],
      help: "Disable MSAA before enabling SMAA."),
    .init("smaa", "SMAA", groups[1], .widescreen, "GRAPHICS", "SMAA", "0", choices: toggle),
    .init(
      "filtering", "Texture filtering", groups[1], .registry, "", "g_TextureFiltering", "2",
      choices: [.init("0", "Low"), .init("1", "Medium"), .init("2", "High")]),
    .init(
      "world", "World detail", groups[1], .registry, "", "g_WorldLodLevel", "3", choices: quality),
    .init(
      "cars", "Car detail", groups[1], .registry, "", "g_CarLodLevel", "1",
      choices: [.init("0", "Low"), .init("1", "High")]),
    .init(
      "carReflections", "Car reflections", groups[1], .registry, "", "g_CarEnvironmentMapEnable",
      "3", choices: quality),
    .init(
      "reflectionUpdate", "Update car reflections", groups[1], .registry, "",
      "g_CarEnvironmentMapUpdateData", "1", choices: toggle),
    .init(
      "roadReflections", "Road reflections", groups[1], .registry, "", "g_RoadReflectionEnable",
      "3", choices: quality),
    .init(
      "shadows", "Shadow detail", groups[2], .registry, "", "g_ShadowDetail", "2",
      choices: [.init("0", "Off"), .init("1", "Low"), .init("2", "High")]),
    .init(
      "shadowResolution", "Shadow map resolution", groups[2], .widescreen, "GRAPHICS", "ShadowsRes",
      "2048",
      choices: [
        .init("512", "512"), .init("1024", "1024"), .init("2048", "2048"), .init("4096", "4096"),
        .init("8192", "8192"),
      ]),
    .init(
      "shadowFix", "Correct shadow aspect ratio", groups[2], .widescreen, "GRAPHICS", "ShadowsFix",
      "1", choices: toggle),
    .init(
      "shadowLOD", "Improved shadow detail distance", groups[2], .widescreen, "GRAPHICS",
      "ImproveShadowLOD", "1", choices: toggle),
    .init(
      "shadowAuto", "Scale shadow resolution with aspect ratio", groups[2], .widescreen, "GRAPHICS",
      "AutoScaleShadowsRes", "1", choices: toggle),
    .init(
      "shadowSharp", "Force sharp shadows", groups[2], .widescreen, "GRAPHICS", "ForceSharpShadows",
      "0", choices: toggle),
    .init(
      "particles", "Particles", groups[3], .registry, "", "g_ParticleSystemEnable", "1",
      choices: toggle),
    .init("rain", "Rain", groups[3], .registry, "", "g_RainEnable", "1", choices: toggle),
    .init(
      "motionBlur", "Motion blur", groups[3], .registry, "", "g_MotionBlurEnable", "1",
      choices: toggle),
    .init(
      "bloom", "Overbright effects", groups[3], .registry, "", "g_OverBrightEnable", "1",
      choices: toggle),
    .init(
      "treatment", "Visual treatment", groups[3], .registry, "", "g_VisualTreatment", "1",
      choices: toggle),
    .init(
      "droplets", "Rain droplet size", groups[3], .widescreen, "GRAPHICS", "RainDropletsScale",
      "0.5",
      choices: [
        .init("0", "Hidden"), .init("0.25", "25%"), .init("0.5", "50%"), .init("1", "100%"),
      ]),
    .init(
      "streaks", "Light streaks", groups[3], .widescreen, "GRAPHICS", "LightStreaksEnable", "0",
      choices: toggle),
    .init(
      "gamma", "Gamma treatment", groups[3], .widescreen, "GRAPHICS", "ConsoleGamma", "0",
      choices: [.init("0", "Original"), .init("1", "Darker"), .init("2", "Xbox 360")]),
    .init(
      "skipIntro", "Skip intro movies", groups[4], .widescreen, "MISC", "SkipIntro", "1",
      choices: toggle),
    .init(
      "audio", "High quality audio", groups[4], .widescreen, "MISC", "HighSpecAudio", "1",
      choices: toggle),
    .init(
      "fov", "Widescreen field of view correction", groups[4], .widescreen, "MAIN", "FixFOV", "1",
      choices: toggle),
    .init(
      "fixHUD", "Widescreen HUD correction", groups[4], .widescreen, "MAIN", "FixHUD", "1",
      choices: toggle),
    .init(
      "camera", "Orbit camera", groups[4], .widescreen, "CAMERA", "Enable", "1", choices: toggle),
    .init(
      "cameraTimeout", "Camera return delay (seconds)", groups[4], .widescreen, "CAMERA",
      "CameraReturnTimeout", "3", range: 0...15),
    .init(
      "cameraSpeed", "Camera return speed", groups[4], .widescreen, "CAMERA", "CameraReturnSpeed",
      "2", choices: [.init("0.5", "0.5×"), .init("1", "1×"), .init("2", "2×"), .init("4", "4×")]),
  ]
}
