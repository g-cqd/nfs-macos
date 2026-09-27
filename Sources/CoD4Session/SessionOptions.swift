import CoD4Core
import Foundation
import LauncherCore

struct SessionOptions {
  let bundle: URL
  let support: URL
  let action: String
  let request: URL?
  let mode: CoD4Mode
  let profile: String?

  init(arguments: [String]) throws {
    guard let app = arguments.first, app.hasSuffix(".app"), arguments.count <= 11 else {
      throw LauncherError.operation(
        "Usage: CoD4Session <app> --support <folder> <action> [--request <path>] [--mode <mode>] [--profile <name>]"
      )
    }
    var options: [String: String] = [:]
    var action: String?
    let actions = ["--prepare", "--play", "--configure", "--import-game", "--profiles"]
    var index = 1
    while index < arguments.count {
      let flag = arguments[index]
      if actions.contains(flag) {
        guard action == nil else { throw LauncherError.operation("Choose only one operation.") }
        action = flag
        index += 1
      } else {
        guard ["--support", "--request", "--mode", "--profile"].contains(flag),
          index + 1 < arguments.count, options[flag] == nil
        else {
          throw LauncherError.operation("Invalid session option.")
        }
        options[flag] = arguments[index + 1]
        index += 2
      }
    }
    guard let support = options["--support"], let action,
      let mode = CoD4Mode(rawValue: options["--mode"] ?? "singlePlayer")
    else {
      throw LauncherError.operation("The session needs a player folder, valid mode and operation.")
    }
    if ["--play", "--configure", "--profiles", "--import-game"].contains(action),
      options["--request"] == nil
    {
      throw LauncherError.operation("This operation requires a request.")
    }
    if let profile = options["--profile"], !CoD4ProfileStore.validName(profile) {
      throw LauncherError.operation("Invalid profile name.")
    }
    self.bundle = URL(fileURLWithPath: app)
    self.support = URL(fileURLWithPath: support)
    self.action = action
    self.request = options["--request"].map { URL(fileURLWithPath: $0) }
    self.mode = mode
    self.profile = options["--profile"]
  }
}
