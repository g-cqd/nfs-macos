import Foundation

/// Portable graphics and input settings; excludes saves, cheats and player names.
package struct SetupProfile: Codable {
  private let format: String
  private let version: Int
  private let values: [String: String]
  private let mappings: ControllerMappings

  package init(settings: GameSettings) {
    format = "nfsmw.setup"
    version = 1
    values = settings.values
    mappings = settings.mappings
  }

  package static func read(_ data: Data) throws(LauncherError) -> SetupProfile {
    guard data.count <= 65_536 else { throw .operation("Setup profile is too large.") }
    do {
      let profile = try JSONDecoder().decode(Self.self, from: data)
      _ = try profile.applying(to: GameSettings())
      return profile
    } catch let error as LauncherError { throw error } catch {
      throw .operation("This is not a supported Most Wanted setup profile.")
    }
  }

  package func applying(to settings: GameSettings) throws(LauncherError) -> GameSettings {
    guard format == "nfsmw.setup", version == 1 else {
      throw .operation("This setup profile uses an unsupported format or version.")
    }
    var result = settings
    result.values = values
    result.mappings = mappings
    try result.validate()
    return result
  }

  package func encoded() throws(LauncherError) -> Data {
    _ = try applying(to: GameSettings())
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return try encoder.encode(self)
    } catch { throw .operation("Could not export setup profile: \(error.localizedDescription)") }
  }
}
