import Foundation

package struct SettingsStore {
  private let paths: AppPaths
  package init(paths: AppPaths) { self.paths = paths }
  package var preferences: URL { paths.support.appendingPathComponent("settings.json") }

  package func load() throws(LauncherError) -> GameSettings {
    if FileManager.default.fileExists(atPath: preferences.path) {
      do {
        let settings = try JSONDecoder().decode(
          GameSettings.self, from: BoundedFile.read(preferences, limit: 65_536))
        try settings.validate()
        return settings
      } catch let error as LauncherError { throw error } catch {
        throw .operation("Could not read saved launcher settings: \(error.localizedDescription)")
      }
    }
    var settings = GameSettings()
    let wide = try ConfigText(
      BoundedFile.text(paths.currentGame.appendingPathComponent(ConfigurationPlan.widePath)))
    let input = try ConfigText(
      BoundedFile.text(paths.currentGame.appendingPathComponent(ConfigurationPlan.inputPath)))
    let renderer = try ConfigText(
      BoundedFile.text(paths.currentGame.appendingPathComponent("mtld3d.conf")))
    for definition in GameSettings.definitions {
      let config: ConfigText
      switch definition.destination {
      case .widescreen: config = wide
      case .input: config = input
      case .renderer: config = renderer
      default: continue
      }
      guard let raw = config.value(section: definition.section, key: definition.key) else {
        continue
      }
      let value =
        definition.accepts(raw)
        ? raw : Double(raw).map { String($0).replacingOccurrences(of: ".0", with: "") } ?? raw
      if definition.accepts(value) { settings.values[definition.id] = value }
    }
    settings.mappings = try mapping(profile: "")
    try settings.validate()
    return settings
  }

  package func mapping(profile: String) throws(LauncherError) -> ControllerMappings {
    let selected = paths.currentGame.appendingPathComponent(
      try ConfigurationPlan.mappingPath(profile: profile))
    let url =
      FileManager.default.fileExists(atPath: selected.path)
      ? selected : paths.currentGame.appendingPathComponent(ConfigurationPlan.defaultMapPath)
    return try ControllerMappings(text: BoundedFile.text(url))
  }

  package func mappingProfiles() throws(LauncherError) -> [String] {
    let directory = paths.currentGame.appendingPathComponent("scripts/XtendedInputMaps")
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    do {
      let urls = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      guard urls.count <= 100 else {
        throw LauncherError.operation("Too many controller profiles.")
      }
      return urls.map(\.lastPathComponent).filter(ProfileName.isValid).sorted()
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not list controller profiles: \(error.localizedDescription)")
    }
  }

  /// Applies settings while Wine is stopped and the caller holds the session lock.
  package func apply(_ settings: GameSettings) throws(LauncherError) {
    try settings.validate()
    do {
      var changes: [FileChange] = []
      for (path, destination) in [
        (ConfigurationPlan.widePath, SettingDefinition.Destination.widescreen),
        (ConfigurationPlan.inputPath, .input), ("mtld3d.conf", .renderer),
      ] {
        let url = paths.currentGame.appendingPathComponent(path)
        let text = try ConfigurationPlan.config(
          BoundedFile.text(url), destination: destination, settings: settings)
        changes.append(FileChange(url: url, bytes: Data(text.utf8)))
      }
      let registry = paths.prefix.appendingPathComponent("user.reg")
      changes.append(
        FileChange(
          url: registry,
          bytes: Data(
            try ConfigurationPlan.registry(BoundedFile.text(registry), settings: settings).utf8)))
      var edits = settings.mappingEdits
      edits[settings.mappingProfile] = settings.mappings
      for profile in edits.keys.sorted() {
        guard let mappings = edits[profile] else { continue }
        let map = paths.currentGame.appendingPathComponent(
          try ConfigurationPlan.mappingPath(profile: profile))
        let original =
          FileManager.default.fileExists(atPath: map.path)
          ? map : paths.currentGame.appendingPathComponent(ConfigurationPlan.defaultMapPath)
        changes.append(
          FileChange(
            url: map, bytes: Data(try mappings.applying(to: BoundedFile.text(original)).utf8)))
      }
      let unlockName = "scripts/Z_NFSMW_Unlocks.asi"
      let active = paths.currentGame.appendingPathComponent(unlockName)
      let disabled = paths.currentGame.appendingPathComponent(unlockName + ".disabled")
      let desired = settings.unlockAll ? active : disabled
      let other = settings.unlockAll ? disabled : active
      let source = paths.template.appendingPathComponent(unlockName)
      changes.append(FileChange(url: desired, bytes: try BoundedFile.read(source)))
      changes.append(FileChange(url: other, bytes: nil))
      var persisted = settings
      persisted.mappingEdits = [:]
      changes.append(FileChange(url: preferences, bytes: try JSONEncoder().encode(persisted)))
      try FileTransaction(root: paths.support).apply(changes)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not apply launcher settings: \(error.localizedDescription)")
    }
  }
}
