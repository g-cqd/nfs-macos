import Darwin
import Foundation

/// Excludes other app copies from the same writable installation.
package enum SessionLock {
  /// Holds a nonblocking process advisory lock for the entire body, releasing it on every exit.
  /// - Note: This lock coordinates processes; an in-memory Mutex cannot replace it.
  package static func withLock<T>(at url: URL, body: () throws -> T) throws -> T {
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw LauncherError.operation("Cannot open the session lock (\(errno)).")
    }
    defer {
      if close(descriptor) != 0 { print("Could not close the session lock (\(errno)).") }
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK { throw LauncherError.alreadyRunning }
      throw LauncherError.operation("Cannot lock the player folder (\(errno)).")
    }
    defer {
      // A child can briefly inherit this open-file description during process creation.
      if flock(descriptor, LOCK_UN) != 0 { print("Could not release the session lock (\(errno)).") }
    }
    return try body()
  }
}
