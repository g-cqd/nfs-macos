import Foundation
import LauncherCore

/// A crash report the starter can point the player to.
package struct NFS2015CrashNotice: Codable, Equatable, Sendable {
  /// Absolute path of the report file.
  package let path: String
  /// The first line of what happened, such as `1 fault in 1 game launch; first at nfs16+0x...`.
  package let headline: String

  package init(path: String, headline: String) {
    self.path = path
    self.headline = headline
  }

  /// What the starter says, with the path the player can reveal.
  package var sentence: String {
    "The game stopped abnormally (\(headline)). A crash report was written to \(path)."
  }
}

/// Writes crash reports next to the session logs and keeps only the newest few.
package struct NFS2015CrashReportStore: Sendable {
  static let prefix = "crash-report-"
  /// The number of reports kept; older ones are deleted when a new one is written.
  package static let keep = 20

  private let folder: URL

  package init(folder: URL) { self.folder = folder }

  /// The existing reports, oldest first. The names carry a UTC time, so name order is time order.
  package func reports() -> [URL] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    // Without the extension, `...Z` sorts before `...Z-2`; with it, the order would flip.
    return names.filter { $0.hasPrefix(Self.prefix) && $0.hasSuffix(".txt") }
      .sorted { $0.dropLast(4) < $1.dropLast(4) }.map { folder.appendingPathComponent($0) }
  }

  /// Writes a new report file and deletes the oldest beyond `keep`.
  /// - Returns: The file written.
  package func write(_ report: NFS2015CrashReport, stamp: String) throws(LauncherError) -> URL {
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var url = folder.appendingPathComponent("\(Self.prefix)\(stamp).txt")
      var suffix = 1
      while FileManager.default.fileExists(atPath: url.path) {
        suffix += 1
        url = folder.appendingPathComponent("\(Self.prefix)\(stamp)-\(suffix).txt")
      }
      try Data(report.text.utf8).write(to: url, options: .withoutOverwriting)
      for old in reports().dropLast(Self.keep) { try FileManager.default.removeItem(at: old) }
      return url
    } catch {
      throw .operation("Could not write the crash report: \(error.localizedDescription)")
    }
  }

  /// The newest report, if it was written at or after `date`.
  package func latest(since date: Date) -> NFS2015CrashNotice? {
    guard let url = reports().last,
      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate,
      modified >= date,
      let text = try? BoundedFile.text(url, limit: NFS2015CrashReport.sizeLimit + 16)
    else { return nil }
    return NFS2015CrashNotice(path: url.path, headline: Self.headline(of: text))
  }

  /// The line after the `What happened` heading, or a plain fallback.
  static func headline(of text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let heading = lines.firstIndex(of: "== What happened =="), heading + 1 < lines.count
    else { return "see the report" }
    return String(lines[heading + 1].prefix(200))
  }
}
