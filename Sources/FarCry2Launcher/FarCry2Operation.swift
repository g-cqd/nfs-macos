import FarCry2Core
import Foundation

/// One helper transaction; only operations that apply settings carry them.
enum FarCry2Operation: Sendable {
  case prepare
  case play(FarCry2LaunchRequest)
  case configure(FarCry2LaunchRequest)
  case backups(FarCry2BackupRequest)
  case shaderCache(FarCry2ShaderCacheRequest)
  case importGame(URL)

  var launchRequest: FarCry2LaunchRequest? {
    switch self {
    case .play(let request), .configure(let request): request
    default: nil
    }
  }
}
