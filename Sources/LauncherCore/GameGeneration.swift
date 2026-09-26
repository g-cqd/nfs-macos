import Foundation

/// Stored with a complete generation so its origin changes atomically with the active game.
struct GameGeneration: Codable {
  let bundleVersion: String
  let imported: Bool
}
