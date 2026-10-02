import Foundation
import LauncherCore
import NFS2015Core

/// One helper transaction; a request carries settings only for the operation that applies them.
enum NFS2015Operation: Sendable, Equatable {
  case prepare
  case play
  case configure(NFS2015Settings)
  case chooseInstallation(URL)
  case enableController
  /// Runs the EA app installer the player downloaded, in the app's own Windows folder.
  case installClient(URL)
  /// Starts the EA app by itself so the player can sign in to it.
  case openClient
}

extension NFS2015Operation {
  /// Whether the helper starts a Windows program, which needs Rosetta first.
  var runsWindowsProgram: Bool {
    switch self {
    case .play, .installClient, .openClient: true
    default: false
    }
  }

  /// What the starter shows while the helper runs this operation.
  var busyPhase: NFS2015Phase {
    switch self {
    case .play: .playing
    case .installClient: .installing
    case .openClient: .signingIn
    default: .preparing
    }
  }
}

/// Asynchronous boundary for helper transactions, so the UI actor never touches the filesystem.
protocol NFS2015Serving: Sendable {
  func perform(_ operation: NFS2015Operation) async throws -> NFS2015Snapshot
  func logLocation() async -> URL?
  /// How far a running first-launch preparation has got; nil when none is staged.
  func preparationProgress() async -> PrefixSeed.Progress?
}

extension NFS2015Serving {
  func preparationProgress() async -> PrefixSeed.Progress? { nil }
}
