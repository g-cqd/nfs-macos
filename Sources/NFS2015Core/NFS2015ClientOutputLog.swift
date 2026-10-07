import Foundation
import LauncherCore

/// Remembers which session log the running EA app writes its output to.
///
/// Every Wine program the EA app starts, the game included, inherits the EA app's standard error.
/// When a later Play reuses an EA app that an earlier Play or Open EA App started, the game's
/// fault lines therefore go to that earlier session's log and not to the new one. The helper that
/// starts the EA app records its log here, and a helper that reuses the EA app watches the
/// recorded log instead of its own. A diagnostic Play sends the EA app's output to a pipe instead,
/// and leaves no record.
package enum NFS2015ClientOutputLog {
  package static let fileName = "client-log.txt"
  static let sizeLimit = 1024

  /// Notes that the EA app this helper starts writes to `log`.
  package static func record(_ log: URL, in support: URL) {
    do {
      try Data(log.path.utf8).write(
        to: support.appendingPathComponent(fileName), options: .atomic)
    } catch { print("Could not record the EA app's log: \(error.localizedDescription)") }
  }

  /// Forgets the record, for an EA app whose output does not go to a session log (a diagnostic
  /// Play sends it to a pipe the helper drains), so a later Play does not watch the wrong file.
  package static func clear(in support: URL) {
    let url = support.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do { try FileManager.default.removeItem(at: url) } catch {
      print("Could not forget the EA app's log: \(error.localizedDescription)")
    }
  }

  /// The recorded log, when it is still a session log of this app: a regular file, not a link,
  /// named `session-*.log` directly inside the support folder's `Logs`.
  package static func recorded(in support: URL) -> URL? {
    guard
      let data = try? BoundedFile.read(support.appendingPathComponent(fileName), limit: sizeLimit),
      let text = String(data: data, encoding: .utf8), text.hasPrefix("/"),
      !text.contains("\n"), !text.contains("\0")
    else { return nil }
    let candidate = URL(fileURLWithPath: text).standardizedFileURL
    let folder = support.appendingPathComponent("Logs").standardizedFileURL
      .resolvingSymlinksInPath()
    guard candidate.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.path,
      candidate.lastPathComponent.hasPrefix("session-"),
      candidate.lastPathComponent.hasSuffix(".log"),
      let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink != true
    else { return nil }
    return candidate
  }
}
