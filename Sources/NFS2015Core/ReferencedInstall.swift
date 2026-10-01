import Foundation
import LauncherCore

/// Remembers which Windows folder the player chose, without copying anything out of it.
package struct ReferencedInstall: Codable, Equatable, Sendable {
  /// The host path of the Windows prefix root the player selected.
  package let prefix: String
  /// The client version seen when the folder was adopted; recorded for the session log only.
  package let clientVersion: String

  package init(prefix: String, clientVersion: String) {
    self.prefix = prefix
    self.clientVersion = clientVersion
  }
}

/// Reads and writes the single reference record beside the player's launcher settings.
package struct InstallReference {
  private let record: URL
  private let plan: StoreClientPlan

  package init(support: URL, plan: StoreClientPlan) {
    self.record = support.appendingPathComponent("referenced-install.json")
    self.plan = plan
  }

  /// - Returns: The readiness of the recorded folder, or `.noInstallationChosen`.
  package func readiness() throws(LauncherError) -> NFS2015Readiness {
    guard let stored = try load() else { return .noInstallationChosen }
    return try NFS2015Locator.resolve(
      prefix: URL(fileURLWithPath: stored.prefix), plan: plan)
  }

  package func load() throws(LauncherError) -> ReferencedInstall? {
    guard FileManager.default.fileExists(atPath: record.path) else { return nil }
    do {
      let stored = try JSONDecoder().decode(
        ReferencedInstall.self, from: BoundedFile.read(record, limit: 8192))
      guard !stored.prefix.isEmpty, stored.prefix.hasPrefix("/"), stored.prefix.utf8.count <= 1024
      else {
        throw LauncherError.operation("The recorded Windows folder is invalid.")
      }
      return stored
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not read the recorded Windows folder: \(error.localizedDescription)")
    }
  }

  /// Records a folder only after proving the game and its store client are both present.
  /// - Precondition: The caller holds the session lock and no game is running.
  package func adopt(_ prefix: URL, transaction: FileTransaction) throws(LauncherError)
    -> NFS2015Readiness
  {
    let readiness = try NFS2015Locator.resolve(prefix: prefix, plan: plan)
    guard let install = readiness.install else { return readiness }
    do {
      let stored = ReferencedInstall(
        prefix: install.prefix.path, clientVersion: install.clientVersion)
      try transaction.apply([FileChange(url: record, bytes: try JSONEncoder().encode(stored))])
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not record the Windows folder: \(error.localizedDescription)")
    }
    return readiness
  }
}
