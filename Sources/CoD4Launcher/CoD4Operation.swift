import CoD4Core
import Foundation

/// One helper transaction; a request contains settings only for operations that apply them.
enum CoD4Operation: Sendable {
  case prepare(mode: CoD4Mode, profile: String?)
  case play(CoD4LaunchRequest)
  case configure(CoD4LaunchRequest)
  case profile(CoD4ProfileRequest, mode: CoD4Mode)
  case importGame(URL, CoD4Mode)

  var requestedMode: CoD4Mode {
    switch self {
    case .prepare(let mode, _), .importGame(_, let mode): mode
    case .play(let request), .configure(let request): request.mode
    case .profile(_, let mode): mode
    }
  }

  var launchRequest: CoD4LaunchRequest? {
    switch self {
    case .play(let request), .configure(let request): request
    default: nil
    }
  }
  var profileSelection: String? {
    if case .prepare(_, let profile) = self { return profile }
    return nil
  }
}
