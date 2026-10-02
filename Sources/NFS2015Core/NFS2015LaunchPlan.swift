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
/// interface renders blank. Only once the client is up does the stub's launch request
/// activate the game.
package struct NFS2015LaunchPlan: Equatable, Sendable {
  /// Step one: the window-owning client, started with the arguments it needs.
  package let client: GuestCommand
  /// Step three: the launch request handed to the running client.
  package let request: GuestCommand
  /// The working directory for both steps, inside the player's own installation.
  package let workingDirectory: URL
  /// Step two: host locations whose timestamp advancing shows the client came up.
  package let readinessEvidence: [URL]
  /// Step two: how many helper processes the client must have before it can accept a request.
  package let readinessChildren: Int
  /// The bound on step two.
  package let readinessSeconds: Int

  package static func make(install: NFS2015Install, plan: StoreClientPlan) throws(LauncherError)
    -> Self
  {
    try plan.validate()
    var evidence: [URL] = []
    for relative in plan.readinessEvidence {
      if let url = try GuestPath.resolve(relative, in: install.userProfile) {
        evidence.append(url)
      }
    }
    return Self(
      client: GuestCommand(
        windowsPath: try install.windowsPath(of: install.client),
        arguments: plan.clientArguments),
      request: GuestCommand(
        windowsPath: try install.windowsPath(of: install.clientLauncher),
        arguments: [plan.launchRequest]),
      workingDirectory: install.game, readinessEvidence: evidence,
      readinessChildren: plan.readinessChildren, readinessSeconds: plan.readinessSeconds)
  }
}

/// Waits for the store client to come up, using only timestamps the client itself advances.
///
/// No credential, token or account file is read: the wait observes modification times of the
/// client's own working locations and stops as soon as one advances past the moment the client
/// was started. A client that produces no activity within its bound is reported as not ready.
package struct ClientReadiness {
  private let evidence: [URL]
  private let children: Int
  private let deadline: Int

  package init(evidence: [URL], children: Int, deadline: Int) {
    self.evidence = evidence
    self.children = children
    self.deadline = deadline
  }

  /// - Parameter since: The moment the client was started.
  /// - Parameter modified: The newest modification time of a location, or nil when absent.
  /// - Parameter isRunning: Whether the client process is still alive.
  /// - Parameter helpers: How many live helper processes the client has.
  /// - Parameter wait: Sleeps for one poll interval; injected so tests never sleep.
  /// - Returns: The number of whole seconds waited.
  /// - Throws: A failure when the client exits or produces no activity within its bound.
  package func wait(
    since: Date, modified: (URL) -> Date?, isRunning: () -> Bool, helpers: () -> Int,
    wait: (Int) throws -> Void
  ) throws(LauncherError) -> Int {
    guard !evidence.isEmpty else {
      throw .operation("The bundle declares no way to tell when the EA app is ready.")
    }
    var waited = 0
    while waited <= deadline {
      guard isRunning() else {
        throw .operation(
          """
          The EA app stopped before it was ready. Open the EA app on its own, sign in, then \
          play again.
          """)
      }
      if helpers() >= children,
        evidence.contains(where: { (modified($0) ?? .distantPast) >= since })
      {
        return waited
      }
      do { try wait(1) } catch {
        throw LauncherError.operation("The wait for the EA app was interrupted.")
      }
      waited += 1
    }
    throw .operation(
      """
      The EA app did not finish starting within \(deadline) seconds. Open the EA app on its \
      own, sign in, then play again.
      """)
  }

  /// The newest modification time at or below a location, bounded so a deep tree cannot stall.
  package static func newestModification(of url: URL) -> Date? {
    let files = FileManager.default
    func stamp(_ candidate: URL) -> Date? {
      try? candidate.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
    }
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
      values.isDirectory == true
    else {
      return stamp(url)
    }
    guard
      let contents = try? files.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.contentModificationDateKey]), contents.count <= 4096
    else {
      return stamp(url)
    }
    return ([stamp(url)] + contents.map(stamp)).compactMap { $0 }.max()
  }
}
