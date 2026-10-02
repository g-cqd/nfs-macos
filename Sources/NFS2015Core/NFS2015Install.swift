import Foundation
import LauncherCore

/// A Need for Speed (2015) installation, and the EA client that activates it, found in place.
///
/// Nothing here is copied. The app records where the player's Windows folder is and runs the
/// player's own EA app from it, because Denuvo activates the executable through that client.
package struct NFS2015Install: Equatable, Sendable {
  /// The Windows prefix root, which holds `drive_c`.
  package let prefix: URL
  /// The game's installation folder.
  package let game: URL
  /// The game executable inside that folder.
  package let executable: URL
  /// The EA client version folder that was found, such as `13.796.0.6309`.
  package let clientVersion: String
  /// The window-owning EA client.
  package let client: URL
  /// The stub that hands a launch request to the running client.
  package let clientLauncher: URL
  /// The single Windows user profile this prefix uses; its name is not always `USER`.
  package let userProfile: URL

  /// The guest path for a host location inside this prefix's `drive_c`.
  package func windowsPath(of url: URL) throws(LauncherError) -> String {
    try Self.windowsPath(of: url, in: prefix)
  }

  /// The guest path for a host location inside a prefix's `drive_c`.
  package static func windowsPath(of url: URL, in prefix: URL) throws(LauncherError) -> String {
    let root = prefix.appendingPathComponent("drive_c").standardizedFileURL
      .resolvingSymlinksInPath()
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    guard path.hasPrefix(root.path + "/") else {
      throw .operation("That location is outside the chosen Windows folder.")
    }
    return "C:\\" + path.dropFirst(root.path.count + 1).replacingOccurrences(of: "/", with: "\\")
  }
}

/// The EA client found in a prefix, whether or not anyone has signed in to it yet.
package struct NFS2015Client: Equatable, Sendable {
  /// The client version folder that was found, such as `13.796.0.6309`.
  package let version: String
  /// The window-owning EA client.
  package let executable: URL
  /// The stub that hands a launch request to the running client.
  package let launcher: URL
}

/// The step a player still has to take before the game can start, when the app owns the prefix.
package enum NFS2015Setup: String, Codable, Equatable, Sendable {
  /// The EA app is not installed in the app's own Windows folder yet.
  case installClient
  /// The EA app is installed, and the player has not signed in to it.
  case signIn
}

/// Why the app cannot start the game yet, in the player's own terms.
package enum NFS2015Readiness: Equatable, Sendable {
  case ready(NFS2015Install)
  case noInstallationChosen
  case notAWindowsFolder
  case gameMissing
  case clientMissing(String)
  case clientIncomplete(String)
  case notSignedIn(String)

  package var install: NFS2015Install? {
    if case .ready(let install) = self { return install }
    return nil
  }

  /// What a player must do next in a Windows folder the app owns, or nil when nothing is missing.
  package var setup: NFS2015Setup? {
    switch self {
    case .clientMissing, .clientIncomplete: .installClient
    case .notSignedIn: .signIn
    default: nil
    }
  }

  /// The same blocker, worded for an app that created and owns its Windows folder, where the
  /// player installs the EA app and signs in from this app instead of from another one.
  package var ownedMessage: String? {
    switch self {
    case .ready: nil
    case .noInstallationChosen, .notAWindowsFolder:
      "This app's own Windows folder is incomplete. Open the log, then reopen the app."
    case .gameMissing:
      """
      The game files are missing from this app's own Windows folder. Open the log; if they were \
      deleted, remove the NFS2015Mac folder in your Library/Application Support so the app \
      prepares them again. That also removes the EA app, your sign-in and the game's settings.
      """
    case .clientMissing(let name):
      """
      Install the \(name): press Install EA App and choose the installer you downloaded from \
      ea.com. Need for Speed (2015) is protected by Denuvo and cannot start without it.
      """
    case .clientIncomplete(let name):
      """
      The \(name) folder is there, but its program files are incomplete. Press Install EA App \
      and run the installer again to repair it.
      """
    case .notSignedIn(let name):
      """
      Press Open EA App, sign in to your EA account, then quit the \(name) and press Play. Need \
      for Speed (2015) is activated through your own EA account; this app never stores, \
      replaces or works around that sign-in.
      """
    }
  }

  /// A message to show beside a disabled Play button; nil once the game can be started.
  package var message: String? {
    switch self {
    case .ready: nil
    case .noInstallationChosen:
      "Choose the Windows folder that holds your EA app and your Need for Speed installation."
    case .notAWindowsFolder:
      "That folder is not a Windows installation: it contains no drive_c folder."
    case .gameMissing:
      """
      Need for Speed (2015) is not installed in that Windows folder. Install it from the EA \
      app, then choose the folder again.
      """
    case .clientMissing(let name):
      """
      The \(name) is not installed in that Windows folder. Need for Speed (2015) is protected \
      by Denuvo and cannot start without it. Install the \(name) from ea.com into the same \
      Windows folder, then choose the folder again.
      """
    case .clientIncomplete(let name):
      """
      The \(name) folder is there, but its program files are incomplete. Repair or reinstall \
      the \(name), then choose the folder again.
      """
    case .notSignedIn(let name):
      """
      Open the \(name) and sign in to your EA account, then play again. Need for Speed (2015) \
      is activated through your own EA account; this app never stores, replaces or works \
      around that sign-in.
      """
    }
  }
}

