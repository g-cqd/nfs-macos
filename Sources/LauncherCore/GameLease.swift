import Foundation

/// Protects a game that outlives an unexpectedly terminated session helper.
package struct GameLease {
  let url: URL

  package init(url: URL) { self.url = url }

  /// Rejects an active recorded process, and removes a record only after proving it is stale.
  package func check() throws(LauncherError) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      let values = try url.resourceValues(forKeys: [
        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size <= 1024
      else {
        throw LauncherError.operation("The previous game session record is invalid.")
      }
      let saved = try JSONDecoder().decode(ProcessIdentity.self, from: Data(contentsOf: url))
      guard try ProcessIdentity.read(pid: saved.pid) != saved else {
        throw LauncherError.alreadyRunning
      }
      try clear()
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Cannot check the previous game session: \(error.localizedDescription)")
    }
  }

  package func record(process: Int32) throws(LauncherError) {
    guard let identity = try ProcessIdentity.read(pid: process) else { return }
    do { try JSONEncoder().encode(identity).write(to: url, options: .atomic) } catch {
      throw .operation("Cannot record the game session: \(error.localizedDescription)")
    }
  }

  /// Called after the owned process exits, while the session lock is still held.
  package func clear() throws(LauncherError) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do { try FileManager.default.removeItem(at: url) } catch {
      throw .operation("Cannot clear the completed game session: \(error.localizedDescription)")
    }
  }
}
