import Foundation
import LauncherCore

struct SessionOptions {
  let bundle: URL
  let support: URL
  let action: String
  let request: URL?

  static let actions = [
    "--prepare", "--play", "--configure", "--choose-installation", "--enable-controller",
    "--install-client", "--open-client", "--configure-metalfx", "--configure-diagnostics",
  ]

  init(arguments: [String]) throws {
    guard let app = arguments.first, app.hasSuffix(".app"), arguments.count <= 7 else {
      throw LauncherError.operation(
        "Usage: NFS2015Session <app> --support <folder> <action> [--request <path>]")
    }
    var options: [String: String] = [:]
    var action: String?
    var index = 1
    while index < arguments.count {
      let flag = arguments[index]
      if Self.actions.contains(flag) {
        guard action == nil else { throw LauncherError.operation("Choose only one operation.") }
        action = flag
        index += 1
      } else {
        guard ["--support", "--request"].contains(flag), index + 1 < arguments.count,
          options[flag] == nil
        else {
          throw LauncherError.operation("Invalid session option.")
        }
        options[flag] = arguments[index + 1]
        index += 2
      }
    }
    guard let support = options["--support"], let action else {
      throw LauncherError.operation("The session needs a player folder and an operation.")
    }
    if [
      "--configure", "--choose-installation", "--install-client", "--configure-metalfx",
      "--configure-diagnostics",
    ].contains(action), options["--request"] == nil {
      throw LauncherError.operation("This operation requires a request.")
    }
    self.bundle = URL(fileURLWithPath: app)
    self.support = URL(fileURLWithPath: support)
    self.action = action
    self.request = options["--request"].map { URL(fileURLWithPath: $0) }
  }
}
