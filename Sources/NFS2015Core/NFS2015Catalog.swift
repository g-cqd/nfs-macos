import Foundation

/// The options this app manages in the game's own options file.
///
/// Every key below was read from the file the installed game wrote. Toggles are offered as the
/// two values the game itself recorded. Detail levels are offered as the four steps the game's
/// own Video menu presents. `GstRender.AmbientOcclusion` and `GstRender.AntiAliasingPost` are
/// deliberately absent: the game wrote a single value for each and this app has no evidence of
/// their full domains, so they stay under the game's own menu.
package enum NFS2015Catalog {
  static let detail = NFS2015Setting.Kind.choices([
    .init("0", "Low"), .init("1", "Medium"), .init("2", "High"), .init("3", "Ultra"),
  ])
  static let toggle = NFS2015Setting.Kind.choices([.init("0", "Off"), .init("1", "On")])

  package static let settings: [NFS2015Setting] = [
    .init(
      "render.resolution", "Resolution", "Display", "1920x1080", .resolution,
      keys: ["GstRender.ResolutionWidth", "GstRender.ResolutionHeight"],
      help: "The render resolution the game requests. Choose a mode your display supports."),
    .init(
      "render.fullscreen", "Full screen", "Display", "1", toggle,
      keys: ["GstRender.FullscreenEnabled"]),
    .init(
      "render.refreshRate", "Refresh rate", "Display", "60", .number(24...480, decimals: 6),
      keys: ["GstRender.FullscreenRefreshRate"],
      help: "Used only in full screen. The game ignores a rate your display cannot present."),
    .init(
      "render.vsync", "Vertical sync", "Display", "0", toggle,
      keys: ["GstRender.VSyncEnabled"]),
    .init(
      "render.brightness", "Brightness", "Display", "0.5", .number(0...1, decimals: 6),
      keys: ["GstRender.Brightness"]),
    .init(
      "quality.texture", "Textures", "Quality", "3", detail, keys: ["GstRender.TextureQuality"]),
    .init("quality.mesh", "Geometry", "Quality", "3", detail, keys: ["GstRender.MeshQuality"]),
    .init("quality.shadow", "Shadows", "Quality", "3", detail, keys: ["GstRender.ShadowQuality"]),
    .init("quality.effects", "Effects", "Quality", "3", detail, keys: ["GstRender.EffectsQuality"]),
    .init("quality.terrain", "Terrain", "Quality", "1", detail, keys: ["GstRender.TerrainQuality"]),
    .init(
      "quality.undergrowth", "Undergrowth", "Quality", "1", detail,
      keys: ["GstRender.UndergrowthQuality"]),
    .init(
      "render.motionBlur", "Motion blur", "Quality", "1", toggle,
      keys: ["GstRender.MotionBlurEnabled"]),
    .init("render.filmGrain", "Film grain", "Quality", "1", toggle, keys: ["GstRender.FilmGrain"]),
    .init(
      "input.deadZoneSteering", "Steering dead zone", "Controller", "0",
      .number(0...0.5, decimals: 6), keys: ["GstInput.DeadZonePadSteering"],
      help: "Applies to a connected game controller, which this game reads natively."),
    .init(
      "input.deadZoneThrottle", "Throttle dead zone", "Controller", "0",
      .number(0...0.5, decimals: 6), keys: ["GstInput.DeadZonePadThrottle"]),
    .init(
      "input.deadZoneBrake", "Brake dead zone", "Controller", "0", .number(0...0.5, decimals: 6),
      keys: ["GstInput.DeadZonePadBrake"]),
    .init(
      "input.autoReverse", "Auto reverse in manual gears", "Controller", "1", toggle,
      keys: ["GstInput.AutoReverseForManualGears"]),
  ]

  package static func setting(_ id: String) -> NFS2015Setting? {
    settings.first { $0.id == id }
  }

  package static let groups = ["Display", "Quality", "Controller"]
}
