import Darwin
import Foundation

/// Paths used by the Game Hub.
package struct HubPaths: Equatable, Sendable {
  package let root: URL

  package init(root: URL) {
    self.root = root
  }

  package static func standard() -> HubPaths {
    HubPaths(root: URL(fileURLWithPath: "/Volumes/ExT2/GameHub", isDirectory: true))
  }

  // MARK: - Computed paths

  package var hub: URL { root.appendingPathComponent("Hub", isDirectory: true) }
  package var config: URL { hub.appendingPathComponent("hub.json") }
  package var state: URL { hub.appendingPathComponent("State", isDirectory: true) }
  package var leases: URL { state.appendingPathComponent("leases", isDirectory: true) }
  package var settings: URL { state.appendingPathComponent("settings", isDirectory: true) }
  package var runs: URL { state.appendingPathComponent("runs", isDirectory: true) }
  package var ledger: URL { state.appendingPathComponent("ledger.jsonl") }
  package var session: URL { state.appendingPathComponent("session.json") }
  package var logs: URL { hub.appendingPathComponent("Logs", isDirectory: true) }
  package var home: URL { hub.appendingPathComponent("Home/Player", isDirectory: true) }
  package var temp: URL { hub.appendingPathComponent("Temp", isDirectory: true) }
  package var userKnowledge: URL { hub.appendingPathComponent("Knowledge", isDirectory: true) }
  package var runtimes: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }

  // MARK: - Runtime paths

  /// Returns the path to the runtime with the given id.
  /// - Throws: `.invalid` if the id does not match the required pattern.
  package func runtime(_ id: String) throws(HubError) -> URL {
    try validateRuntimeID(id)
    return runtimes.appendingPathComponent(id, isDirectory: true)
  }

  /// Returns the path to the manifest for the runtime with the given id.
  /// - Throws: `.invalid` if the id does not match the required pattern.
  package func runtimeManifest(_ id: String) throws(HubError) -> URL {
    try validateRuntimeID(id)
    return runtimes.appendingPathComponent("\(id).manifest")
  }

  /// Returns the path to the helpers directory for the runtime with the given id.
  /// - Throws: `.invalid` if the id does not match the required pattern.
  package func helpers(_ id: String) throws(HubError) -> URL {
    try validateRuntimeID(id)
    return runtimes.appendingPathComponent("\(id)-helpers", isDirectory: true)
  }

  // MARK: - Private

  /// Validates that the runtime id matches the required pattern: `^[a-z0-9][a-z0-9-]{0,47}$`
  private func validateRuntimeID(_ id: String) throws(HubError) {
    let bytes = id.utf8
    guard bytes.count >= 1, bytes.count <= 48 else {
      throw .invalid("Runtime id must be 1 to 48 characters long.")
    }
    for (index, byte) in bytes.enumerated() {
      let isDigit = byte >= 0x30 && byte <= 0x39
      let isLowercase = byte >= 0x61 && byte <= 0x7A
      let isHyphen = byte == 0x2D
      let isValid = isLowercase || isDigit || (isHyphen && index > 0)
      guard isValid else {
        throw .invalid("Runtime id must match ^[a-z0-9][a-z0-9-]{0,47}$.")
      }
    }
  }

  // MARK: - Directory preparation

  /// Prepares the Hub directory tree. Creates directories if they don't exist.
  /// - Throws: `.volumeMissing` if the root does not exist as a directory.
  /// - Throws: `.unsafePath` if the root is a symlink.
  /// - Throws: `.io` for other file system errors.
  package func prepareTree() throws(HubError) {
    // B4: Check volume first
    if let v = Self.volumeRoot(of: root.path), !Self.isMounted(v) {
      throw .volumeMissing(v)
    }

    var info = stat()
    let result = lstat(root.path, &info)
    guard result == 0 else {
      throw .volumeMissing(root.path)
    }
    // Check that root is a directory (not a symlink)
    guard (info.st_mode & S_IFMT) == S_IFDIR else {
      throw .unsafePath("Root \(root.path) is not a directory or is a symlink.")
    }

    // S10: Create directories in dependency order
    let directories: [(URL, UInt16)] = [
      (hub, 0o755),
      (hub.appendingPathComponent("Home", isDirectory: true), 0o755),
      (home, 0o755),
      (state, 0o700),
      (leases, 0o700),
      (settings, 0o700),
      (runs, 0o700),
      (logs, 0o755),
      (temp, 0o755),
      (userKnowledge, 0o755),
    ]

    for (url, mode) in directories {
      try createDirectory(url, mode: mode)
    }
  }

  private func createDirectory(_ url: URL, mode: UInt16) throws(HubError) {
    let path = url.path
    var info = stat()
    if lstat(path, &info) == 0 {
      // S10: Existing entry must be a real directory (not symlink)
      guard (info.st_mode & S_IFMT) == S_IFDIR else {
        throw .unsafePath("Path \(path) exists but is not a directory.")
      }
      // S10: Tighten existing directory's mode
      if mode_t(info.st_mode & 0o777) != mode_t(mode) {
        guard chmod(path, mode_t(mode)) == 0 else { throw posixFailure("chmod", path) }
      }
      return
    }

    // S10: no recursion; callers create parents first, in dependency order.
    guard mkdir(path, mode_t(mode)) == 0 else {
      throw posixFailure("mkdir", path)
    }

    // S10: Ensure mode is set correctly (umask-independent)
    guard chmod(path, mode_t(mode)) == 0 else { throw posixFailure("chmod", path) }
  }

  // MARK: - Volume detection

  /// Returns the volume root (e.g., `/Volumes/ExT2`) for a path, or nil if the path is not on a mounted volume.
  package static func volumeRoot(of path: String) -> String? {
    guard path.starts(with: "/Volumes/") else { return nil }
    let components = path.dropFirst(9).split(separator: "/", maxSplits: 1)
    guard let volumeName = components.first else { return nil }
    return "/Volumes/" + volumeName
  }

  /// Checks if the volume at the given root is mounted.
  /// S11: Also requires that the path is a directory.
  package static func isMounted(_ volumeRoot: String) -> Bool {
    var volumeInfo = stat()
    var volumesInfo = stat()
    guard lstat(volumeRoot, &volumeInfo) == 0 else { return false }
    guard (volumeInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
    guard lstat("/Volumes", &volumesInfo) == 0 else { return false }
    // The volume is mounted if its device differs from /Volumes
    return volumeInfo.st_dev != volumesInfo.st_dev
  }
}
