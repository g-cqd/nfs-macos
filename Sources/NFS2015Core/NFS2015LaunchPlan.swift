import Foundation
import LauncherCore

/// One Windows program and its arguments, as the guest sees them.
package struct GuestCommand: Equatable, Sendable {
  package let windowsPath: String
  package let arguments: [String]

  package init(windowsPath: String, arguments: [String]) {
    self.windowsPath = windowsPath
    self.arguments = arguments
  }

  /// The argument list handed to the bundle's `wine` binary.
  package var wineArguments: [String] { [windowsPath] + arguments }
}

/// The ordered steps that start Need for Speed (2015) through the player's EA app.
///
/// The client must be started directly with its own argument: handing the argument to the
/// launcher stub does not reach the client process it creates, and without it the EA
/// interface renders blank. Only once the client reports that it is signed in and booted does
/// the stub's launch request activate the game. A client that is already running is reused.
package struct NFS2015LaunchPlan: Equatable, Sendable {
  /// Step one: the window-owning client, started with the arguments it needs.
  package let client: GuestCommand
  /// Step three: the launch request handed to the running client.
  package let request: GuestCommand
  /// The working directory for both steps, inside the player's own installation.
  package let workingDirectory: URL
  /// Step two: how the client's own log tells that it is signed in and booted.
  package let readiness: ClientLogProbe
  /// The bound on step two.
  package let readinessSeconds: Int

  package static func make(install: NFS2015Install, plan: StoreClientPlan) throws(LauncherError)
    -> Self
  {
    try plan.validate()
    let driveC = install.prefix.appendingPathComponent("drive_c")
    return Self(
      client: GuestCommand(
        windowsPath: try install.windowsPath(of: install.client),
        arguments: plan.clientArguments),
      request: GuestCommand(
        windowsPath: try install.windowsPath(of: install.clientLauncher),
        arguments: [plan.launchRequest]),
      workingDirectory: install.game,
      readiness: ClientLogProbe(
        log: try logLocation(plan.readinessLog, in: driveC), startMarker: plan.startMarker,
        readyEvents: plan.readyEvents),
      readinessSeconds: plan.readinessSeconds)
  }

  /// Where the client's log is or will be.
  ///
  /// The log does not exist until the client first runs, so a location that is absent now is
  /// placed below its nearest existing folder, matched the way the guest matches names.
  static func logLocation(_ relative: String, in root: URL) throws(LauncherError) -> URL {
    if let found = try GuestPath.resolve(relative, in: root) { return found }
    let components = relative.split(separator: "/").map(String.init)
    for count in stride(from: components.count - 1, through: 1, by: -1) {
      if let base = try GuestPath.resolve(components.prefix(count).joined(separator: "/"), in: root)
      {
        return components.dropFirst(count).reduce(base) { $0.appendingPathComponent($1) }
      }
    }
    return components.reduce(root.standardizedFileURL.resolvingSymlinksInPath()) {
      $0.appendingPathComponent($1)
    }
  }
}
