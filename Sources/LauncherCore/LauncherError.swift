import Foundation

/// A launch or preparation failure suitable for display with the session log.
package enum LauncherError: Error, LocalizedError, Equatable {
  case operation(String)
  case alreadyRunning

  package var errorDescription: String? {
    switch self {
    case .operation(let message): message
    case .alreadyRunning: "Most Wanted is already running. Return to its game window."
    }
  }
}
