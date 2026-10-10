import Darwin
import Foundation

/// A failed system call as a `HubError.io`, naming the action, the path and the system's reason.
/// Call it directly after the failing call so `errno` is still the call's own.
func posixFailure(_ action: String, _ path: String) -> HubError {
  let code = errno
  return .io("\(action) failed for \(path): \(String(cString: strerror(code)))")
}

/// The human-readable text of a `HubError`, for composing a message that wraps another error.
func text(of error: HubError) -> String {
  switch error {
  case .invalid(let message), .unsafePath(let message), .io(let message): message
  case .belowFloor(let needed, let free, let floor):
    "Needs \(needed) bytes with \(free) free and a floor of \(floor)."
  }
}

/// Path rules shared by the planner, the builder and the remover. Every function is pure except
/// ``realPath(_:)``, which asks the file system.
enum InstancePaths {
  /// Splits `path` on `/` into its components, dropping or rejecting empty ones.
  /// - Parameters:
  ///   - path: A prefix-relative path from a recipe or a plan entry.
  ///   - subject: What the path is, for the error message.
  ///   - dropEmpty: `true` for recipe paths (`a//b/` means `a/b`); `false` for plan entries, whose
  ///     paths must already be exact.
  ///   - escapeIsUnsafe: Throw `.unsafePath` instead of `.invalid`.
  /// - Throws: When the path holds a NUL, is absolute, has a `.` or `..` component, has an
  ///   empty component it may not drop, or has no component at all.
  /// - Complexity: O(n) in the length of `path`.
  static func components(
    _ path: String, subject: String, dropEmpty: Bool, escapeIsUnsafe: Bool = false
  ) throws(HubError) -> [String] {
    func failure(_ reason: String) -> HubError {
      let message = "\(subject) '\(path)' \(reason)."
      return escapeIsUnsafe ? .unsafePath(message) : .invalid(message)
    }
    guard !path.utf8.contains(0) else { throw failure("contains a NUL byte") }
    guard path.utf8.first != 0x2F else { throw failure("is absolute") }
    var result: [String] = []
    for part in path.utf8.split(separator: 0x2F, omittingEmptySubsequences: false) {
      let component = String(decoding: part, as: UTF8.self)
      if component.isEmpty {
        if dropEmpty { continue }
        throw failure("has an empty component")
      }
      guard component != ".", component != ".." else {
        throw failure("has a '.' or '..' component")
      }
      result.append(component)
    }
    guard !result.isEmpty else { throw failure("names nothing") }
    return result
  }

  /// The non-empty components of an absolute path, with `.` and `..` resolved by text alone
  /// (a `..` at the root stays at the root). Symlinks are not consulted.
  static func lexical(_ absolutePath: String) -> [String] {
    var result: [String] = []
    for part in absolutePath.utf8.split(separator: 0x2F) {
      let component = String(decoding: part, as: UTF8.self)
      if component == "." { continue }
      if component == ".." {
        _ = result.popLast()
      } else {
        result.append(component)
      }
    }
    return result
  }

  /// Whether `roots` is a leading run of `path`, comparing whole components.
  static func isUnder(_ path: [String], roots: [[String]]) -> Bool {
    roots.contains { path.starts(with: $0) }
  }

  /// `path` with every symlink resolved by the system, or `nil` when it cannot be resolved.
  static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

/// The advisory lock that serializes everything that creates or deletes instance folders.
///
/// It is an `flock` on `<instances>/.lock`, so the system drops it when the process dies and a
/// crashed build can never leave the Hub locked. The type is `~Copyable` and closes its descriptor
/// in `deinit`, so the descriptor is closed exactly once however the holder is left.
package struct InstanceLock: ~Copyable {
  private let descriptor: Int32

  private init(descriptor: Int32) { self.descriptor = descriptor }

  /// Takes the lock, retrying for about 300 ms while another holder has it.
  ///
  /// This is the one bounded wait in the engine. The lock is shared with other processes, and a
  /// descriptor that a `posix_spawn` child has briefly inherited keeps the lock alive for a few
  /// milliseconds after its owner closed it, so a single refusal does not mean a real build is
  /// running. Six tries 50 ms apart absorb that; a longer holder is refused.
  /// - Throws: `.io` when another build or removal still holds the lock after the retries, or the
  ///   lock file cannot be opened (a symlink at `.lock` is refused, never followed).
  /// - Complexity: O(1); waits at most about 300 ms.
  package static func acquire(instancesPath: String) throws(HubError) -> InstanceLock {
    let path = instancesPath + "/.lock"
    let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw posixFailure("Opening the instance lock", path) }
    var retries = 0
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      guard code == EWOULDBLOCK, retries < 6 else {
        errno = code
        let failure = posixFailure("Locking the instances folder", path)
        close(descriptor)
        throw code == EWOULDBLOCK
          ? .io("Another instance is being built or removed. Try again when it has finished.")
          : failure
      }
      retries += 1
      usleep(50_000)
    }
    return InstanceLock(descriptor: descriptor)
  }

  /// Runs `body` while holding the lock, then releases it; the lock is also released when `body`
  /// throws. Lock-free callers get the retry and refusal of ``acquire(instancesPath:)``.
  package static func withLock<Result>(
    instancesPath: String, _ body: () throws(HubError) -> Result
  ) throws(HubError) -> Result {
    let lock = try acquire(instancesPath: instancesPath)
    let result = try body()
    lock.release()
    return result
  }

  /// Whether the descriptor is closed in a spawned child (`FD_CLOEXEC`).
  package var closesOnExec: Bool { fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0 }

  /// Releases the lock; the consumed value's `deinit` closes the descriptor.
  package consuming func release() {}

  deinit { close(descriptor) }
}

/// Deletes a folder tree without ever following a symlink or leaving the volume.
package enum TreeDeleter {
  /// Removes `path` and everything under it. A symlink is removed as a link; its target is never
  /// touched. Directories are made readable and writable by the owner first, so a read-only
  /// folder inside the tree does not stop the deletion. Stops at the first failure.
  /// - Throws: `.io` naming the path that could not be removed.
  /// - Complexity: O(n) in the number of entries under `path`.
  package static func remove(path: String) throws(HubError) {
    guard let rootPath = strdup(path) else { throw .io("Out of memory deleting \(path).") }
    defer { free(rootPath) }
    var argv: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
    guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
      throw posixFailure("Opening the folder for deletion", path)
    }
    defer { fts_close(stream) }
    errno = 0
    while let entry = fts_read(stream) {
      let entryPath = String(cString: entry.pointee.fts_path)
      switch Int32(entry.pointee.fts_info) {
      case FTS_D:
        let mode = entry.pointee.fts_statp.pointee.st_mode & 0o7777
        guard chmod(entryPath, mode | 0o700) == 0 else {
          throw posixFailure("Making the folder deletable", entryPath)
        }
      case FTS_DP:
        guard rmdir(entryPath) == 0 else { throw posixFailure("Removing the folder", entryPath) }
      case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
        guard unlink(entryPath) == 0 else { throw posixFailure("Removing the file", entryPath) }
      default:
        let reason = String(cString: strerror(entry.pointee.fts_errno))
        throw .io("Could not read \(entryPath) for deletion: \(reason)")
      }
      errno = 0
    }
    guard errno == 0 else { throw posixFailure("Walking the folder for deletion", path) }
  }
}
