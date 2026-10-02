import Foundation
import LauncherCore

/// Command-line contract between the starter and its session helper.
struct SessionOptions {
  enum Action: String {
    case prepare = "--prepare"
    case play = "--play"
    case configure = "--configure"
    case importGame = "--import-game"
    case backups = "--backups"
    case shaderCache = "--shader-cache"
  }

  let bundle: URL
  let support: URL
  let action: Action
  let request: URL?

  init(arguments: [String]) throws {
    let usage = LauncherError.operation(
      "Usage: FarCry2Session <app> --support <folder> <action> [--request <path>]")
    guard let app = arguments.first, app.hasSuffix(".app"), arguments.count <= 6 else {
      throw usage
    }
    var support: String?
    var request: String?
    var action: Action?
    var index = 1
    while index < arguments.count {
      let flag = arguments[index]
      if let named = Action(rawValue: flag) {
        guard action == nil else { throw LauncherError.operation("Choose only one operation.") }
        action = named
        index += 1
      } else if flag == "--support" || flag == "--request" {
        guard index + 1 < arguments.count else { throw usage }
        if flag == "--support" {
          guard support == nil else { throw usage }
          support = arguments[index + 1]
        } else {
          guard request == nil else { throw usage }
          request = arguments[index + 1]
        }
        index += 2
      } else {
        throw usage
      }
    }
    guard let support, let action else {
      throw LauncherError.operation("The session needs a player folder and an operation.")
    }
    if action != .prepare, request == nil {
      throw LauncherError.operation("This operation requires a request.")
    }
    self.bundle = URL(fileURLWithPath: app)
    self.support = URL(fileURLWithPath: support)
    self.action = action
    self.request = request.map { URL(fileURLWithPath: $0) }
  }
}
