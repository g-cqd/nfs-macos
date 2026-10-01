import Foundation

/// Bounded traversal and copying of a player-owned folder tree (saves, settings, backups).
///
/// Links, special files, oversized files and unbounded trees are rejected before anything is copied,
/// so a damaged or hostile folder cannot make a backup or restore escape or exhaust the disk.
package enum BoundedTree {
  package struct Limits: Sendable {
    package let files: Int
    package let bytes: Int
    package let depth: Int
    package init(files: Int = 4096, bytes: Int = 512 * 1024 * 1024, depth: Int = 16) {
      self.files = files
      self.bytes = bytes
      self.depth = depth
    }
  }

  package struct Summary: Equatable, Sendable {
    package let files: [String]
    package let bytes: Int
  }

  /// Lists regular files as sorted relative paths. A missing root is an empty tree.
  package static func inventory(_ root: URL, limits: Limits = Limits()) throws(LauncherError)
    -> Summary
  {
    let files = FileManager.default
    guard files.fileExists(atPath: root.path) else { return Summary(files: [], bytes: 0) }
    let root = root.standardizedFileURL
    do {
      let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw LauncherError.operation("\(root.lastPathComponent) must be a real folder.")
      }
      var pending: [(url: URL, depth: Int, prefix: String)] = [(root, 0, "")]
      var result: [String] = []
      var bytes = 0
      while let (directory, depth, prefix) = pending.popLast() {
        guard depth < limits.depth else {
          throw LauncherError.operation("A player folder is nested too deeply.")
        }
        for entry in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
          let attributes = try entry.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
          ])
          guard attributes.isSymbolicLink != true else {
            throw LauncherError.operation("Links are not supported in player folders.")
          }
          if attributes.isDirectory == true {
            pending.append((entry, depth + 1, prefix + entry.lastPathComponent + "/"))
            continue
          }
          guard attributes.isRegularFile == true, let size = attributes.fileSize else {
            throw LauncherError.operation("A player folder contains an unsupported item.")
          }
          bytes += size
          guard result.count < limits.files, bytes <= limits.bytes else {
            throw LauncherError.operation("A player folder is larger than this app supports.")
          }
          // Built from names, not absolute paths: the system may report /private/var for /var.
          result.append(prefix + entry.lastPathComponent)
        }
      }
      return Summary(files: result.sorted(), bytes: bytes)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not read \(root.lastPathComponent): \(error.localizedDescription)")
    }
  }

  /// Copies a tree to a new destination; a failed copy leaves no partial destination behind.
  @discardableResult
  package static func copy(_ source: URL, to destination: URL, limits: Limits = Limits())
    throws(LauncherError) -> Summary
  {
    let summary = try inventory(source, limits: limits)
    let files = FileManager.default
    guard !files.fileExists(atPath: destination.path),
      !destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/")
    else { throw .operation("Choose a new destination outside the source folder.") }
    do {
      try files.createDirectory(at: destination, withIntermediateDirectories: true)
      for relative in summary.files {
        let target = destination.appendingPathComponent(relative)
        try files.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: source.appendingPathComponent(relative), to: target)
      }
      guard try inventory(destination, limits: limits) == summary else {
        throw LauncherError.operation("The copy does not match its source.")
      }
      return summary
    } catch {
      do { try files.removeItem(at: destination) } catch {
        print("Could not remove incomplete copy: \(error)")
      }
      if let error = error as? LauncherError { throw error }
      throw .operation("Could not copy \(source.lastPathComponent): \(error.localizedDescription)")
    }
  }
}
