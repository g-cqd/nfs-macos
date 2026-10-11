import Foundation
import LauncherCore

/// The helper's command line: `BF3Session <app> --support <folder> <action> [value]`.
struct SessionOptions {
  let bundle: URL
  let support: URL
  let action: String
  /// The page name for `--open-store`, the preset name for `--preset`, on/off for `--sidecar`.
  let value: String?
  /// Developer-only replacements, honoured in debug builds only (see `DeveloperOverrides`).
  let developer: DeveloperOverrides

  static let actions = [
    "--prepare", "--start-client", "--open-store", "--status", "--stop", "--preset", "--sidecar",
    "--plan",
  ]
  static let valued = ["--open-store", "--preset", "--sidecar"]

  init(arguments: [String]) throws {
    guard let app = arguments.first, app.hasSuffix(".app"), arguments.count <= 14 else {
      throw LauncherError.operation(
        "Usage: BF3Session <app> --support <folder> <action> [value]")
    }
    var options: [String: String] = [:]
    var action: String?
    var value: String?
    var index = 1
    while index < arguments.count {
      let flag = arguments[index]
      if Self.actions.contains(flag) {
        guard action == nil else { throw LauncherError.operation("Choose only one operation.") }
        action = flag
        index += 1
        if Self.valued.contains(flag), index < arguments.count, !arguments[index].hasPrefix("--") {
          value = arguments[index]
          index += 1
        }
      } else {
        guard (["--support"] + DeveloperOverrides.flags).contains(flag),
          index + 1 < arguments.count, options[flag] == nil
        else {
          throw LauncherError.operation("Invalid session option: \(flag)")
        }
        options[flag] = arguments[index + 1]
        index += 2
      }
    }
    guard let support = options["--support"], let action else {
      throw LauncherError.operation("The session needs a player folder and an operation.")
    }
    if ["--preset", "--sidecar"].contains(action), value == nil {
      throw LauncherError.operation("This operation needs a value.")
    }
    self.bundle = URL(fileURLWithPath: app)
    self.support = URL(fileURLWithPath: support)
    self.action = action
    self.value = value
    self.developer = try DeveloperOverrides(options)
  }
}

/// Replacements for the bundled runtime, sidecar and prefix, so the built helper can be tried
/// against an existing setup on a developer's Mac without copying the app's payload there.
///
/// Only debug builds accept them; a release build refuses the flags, so the delivered app always
/// runs its own signed runtime and its own prefix.
struct DeveloperOverrides {
  static let flags = [
    "--developer-runtime", "--developer-sidecar", "--developer-prefix",
    "--developer-browser-profile",
  ]

  /// A Wine root holding `bin/wine` and `bin/wineserver`.
  let runtime: URL?
  let sidecar: URL?
  /// An existing prefix used in place; it is never placed, copied or verified.
  let prefix: URL?
  /// An existing browser profile, so a test reuses a Battlelog sign-in instead of a new profile.
  let browserProfile: URL?

  init(_ options: [String: String]) throws {
    let given = Self.flags.compactMap { flag in options[flag].map { (flag, $0) } }
    #if DEBUG
      for (flag, path) in given where !path.hasPrefix("/") {
        throw LauncherError.operation("\(flag) needs an absolute path.")
      }
      runtime = options["--developer-runtime"].map { URL(fileURLWithPath: $0) }
      sidecar = options["--developer-sidecar"].map { URL(fileURLWithPath: $0) }
      prefix = options["--developer-prefix"].map { URL(fileURLWithPath: $0) }
      browserProfile = options["--developer-browser-profile"].map { URL(fileURLWithPath: $0) }
    #else
      guard given.isEmpty else {
        throw LauncherError.operation("Developer overrides are not available in this build.")
      }
      runtime = nil
      sidecar = nil
      prefix = nil
      browserProfile = nil
    #endif
  }

  var isActive: Bool { runtime != nil || sidecar != nil || prefix != nil || browserProfile != nil }
}
