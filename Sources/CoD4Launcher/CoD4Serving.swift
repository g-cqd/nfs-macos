import CoD4Core
import Foundation

/// Asynchronous boundary for helper transactions and bounded setup files.
protocol CoD4Serving: Sendable {
  func hasGameData() async throws -> Bool
  func perform(_ operation: CoD4Operation) async throws -> CoD4Snapshot
  func readSetup(_ url: URL) async throws -> CoD4Settings
  func writeSetup(_ settings: CoD4Settings, to url: URL) async throws
  func logLocation() async -> URL?
}
