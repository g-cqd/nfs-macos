import Darwin
import Foundation

/// Reads free space of a volume.
package enum SpaceProbe {
  /// The bytes available to this user on the volume that holds `url`, or `nil` when unreadable.
  /// Uses `statfs` to read the available blocks and block size of the volume.
  /// - Complexity: O(1) system call.
  package static func freeBytes(at url: URL) -> Int64? {
    var st = statfs()
    guard statfs(url.path, &st) == 0 else { return nil }
    return Int64(st.f_bavail) * Int64(st.f_bsize)
  }
}
