import Foundation

/// Recovers interrupted updates before another operation can inspect or change player data.
/// - Note: The caller must hold the session lock and exclude a running game.
package struct FileTransaction {
  private struct Original: Codable {
    let path: String
    let bytes: Data?
  }
  private let root: URL
  private var journal: URL { root.appendingPathComponent("configuration-transaction.json") }
  private let files = FileManager.default

  package init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

  package func recover() throws(LauncherError) {
    guard files.fileExists(atPath: journal.path) else { return }
    do {
      let originals = try JSONDecoder().decode(
        [Original].self, from: BoundedFile.read(journal, limit: 24_000_000))
      guard originals.count <= 256 else {
        throw LauncherError.operation("Invalid transaction journal.")
      }
      var targets: Set<String> = []
      for original in originals {
        let url = try checked(root.appendingPathComponent(original.path))
        guard targets.insert(url.path).inserted, original.bytes?.count ?? 0 <= 1_048_576 else {
          throw LauncherError.operation("Duplicate or oversized transaction entry.")
        }
      }
      for original in originals {
        let url = try checked(root.appendingPathComponent(original.path))
        guard original.bytes?.count ?? 0 <= 1_048_576 else {
          throw LauncherError.operation("Oversized transaction entry.")
        }
        try restore(original.bytes, at: url)
      }
      try files.removeItem(at: journal)
    } catch let error as LauncherError { throw error } catch {
      throw .operation(
        "Could not recover the previous configuration: \(error.localizedDescription)")
    }
  }

  /// Publishes all changes or restores originals; an interruption is rolled back by recover().
  package func apply(
    _ changes: [FileChange],
    write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
  ) throws(LauncherError) {
    try recover()
    guard changes.count <= 256 else { throw .operation("Too many files in one update.") }
    do {
      var originals: [Original] = []
      var targets: Set<String> = []
      var totalBytes = 0
      for change in changes {
        let url = try checked(change.url)
        guard targets.insert(url.path).inserted, change.bytes?.count ?? 0 <= 1_048_576 else {
          throw LauncherError.operation("Duplicate or oversized update target.")
        }
        let old = files.fileExists(atPath: url.path) ? try BoundedFile.read(url) : nil
        totalBytes += (old?.count ?? 0) + (change.bytes?.count ?? 0)
        guard totalBytes <= 16_000_000 else {
          throw LauncherError.operation("Update exceeds the size limit.")
        }
        originals.append(
          Original(path: String(url.path.dropFirst(root.path.count + 1)), bytes: old))
      }
      try JSONEncoder().encode(originals).write(to: journal, options: .atomic)
      do {
        for change in changes {
          let url = try checked(change.url)
          if let bytes = change.bytes {
            try files.createDirectory(
              at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(bytes, url)
          } else if files.fileExists(atPath: url.path) {
            try files.removeItem(at: url)
          }
        }
        try files.removeItem(at: journal)
      } catch {
        let failure = error.localizedDescription
        try recover()
        throw LauncherError.operation("The update was rolled back: \(failure)")
      }
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not update player data: \(error.localizedDescription)")
    }
  }

  private func checked(_ url: URL) throws(LauncherError) -> URL {
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    guard resolved.path.hasPrefix(root.path + "/"), resolved != journal else {
      throw .operation("Update target is outside the player folder.")
    }
    return resolved
  }

  private func restore(_ data: Data?, at url: URL) throws {
    if let data {
      try files.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } else if files.fileExists(atPath: url.path) {
      try files.removeItem(at: url)
    }
  }
}
