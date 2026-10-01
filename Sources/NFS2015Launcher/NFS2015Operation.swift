import Foundation
import NFS2015Core

/// One helper transaction; a request carries settings only for the operation that applies them.
enum NFS2015Operation: Sendable, Equatable {
  case prepare
  case play
  case configure(NFS2015Settings)
  case chooseInstallation(URL)
  case enableController
}

/// Asynchronous boundary for helper transactions, so the UI actor never touches the filesystem.
protocol NFS2015Serving: Sendable {
  func perform(_ operation: NFS2015Operation) async throws -> NFS2015Snapshot
  func logLocation() async -> URL?
}
