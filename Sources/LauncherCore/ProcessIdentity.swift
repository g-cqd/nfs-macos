import Darwin
import Foundation

/// PID plus kernel start time distinguishes a surviving child from PID reuse.
struct ProcessIdentity: Codable, Equatable {
  let pid: Int32
  let seconds: UInt64
  let microseconds: UInt64

  static func read(pid: Int32) throws(LauncherError) -> Self? {
    guard pid > 0 else { throw .operation("Invalid game process identifier.") }
    var info = proc_bsdinfo()
    // The kernel writes exactly one initialized proc_bsdinfo during this nonescaping borrow.
    let count = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
    }
    guard count == MemoryLayout<proc_bsdinfo>.size else {
      if count == 0 && errno == ESRCH { return nil }
      throw .operation("Cannot check the existing game process (\(errno)).")
    }
    return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
  }
}
