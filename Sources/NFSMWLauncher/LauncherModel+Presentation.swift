import LauncherCore

extension LauncherModel {
  static let displayPreferences: Set<String> = [
    "width", "height", "window", "fps", "vsync", "retina", "hud",
  ]
  private static let commonIDs: Set<String> = ["window", "fps", "vsync", "scale"]

  func controllerButton(_ binding: SettingChoice) -> ControllerButtonPresentation {
    ControllerButtonPresentation(
      binding: binding, playStation: ["1", "3"].contains(settings.value("icons")))
  }

  var commonGraphics: [SettingDefinition] {
    GraphicsCatalog.settings.filter { Self.commonIDs.contains($0.id) }
  }

  func advancedGraphics(in group: String) -> [SettingDefinition] {
    graphics(in: group).filter { !Self.commonIDs.contains($0.id) }
  }

  var renderingSummary: String {
    if settings.value("scale") != "1" { return "MetalFX spatial · reduced render resolution" }
    if settings.value("retina") == "1" { return "Retina output · MetalFX when output is larger" }
    return "Native render resolution"
  }

  var displaySummary: String {
    settings.value("width") + " × " + settings.value("height") + " · " + aspectRatio.rawValue
  }

  var frameRateSummary: String {
    let cap = settings.value("fps")
    return cap == "0" ? "Uncapped" : "Up to " + cap + " FPS"
  }

  var settingsIssue: String? {
    do {
      try settings.validate()
      return nil
    } catch { return error.localizedDescription }
  }

  var canLaunch: Bool {
    rosetta.isAvailable && !phase.isBusy && phase != .needsGameData && settingsIssue == nil
  }

  var careerSummary: String {
    let count = saveEditor.profiles.count
    return count == 0
      ? "Start a new career in the game, or import a save."
      : "\(count) saved player profile\(count == 1 ? "" : "s")"
  }

  var basicControls: [SettingDefinition] {
    ControlsCatalog.settings.filter {
      ["icons", "leftDeadzone", "rightDeadzone", "cameraDeadzone"].contains($0.id)
    }
  }
  var advancedControls: [SettingDefinition] {
    ControlsCatalog.settings.filter {
      !["icons", "leftDeadzone", "rightDeadzone", "cameraDeadzone"].contains($0.id)
    }
  }
}
