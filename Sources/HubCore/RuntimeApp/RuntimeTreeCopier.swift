import Darwin
import Foundation

/// Copies a folder tree file by file with `copyfile(3)`: data, mode, times, extended attributes
/// and ACLs. A file is cloned when the two folders share an APFS volume and byte-copied when
/// they do not. Symbolic links are copied as links and never followed. No file is modified.
enum RuntimeTreeCopier {
  /// A copied folder and the permission bits it had in the source.
  struct FolderMode {
    let path: String
    let mode: mode_t
  }

  /// Copies the contents of `source` into the existing folder `destination`.
  ///
  /// Every copied folder, `destination` included, keeps the owner's read, write and search bits
  /// until ``restore(_:)`` runs, so a failure can always be cleaned up.
  /// - Returns: The folders with their exact source modes, for ``restore(_:)``.
  /// - Throws: `.io` for a failed call, `.invalid` for a file that is neither regular, a folder
  ///   nor a link.
  /// - Complexity: O(total bytes) when the copy is not cloned.
  static func copy(contentsOf source: String, to destination: String) throws(HubError)
    -> [FolderMode]
  {
    guard let root = try RuntimeTree.lstatEntry(source), root.kind == .directory else {
      throw .invalid("\(source) is not a folder.")
    }
    var folders = [FolderMode(path: destination, mode: root.mode)]
    for entry in try RuntimeTree.entries(under: source) {
      let from = source + "/" + entry.path
      let to = destination + "/" + entry.path
      switch entry.kind {
      case .directory:
        // Owner-only while it fills; the source's bits are applied at the end.
        guard mkdir(to, 0o700) == 0 else { throw posixFailure("mkdir", to) }
        folders.append(FolderMode(path: to, mode: entry.mode))
      case .file:
        try copyFile(from: from, to: to)
      case .link:
        let target: String
        do {
          target = try FileManager.default.destinationOfSymbolicLink(atPath: from)
        } catch {
          throw .io("Cannot read the link \(from): \(error.localizedDescription)")
        }
        guard symlink(target, to) == 0 else { throw posixFailure("symlink", to) }
      case .other:
        throw .invalid("\(from) is not a regular file, folder or link.")
      }
    }
    for folder in folders.reversed() {
      guard chmod(folder.path, folder.mode | 0o700) == 0 else {
        throw posixFailure("chmod", folder.path)
      }
    }
    return folders
  }

  /// Gives every folder the exact mode it had in the source, children before parents.
  static func restore(_ folders: [FolderMode]) throws(HubError) {
    for folder in folders.reversed() {
      guard chmod(folder.path, folder.mode) == 0 else { throw posixFailure("chmod", folder.path) }
    }
  }

  /// Gives every folder under `root`, and `root` itself, the owner's read, write and search bits,
  /// so `root` can be removed. Best effort: what cannot be changed fails again at the removal.
  static func makeRemovable(_ root: String) {
    var pending = [root]
    while let directory = pending.popLast() {
      var info = stat()
      guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
      _ = chmod(directory, (info.st_mode & 0o7777) | 0o700)
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        continue
      }
      pending.append(contentsOf: names.map { directory + "/" + $0 })
    }
  }

  /// Copies one regular file; the destination must not exist.
  static func copyFile(from: String, to: String) throws(HubError) {
    let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
    guard copyfile(from, to, nil, flags) == 0 else { throw posixFailure("copyfile", from) }
  }
}
