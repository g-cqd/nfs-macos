import Foundation

/// Stored with a complete generation so its origin changes atomically with the active game.
struct GameGeneration: Codable {
  let bundleVersion: String
  let imported: Bool
  /// What the recognition rules found in an imported installation; nil for fixed-manifest games.
  let installation: InstalledGame?

  init(bundleVersion: String, imported: Bool, installation: InstalledGame? = nil) {
    self.bundleVersion = bundleVersion
    self.imported = imported
    self.installation = installation
  }
}
