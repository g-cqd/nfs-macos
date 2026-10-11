import Darwin
import Foundation

/// A read-only walk of a folder that never follows a symbolic link.
enum RuntimeTree {
  enum Kind: Equatable {
    case directory, file, link, other
  }

  struct Entry {
    /// The path relative to the walked root, without a leading `./`.
    let path: String
    let kind: Kind
    /// The permission bits (`st_mode & 0o7777`).
    let mode: mode_t
    let size: Int64
  }

  /// The kind, mode and size of `path`, or nil when nothing is there.
  static func lstatEntry(_ path: String, relative: String = "") throws(HubError) -> Entry? {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT || errno == ENOTDIR { return nil }
      throw posixFailure("lstat", path)
    }
    let kind: Kind
    switch info.st_mode & S_IFMT {
    case S_IFDIR: kind = .directory
    case S_IFREG: kind = .file
    case S_IFLNK: kind = .link
    default: kind = .other
    }
    return Entry(path: relative, kind: kind, mode: info.st_mode & 0o7777, size: Int64(info.st_size))
  }

  /// Every entry under `root` (not `root` itself), each directory before what it holds, siblings
  /// in name order.
  /// - Throws: `.io` when a folder cannot be listed.
  /// - Complexity: O(n log n) in the number of entries.
  static func entries(under root: String) throws(HubError) -> [Entry] {
    var result: [Entry] = []
    var pending: [String] = [""]
    while let directory = pending.popLast() {
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(
          atPath: directory.isEmpty ? root : root + "/" + directory
        ).sorted()
      } catch {
        throw .io(
          "Cannot list \(directory.isEmpty ? root : root + "/" + directory): \(error.localizedDescription)"
        )
      }
      var subdirectories: [String] = []
      for name in names {
        let relative = directory.isEmpty ? name : directory + "/" + name
        guard let entry = try lstatEntry(root + "/" + relative, relative: relative) else {
          throw .io("\(root + "/" + relative) vanished while it was listed.")
        }
        result.append(entry)
        if entry.kind == .directory { subdirectories.append(relative) }
      }
      // Reversed so the stack pops them in name order.
      pending.append(contentsOf: subdirectories.reversed())
    }
    return result
  }
}
