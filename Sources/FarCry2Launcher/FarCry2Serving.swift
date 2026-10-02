import FarCry2Core
import Foundation

/// Asynchronous boundary for helper transactions and bounded setup files.
protocol FarCry2Serving: Sendable {
  func hasGameData() async throws -> Bool
  func perform(_ operation: FarCry2Operation) async throws -> FarCry2Snapshot
  func readSetup(_ url: URL) async throws -> FarCry2Settings
  func writeSetup(_ settings: FarCry2Settings, to url: URL) async throws
  func logLocation() async -> URL?
}
