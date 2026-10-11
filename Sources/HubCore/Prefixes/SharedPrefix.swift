import Darwin
import Foundation
import LauncherCore

/// A Wine prefix shared by multiple games.
package struct SharedPrefix: Equatable, Sendable {
  package let configured: URL
  package let resolved: URL
  package let hops: [URL]

  package init(configured: URL, resolved: URL, hops: [URL]) {
    self.configured = configured
    self.resolved = resolved
    self.hops = hops
  }

  // MARK: - Locating and validating

  /// Locates and validates a Wine prefix.
  package static func locate(_ path: String, allowedRoots: [URL]) throws(HubError) -> SharedPrefix {
    // 1. Validate path format
    guard path.starts(with: "/") else {
      throw .invalid("Prefix path must be absolute.")
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    for component in components {
      guard component != "." && component != ".." else {
        throw .invalid("Prefix path cannot contain . or .. components.")
      }
    }

    let configuredURL = URL(fileURLWithPath: path, isDirectory: true)

    // 2. Check volume before any filesystem access
    if let volumeRoot = HubPaths.volumeRoot(of: path) {
      guard HubPaths.isMounted(volumeRoot) else {
        throw .volumeMissing(volumeRoot)
      }
    }

    // B6: Canonicalize allowed roots with primary root first check
    guard let first = allowedRoots.first else {
      throw .unsafePath("primary allowed root missing")
    }
    if let v = HubPaths.volumeRoot(of: first.path), !HubPaths.isMounted(v) { throw .volumeMissing(v) }
    guard let primary = realPath(first.path) else {
      throw .unsafePath("primary allowed root missing")
    }

    var canonicalRoots: [String] = [primary]
    for root in allowedRoots.dropFirst() {
      // Skip non-primary roots whose volumeRoot is not mounted
      if let v = HubPaths.volumeRoot(of: root.path), !HubPaths.isMounted(v) {
        continue
      }
      if let canonical = realPath(root.path) {
        canonicalRoots.append(canonical)
      }
    }

    // B4: Check if PRIMARY allowed root lies under unmounted /Volumes
    if let volumeRoot = HubPaths.volumeRoot(of: primary), !HubPaths.isMounted(volumeRoot) {
      throw .volumeMissing(volumeRoot)
    }

    // S7: Resolve symlinks (exactly 8 links accepted, 9th link throws)
    var hops: [URL] = []
    var current = path
    var visited = Set<String>()

    for hopIndex in 0..<9 {
      // Check volume before following symlinks
      if let volumeRoot = HubPaths.volumeRoot(of: current) {
        guard HubPaths.isMounted(volumeRoot) else {
          throw .volumeMissing(volumeRoot)
        }
      }

      var info = stat()
      guard lstat(current, &info) == 0 else {
        throw .unsafePath("Cannot access \(current)")
      }

      // Check if it's a symlink
      guard (info.st_mode & S_IFMT) == S_IFLNK else {
        // Not a symlink, we're done
        break
      }

      // S7: Check for 9th hop - reject too many symlink hops
      if hopIndex >= 8 {
        throw .unsafePath("too many symlink hops")
      }

      // Check for loops
      guard !visited.contains(current) else {
        throw .unsafePath("symlink loop")
      }
      visited.insert(current)

      // Read the symlink
      var linkBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      let linkLength = readlink(current, &linkBuffer, linkBuffer.count - 1)
      guard linkLength > 0 else {
        throw posixFailure("readlink", current)
      }

      // S7: Validate UTF-8 readlink result
      let linkTarget: String
      if let decoded = String(bytes: linkBuffer.prefix(Int(linkLength)).map { UInt8(bitPattern: $0) }, encoding: .utf8) {
        linkTarget = decoded
      } else {
        throw .unsafePath("non-UTF8 symlink target")
      }

      // Resolve relative targets
      let target: String
      if linkTarget.starts(with: "/") {
        target = linkTarget
      } else {
        let parentPath = URL(fileURLWithPath: current).deletingLastPathComponent().path
        target = parentPath + "/" + linkTarget
      }

      hops.append(URL(fileURLWithPath: target, isDirectory: true))
      current = target
    }

    // 5. Resolve final path and validate it's within allowed roots
    guard let resolvedPath = realPath(current) else {
      throw .unsafePath("Cannot resolve \(current)")
    }

    // Check that resolved path is within the first allowed root
    guard isUnderRoot(resolvedPath, rootPath: primary) else {
      throw .unsafePath("Resolved path \(resolvedPath) is not under the primary allowed root.")
    }

    // B5: Check all hops are within allowed roots (with realpath of each hop's parent)
    // Every parent directory involved (the initial path's and each hop's OWN parent, not the
    // parent of what the hop resolves to) must independently be inside a canonical allowed root.
    let parentsToCheck = [path] + hops.map(\.path)
    for entry in parentsToCheck {
      let parentPath = URL(fileURLWithPath: entry).deletingLastPathComponent().path
      guard let parentResolved = realPath(parentPath) else {
        throw .unsafePath("Cannot resolve parent of \(entry)")
      }
      guard canonicalRoots.contains(where: { isUnderRoot(parentResolved, rootPath: $0) }) else {
        throw .unsafePath("Hop \(entry) is not under allowed roots.")
      }
    }

    // 6. Check for stale prefix copies
    let lastComponent = URL(fileURLWithPath: resolvedPath).lastPathComponent
    guard !lastComponent.starts(with: "Prefix.internal-old") else {
      throw .unsafePath("stale copy")
    }

    // 7. Validate the resolved directory
    var resolvedInfo = stat()
    guard lstat(resolvedPath, &resolvedInfo) == 0 else {
      throw .unsafePath("Cannot access resolved prefix: \(resolvedPath)")
    }

    // Must be a directory, not a symlink
    guard (resolvedInfo.st_mode & S_IFMT) == S_IFDIR else {
      throw .invalid("prefix incomplete: not a directory")
    }

    // Must be owned by the current user
    guard resolvedInfo.st_uid == getuid() else {
      throw .invalid("prefix incomplete: owned by another user")
    }

    // Check for required files and directories
    let systemRegPath = resolvedPath + "/system.reg"
    let userRegPath = resolvedPath + "/user.reg"
    let driveCPath = resolvedPath + "/drive_c"
    let dosdevicesPath = resolvedPath + "/dosdevices"

    for path in [systemRegPath, userRegPath] {
      var info = stat()
      guard lstat(path, &info) == 0 else {
        throw .invalid("prefix incomplete: missing \(URL(fileURLWithPath: path).lastPathComponent)")
      }
      guard (info.st_mode & S_IFMT) == S_IFREG else {
        throw .invalid("prefix incomplete: \(URL(fileURLWithPath: path).lastPathComponent) is not a regular file")
      }
    }

    // drive_c must be a real directory
    var driveCInfo = stat()
    guard lstat(driveCPath, &driveCInfo) == 0 else {
      throw .invalid("prefix incomplete: missing drive_c")
    }
    guard (driveCInfo.st_mode & S_IFMT) == S_IFDIR else {
      throw .invalid("prefix incomplete: drive_c is not a directory")
    }

    // dosdevices must exist and be a directory
    var dosdevicesInfo = stat()
    guard lstat(dosdevicesPath, &dosdevicesInfo) == 0 else {
      throw .invalid("prefix incomplete: missing dosdevices")
    }
    guard (dosdevicesInfo.st_mode & S_IFMT) == S_IFDIR else {
      throw .invalid("prefix incomplete: dosdevices is not a directory")
    }

    let resolvedURL = URL(fileURLWithPath: resolvedPath, isDirectory: true)
    return SharedPrefix(configured: configuredURL, resolved: resolvedURL, hops: hops)
  }

  // MARK: - Validation

  /// Detects problems in the prefix that can be repaired.
  /// S9: Results sorted by summary string for deterministic output.
  /// problems() must never stat a path under an unmounted volume.
  package func problems(runtime: URL?, drives: [String: String]) -> [PrefixProblem] {
    var result: [PrefixProblem] = []

    let dosdevicesPath = resolved.path + "/dosdevices"

    // B2: Validate and filter drives - exactly one char in "c"..."y"
    var validDrives: [String: String] = [:]
    for (letter, target) in drives {
      guard letter.count == 1, let char = letter.first, char >= "c" && char <= "y" else {
        continue // Skip invalid drive letters
      }
      // B2: c only with target "../drive_c"
      if letter == "c" {
        guard target == "../drive_c" else { continue }
      }
      validDrives[letter] = target
    }

    // Check c: drive
    let cDrivePath = dosdevicesPath + "/c:"
    let cDriveTarget = "../drive_c"
    var cInfo = stat()
    if lstat(cDrivePath, &cInfo) == 0 {
      if (cInfo.st_mode & S_IFMT) == S_IFLNK {
        // Read the link
        if let actual = Self.readLink(cDrivePath) {
          if actual != cDriveTarget {
            result.append(.cDrive(actual: actual))
          }
        } else {
          result.append(.cDrive(actual: nil))
        }
      } else {
        result.append(.cDrive(actual: "not a symlink"))
      }
    } else {
      result.append(.cDrive(actual: nil))
    }

    // Check declared drives
    for (letter, expectedTarget) in validDrives {
      let drivePath = dosdevicesPath + "/\(letter):"
      var driveInfo = stat()
      if lstat(drivePath, &driveInfo) == 0 {
        if (driveInfo.st_mode & S_IFMT) == S_IFLNK {
          if let actual = Self.readLink(drivePath) {
            if actual != expectedTarget {
              result.append(.driveTarget(letter, actual: actual, expected: expectedTarget))
            } else {
              // B3: Check if the link target is safe (includes volume mount check)
              if !Self.isSafeDriveTarget(actual) {
                result.append(.driveUnreachable(letter, target: actual))
              }
            }
          }
        } else {
          // Not a symlink - check if the target is safe
          if !Self.isSafeDriveTarget(expectedTarget) {
            result.append(.driveUnreachable(letter, target: expectedTarget))
          }
        }
      } else {
        result.append(.missingDrive(letter))
      }
    }

    // Check .update-timestamp if runtime is provided
    if let runtime {
      let timestampPath = resolved.path + "/.update-timestamp"
      var timestampInfo = stat()
      // S8: stamp = trimmed Int64 of .update-timestamp (nil if unreadable/non-integer)
      let stamp: Int64?
      if lstat(timestampPath, &timestampInfo) == 0 {
        if let timestampData = try? Data(contentsOf: URL(fileURLWithPath: timestampPath)),
           let timestampString = String(data: timestampData, encoding: .utf8) {
          stamp = Int64(timestampString.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
          stamp = nil
        }
      } else {
        stamp = nil
      }

      // S8: mt = stat(wine.inf).st_mtimespec.tv_sec (nil if fails or volumeRoot not mounted)
      let wineInfPath = runtime.path + "/share/wine/wine.inf"
      var wineInfInfo = stat()
      let mt: Int64?

      // Skip wine.inf stat if runtime's volumeRoot is not mounted
      if let v = HubPaths.volumeRoot(of: wineInfPath), !HubPaths.isMounted(v) {
        mt = nil
      } else if stat(wineInfPath, &wineInfInfo) == 0 {
        mt = Int64(wineInfInfo.st_mtimespec.tv_sec)
      } else {
        mt = nil
      }

      // S8: if stamp == nil || mt == nil || stamp != mt -> error
      if stamp == nil || mt == nil || stamp != mt {
        let stampStr = stamp.map(String.init)
        let mtStr = mt.map(String.init)
        result.append(.updateStamp(prefix: stampStr, runtime: mtStr))
      }
    }

    // S9: One sweep over dosdevices entries that end with ":" (letter validated), symlinks only, for driveUnreachable
    // S9: Skip relative link targets (they are validated separately, e.g., c: -> ../drive_c is validated by cDrive check)
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: dosdevicesPath) {
      for entry in entries {
        // Must end with ":"
        guard entry.hasSuffix(":") else { continue }

        let letter = String(entry.dropLast()) // Remove the ":"

        // B2: Validate letter - exactly one char in "c"..."y"
        guard letter.count == 1, let char = letter.first, char >= "c" && char <= "y" else {
          continue
        }

        let linkPath = dosdevicesPath + "/\(entry)"
        var info = stat()

        // Symlinks only
        guard lstat(linkPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else {
          continue
        }

        // Check if target exists
        guard let target = Self.readLink(linkPath) else { continue }

        // S9: Skip relative link targets (validated separately by cDrive check, etc.)
        guard target.starts(with: "/") else { continue }

        // Check if target is safe
        if !Self.isSafeDriveTarget(target) {
          // No double reports: check if already reported as driveTarget or cDrive
          let alreadyReported = result.contains {
            switch $0 {
            case .driveTarget(let l, _, _): return l == letter
            case .cDrive: return letter == "c"
            case .driveUnreachable(let l, _): return l == letter
            default: return false
            }
          }

          if !alreadyReported {
            result.append(.driveUnreachable(letter, target: target))
          }
        }
      }
    }

    // S9: Sort results by summary string for deterministic output
    result.sort { $0.summary < $1.summary }

    return result
  }

  // MARK: - Repair

  /// A step to repair a drive link.
  package struct RepairStep: Codable, Equatable, Sendable {
    package let letter: String
    package let target: String

    package init(letter: String, target: String) {
      self.letter = letter
      self.target = target
    }
  }

  /// Creates a plan to repair missing drive links.
  /// S9: Results sorted by letter for deterministic output.
  /// B2: Validates drive letters - exactly one char in "c"..."y"
  package func repairPlan(drives: [String: String]) -> [RepairStep] {
    var result: [RepairStep] = []

    let dosdevicesPath = resolved.path + "/dosdevices"

    // Check c: drive - only plan if drive_c exists
    let cDrivePath = dosdevicesPath + "/c:"
    var cInfo = stat()
    // S13: "missing" means lstat failed with errno == ENOENT only
    if lstat(cDrivePath, &cInfo) != 0 && errno == ENOENT {
      // c: is missing, check if drive_c exists
      let driveCPath = resolved.path + "/drive_c"
      var driveCInfo = stat()
      if lstat(driveCPath, &driveCInfo) == 0 {
        result.append(RepairStep(letter: "c", target: "../drive_c"))
      }
    }

    // B2: Validate and filter drives - exactly one char in "c"..."y"
    var validDrives: [(String, String)] = []
    for (letter, target) in drives {
      guard letter.count == 1, let char = letter.first, char >= "c" && char <= "y" else {
        continue // Skip invalid drive letters
      }
      // B2: c only with target "../drive_c"
      if letter == "c" {
        guard target == "../drive_c" else { continue }
      }
      validDrives.append((letter, target))
    }

    // Check declared drives - only plan if the target exists and is accessible
    for (letter, expectedTarget) in validDrives {
      let drivePath = dosdevicesPath + "/\(letter):"
      var driveInfo = stat()
      // S13: "missing" means lstat failed with errno == ENOENT only
      if lstat(drivePath, &driveInfo) != 0 && errno == ENOENT {
        // Drive is missing, check if target is safe (B3: isSafeDriveTarget)
        if Self.isSafeDriveTarget(expectedTarget) {
          result.append(RepairStep(letter: letter, target: expectedTarget))
        }
      }
    }

    // Sort by letter for deterministic output (S9)
    result.sort { $0.letter < $1.letter }

    return result
  }

  /// Executes repair steps.
  /// B2: Validates step letter and target before creating symlink
  /// non-c target must pass isSafeDriveTarget
  package func repair(_ steps: [RepairStep]) throws(HubError) {
    let dosdevicesPath = resolved.path + "/dosdevices"

    for step in steps {
      // B2: Validate letter (exactly one char in "c"..."y", c only with "../drive_c")
      guard step.letter.count == 1, let char = step.letter.first, char >= "c" && char <= "y" else {
        throw .unsafePath("invalid drive letter: \(step.letter)")
      }

      if step.letter == "c" {
        guard step.target == "../drive_c" else {
          throw .unsafePath("c: drive must target ../drive_c")
        }
      } else {
        // B2: non-c target must pass isSafeDriveTarget
        guard Self.isSafeDriveTarget(step.target) else {
          throw .unsafePath("unsafe drive target: \(step.target)")
        }
      }

      let linkPath = dosdevicesPath + "/\(step.letter):"

      // Re-check that the link is still missing
      var linkInfo = stat()
      // S13: "missing" means lstat failed with errno == ENOENT only
      if lstat(linkPath, &linkInfo) == 0 {
        // Link already exists, skip (never replace)
        continue
      }
      // Only plan to create if it's truly missing (ENOENT), not if another error occurred
      guard errno == ENOENT else {
        continue
      }

      // Create the symlink
      let result = symlink(step.target, linkPath)
      guard result == 0 else {
        // B2: Treat EEXIST as skip
        if errno == EEXIST {
          continue
        }
        throw posixFailure("symlink", linkPath)
      }
    }
  }

  /// Whether the server is running.
  package var serverRunning: Bool {
    PrefixActivity.serverIsRunning(prefix: resolved)
  }

  // MARK: - Private helpers

  private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func isUnderRoot(_ path: String, rootPath: String) -> Bool {
    if path == rootPath {
      return true
    }
    let withSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return path.starts(with: withSlash)
  }

  /// Reads a symlink target and returns it as a String, or nil if the read fails.
  private static func readLink(_ path: String) -> String? {
    var linkBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let linkLength = readlink(path, &linkBuffer, linkBuffer.count - 1)
    guard linkLength > 0 else { return nil }
    return String(bytes: linkBuffer.prefix(Int(linkLength)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
  }

  // B3: Helper for validating drive targets
  /// Validates a drive target: absolute path, no "." or "..", volume mounted if applicable,
  /// and must resolve to an existing directory.
  /// Order: absolute + no "."/".." components -> if volumeRoot(of: target) non-nil and !isMounted -> false (BEFORE realpath) -> realpath -> mount check on the real path -> stat is dir.
  package static func isSafeDriveTarget(_ target: String) -> Bool {
    // 1. Must be absolute
    guard target.starts(with: "/") else {
      return false
    }

    // 2. No "." or ".." components
    let components = target.split(separator: "/", omittingEmptySubsequences: true)
    for component in components {
      if component == "." || component == ".." {
        return false
      }
    }

    // 3. If target is under /Volumes (BEFORE realpath), check that the volume is mounted
    if let volumeRoot = HubPaths.volumeRoot(of: target) {
      guard HubPaths.isMounted(volumeRoot) else {
        return false
      }
    }

    // 4. realpath the target
    guard let realTarget = realPath(target) else {
      return false
    }

    // 5. If realpath result is under /Volumes, check that the volume is mounted
    if let volumeRoot = HubPaths.volumeRoot(of: realTarget) {
      guard HubPaths.isMounted(volumeRoot) else {
        return false
      }
    }

    // 6. Must be a directory
    var targetInfo = stat()
    guard stat(realTarget, &targetInfo) == 0 else {
      return false
    }

    guard (targetInfo.st_mode & S_IFMT) == S_IFDIR else {
      return false
    }

    return true
  }
}