/// Finds the player's installation without changing it.
package enum NFS2015Locator {
  /// - Parameter prefix: The Windows folder the player chose, which holds `drive_c`.
  /// - Parameter plan: The recipe-declared client and game locations.
  /// - Returns: A readiness answer; `.ready` carries the resolved installation.
  /// - Throws: A failure when the chosen folder cannot be inspected safely.
  /// - Complexity: O(entries in the inspected folders); no file contents are read.
  package static func resolve(prefix: URL, plan: StoreClientPlan) throws(LauncherError)
    -> NFS2015Readiness
  {
    try plan.validate()
    let files = FileManager.default
    let prefix = prefix.standardizedFileURL.resolvingSymlinksInPath()
    do {
      let values = try prefix.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        return .notAWindowsFolder
      }
    } catch { return .notAWindowsFolder }
    guard let driveC = try GuestPath.resolve("drive_c", in: prefix) else {
      return .notAWindowsFolder
    }
    guard let game = try GuestPath.resolve(plan.gameRoot, in: driveC),
      let executable = try GuestPath.resolve(GameKind.nfs2015.executable, in: game),
      files.isReadableFile(atPath: executable.path)
    else {
      return .gameMissing
    }
    guard let installRoot = try GuestPath.resolve(plan.installRoot, in: driveC) else {
      return .clientMissing(plan.name)
    }
    guard let installed = try client(in: installRoot, plan: plan) else {
      return .clientIncomplete(plan.name)
    }
    guard let profile = try userProfile(in: driveC) else {
      return .notSignedIn(plan.name)
    }
    for evidence in plan.signInEvidence {
      guard let found = try GuestPath.resolve(evidence, in: profile),
        files.fileExists(atPath: found.path)
      else {
        return .notSignedIn(plan.name)
      }
    }
    return .ready(
      NFS2015Install(
        prefix: prefix, game: game, executable: executable,
        clientVersion: installed.version, client: installed.executable,
        clientLauncher: installed.launcher,
        userProfile: profile))
  }

  /// Finds the installed client, if any, without needing a signed-in account.
  /// - Returns: The client, or nil when it is absent or its launcher stub is missing.
  /// - Complexity: O(entries in the inspected folders); no file contents are read.
  package static func client(prefix: URL, plan: StoreClientPlan) throws(LauncherError)
    -> NFS2015Client?
  {
    try plan.validate()
    let prefix = prefix.standardizedFileURL.resolvingSymlinksInPath()
    guard let driveC = try GuestPath.resolve("drive_c", in: prefix),
      let installRoot = try GuestPath.resolve(plan.installRoot, in: driveC)
    else { return nil }
    return try client(in: installRoot, plan: plan)
  }

  /// Picks the newest version folder that actually contains the client, and needs its launcher.
  ///
  /// The installer also registers a stable junction beside the version folders, but the host
  /// sees that junction as a link that need not resolve, and it is absent in a prefix whose
  /// client updated itself. The version folders are therefore the authority.
  private static func client(in root: URL, plan: StoreClientPlan) throws(LauncherError)
    -> NFS2015Client?
  {
    for candidate in try GuestPath.versionFolders(in: root) {
      guard let executable = try GuestPath.resolve(plan.clientExecutable, in: candidate) else {
        continue
      }
      guard let launcher = try GuestPath.resolve(plan.launcherExecutable, in: candidate) else {
        return nil
      }
      return NFS2015Client(
        version: candidate.lastPathComponent, executable: executable, launcher: launcher)
    }
    return nil
  }

  /// Discovers the prefix's single real user profile; this runtime names it `crossover`.
  private static func userProfile(in driveC: URL) throws(LauncherError) -> URL? {
    guard let users = try GuestPath.resolve("users", in: driveC) else { return nil }
    do {
      let contents = try FileManager.default.contentsOfDirectory(
        at: users, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard contents.count <= 100 else {
        throw LauncherError.operation("Too many Windows user folders.")
      }
      let profiles = try contents.filter { url in
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
          && url.lastPathComponent != "Public"
      }
      return profiles.count == 1 ? profiles[0] : nil
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not read the Windows user folders: \(error.localizedDescription)")
    }
  }
}
