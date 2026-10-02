import Foundation

/// The options this app can change in the game's own options file.
///
/// Every key below was seen in the file the installed game wrote, so each exists on a machine
/// where the game has run. What differs is how well the values are known; each setting carries
/// that as its source. Nothing here reaches the binary `PROFILEOPTIONS` file beside the text
/// one: its speedometer, minimap, camera, telemetry and multiplayer preferences are not offered,
/// and neither are cheats, trainers, memory patches or anything touching protection, activation
/// or online features.
package enum NFS2015Catalog {
  static let detail = NFS2015Setting.Kind.choices([
    .init("0", "Level 0 (lowest)"), .init("1", "Level 1"), .init("2", "Level 2"),
    .init("3", "Level 3 (highest)"),
  ])
  static let toggle = NFS2015Setting.Kind.choices([.init("0", "Off"), .init("1", "On")])
  static let unitRange = NFS2015Setting.Kind.number(0...1, decimals: 6)

  static let levelHelp = "The game wrote 0 to 3 here; what each level means is inferred."

  static let display: [NFS2015Setting] = [
    .init(
      "render.resolution", "Resolution", .display, "1920x1080", .resolution,
      keys: ["GstRender.ResolutionWidth", "GstRender.ResolutionHeight"],
      help: """
        Width x height. On a Retina display the app sets Wine's RetinaMode, so the game sees the \
        panel's native size (for example 2560x1600). Pick a size your display supports. This \
        app has no MetalFX scaling control.
        """),
    .init(
      "render.fullscreen", "Full screen", .display, "1", toggle,
      keys: ["GstRender.FullscreenEnabled"]),
    .init(
      "render.refreshRate", "Refresh rate (Hz)", .display, "60", .number(24...480, decimals: 6),
      keys: ["GstRender.FullscreenRefreshRate"],
      help: "Used only in full screen. The game ignores a rate the display cannot present."),
  ]

  static let quality: [NFS2015Setting] = [
    .init(
      "quality.texture", "Textures", .quality, "3", detail, keys: ["GstRender.TextureQuality"],
      source: .reported, help: levelHelp),
    .init(
      "quality.mesh", "Geometry", .quality, "3", detail, keys: ["GstRender.MeshQuality"],
      source: .reported),
    .init(
      "quality.shadow", "Shadows", .quality, "3", detail, keys: ["GstRender.ShadowQuality"],
      source: .reported),
    .init(
      "quality.effects", "Effects", .quality, "3", detail, keys: ["GstRender.EffectsQuality"],
      source: .reported),
    .init(
      "quality.terrain", "Terrain", .quality, "1", detail, keys: ["GstRender.TerrainQuality"],
      source: .reported),
    .init(
      "quality.undergrowth", "Undergrowth", .quality, "1", detail,
      keys: ["GstRender.UndergrowthQuality"], source: .reported),
    .init(
      "render.motionBlur", "Motion blur", .quality, "1", toggle,
      keys: ["GstRender.MotionBlurEnabled"]),
    .init("render.filmGrain", "Film grain", .quality, "1", toggle, keys: ["GstRender.FilmGrain"]),
    .init(
      "render.brightness", "Brightness", .quality, "0.5", unitRange,
      keys: ["GstRender.Brightness"]),
  ]

  package static let settings: [NFS2015Setting] =
    display + quality + controls + audio + experimental

  package static func setting(_ id: String) -> NFS2015Setting? {
    settings.first { $0.id == id }
  }

  package static func settings(in group: NFS2015SettingGroup) -> [NFS2015Setting] {
    settings.filter { $0.group == group }
  }

  /// Every option file key the catalog can read or write.
  package static var keys: [String] { settings.flatMap(\.keys) }
}

/// One tap that sets several options together. A preset changes the pending edits only; nothing
/// is written until the player saves.
package enum NFS2015Preset {
  /// All six detail levels at their top step, motion blur and film grain off. The resolution is
  /// left alone: it is whatever the display's native size is, which only the player knows.
  package static let maximumQuality: [String: String] = [
    "quality.texture": "3", "quality.mesh": "3", "quality.shadow": "3", "quality.effects": "3",
    "quality.terrain": "3", "quality.undergrowth": "3", "render.motionBlur": "0",
    "render.filmGrain": "0",
  ]
}
