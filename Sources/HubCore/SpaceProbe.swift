import Darwin
import Foundation

/// Reads free space of a volume.
package enum SpaceProbe {
  /// The bytes available to this user on the volume that holds `url`. When `url` does not exist
  /// yet (a fresh install has neither the Hub folder nor the instances folder), the nearest
  /// existing ancestor answers, because the folder will be created on that volume.
  /// - Returns: `nil` when the volume cannot be read, for example under a folder the user may not
  ///   search.
  /// - Complexity: O(d) system calls for d missing path components.
  package static func freeBytes(at url: URL) -> Int64? {
    var path = url.standardizedFileURL.path
    while true {
      var info = statfs()
      if statfs(path, &info) == 0 {
        return Int64(info.f_bavail) * Int64(info.f_bsize)
      }
      guard errno == ENOENT || errno == ENOTDIR, path != "/" else { return nil }
      path = (path as NSString).deletingLastPathComponent
      if path.isEmpty { path = "/" }
    }
  }
}
