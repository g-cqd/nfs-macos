import Darwin
import Foundation

/// The size of a volume, in bytes.
package struct DataStoreCapacity: Equatable, Sendable {
  /// Bytes available to this user.
  package var free: Int64
  package var total: Int64

  package init(free: Int64, total: Int64) {
    self.free = free
    self.total = total
  }
}

/// What the Hub asks of the volume under a path. Injected so tests can simulate an unplugged
/// drive, a case-insensitive volume, a read-only volume or a second volume without any of them.
///
/// For a path that does not exist yet, every answer is that of the nearest existing ancestor,
/// because that is the volume the folder would be created on.
package protocol DataStoreCapabilities: Sendable {
  /// Whether the volume at `volumeRoot` (such as `/Volumes/ExT2`) is mounted.
  func isMounted(volumeRoot: String) -> Bool
  /// Whether the volume holding `path` tells `Readme` from `readme` (APFS case-sensitive).
  /// False when the answer cannot be read: the Hub refuses what it cannot confirm.
  func isCaseSensitive(at path: String) -> Bool
  /// Whether this user may create files in the folder holding `path`.
  func isWritable(at path: String) -> Bool
  /// Free and total bytes of the volume holding `path`; nil when it cannot be read.
  func capacity(at path: String) -> DataStoreCapacity?
  /// The device number of the volume holding `path`; nil when it cannot be read.
  func device(of path: String) -> Int64?
}

/// The capabilities of the volumes of this Mac.
package struct LiveDataStoreCapabilities: DataStoreCapabilities {
  package init() {}

  package func isMounted(volumeRoot: String) -> Bool { HubPaths.isMounted(volumeRoot) }

  package func isCaseSensitive(at path: String) -> Bool {
    guard let existing = Self.nearestExisting(path) else { return false }
    return pathconf(existing, _PC_CASE_SENSITIVE) == 1
  }

  package func isWritable(at path: String) -> Bool {
    guard let existing = Self.nearestExisting(path) else { return false }
    return access(existing, W_OK) == 0
  }

  package func capacity(at path: String) -> DataStoreCapacity? {
    guard let existing = Self.nearestExisting(path) else { return nil }
    var info = statfs()
    guard statfs(existing, &info) == 0 else { return nil }
    let size = Int64(info.f_bsize)
    return DataStoreCapacity(free: Int64(info.f_bavail) * size, total: Int64(info.f_blocks) * size)
  }

  package func device(of path: String) -> Int64? {
    guard let existing = Self.nearestExisting(path) else { return nil }
    var info = stat()
    guard stat(existing, &info) == 0 else { return nil }
    return Int64(info.st_dev)
  }

  /// `path`, or its nearest ancestor that exists.
  /// - Complexity: O(d) system calls for d missing components.
  private static func nearestExisting(_ path: String) -> String? {
    var current = path
    while true {
      var info = stat()
      if stat(current, &info) == 0 { return current }
      guard errno == ENOENT || errno == ENOTDIR, current != "/" else { return nil }
      current = DatastorePath.parent(of: current)
    }
  }
}
