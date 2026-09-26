import CryptoKit
import Darwin
import Foundation

/// Publishes verified working copies while leaving the prefix and saves intact on repeat launches.
package struct GameInstaller {
  private let paths: AppPaths
  private let manifest: BundleManifest
  private let files = FileManager.default

  package init(paths: AppPaths, manifest: BundleManifest) {
    self.paths = paths
    self.manifest = manifest
  }

  /// Must run while holding the session lock, on the synchronous session helper.
  /// - Parameter initializePrefix: Initializes the unpublished prefix; must stop its Wine server before returning.
  /// - Returns: The verified generation's working directory.
  /// - Throws: A preparation failure; existing saves and the active generation remain available.
  /// - Complexity: O(payload bytes) for a new generation, O(1) for an existing generation.
  package func prepare(initializePrefix: (URL) throws -> Void) throws(LauncherError) -> URL {
    do {
      try manifest.validate()
      try files.createDirectory(at: paths.support, withIntermediateDirectories: true)
      if !files.fileExists(atPath: paths.data.path) {
        try initialize(initializePrefix)
      } else {
        guard files.fileExists(atPath: paths.prefix.path),
          files.fileExists(atPath: paths.saves.path)
        else {
          throw LauncherError.operation(
            "Player data is incomplete. Keep this folder and check the session log.")
        }
        try updateGeneration()
      }
      return paths.game(version: manifest.version)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not prepare the game: \(error.localizedDescription)")
    }
  }

  private func initialize(_ initializePrefix: (URL) throws -> Void) throws {
    let stage = paths.support.appendingPathComponent(".preparing")
    if files.fileExists(atPath: stage.path) { try files.removeItem(at: stage) }
    try files.createDirectory(at: stage, withIntermediateDirectories: false)
    do {
      let game = stage.appendingPathComponent("Versions/\(manifest.version)/Game")
      try copyVerifiedGame(to: game)
      try files.createDirectory(
        at: stage.appendingPathComponent("Saves"), withIntermediateDirectories: false)
      try files.createSymbolicLink(
        atPath: stage.appendingPathComponent("Current").path,
        withDestinationPath: "Versions/\(manifest.version)")
      let prefix = stage.appendingPathComponent("Prefix")
      try initializePrefix(prefix)
      try files.createDirectory(
        at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
      try files.createSymbolicLink(
        atPath: prefix.appendingPathComponent("drive_c/NFSMW").path,
        withDestinationPath: "../../Current/Game")
      try files.createSymbolicLink(
        atPath: prefix.appendingPathComponent("drive_c/NFSMWSaves").path,
        withDestinationPath: "../../Saves")
      try files.moveItem(at: stage, to: paths.data)
    } catch {
      do { try files.removeItem(at: stage) } catch {
        print("Could not remove incomplete initialization: \(error)")
      }
      throw error
    }
  }

  private func updateGeneration() throws {
    let generation = paths.game(version: manifest.version).deletingLastPathComponent()
    let current = paths.data.appendingPathComponent("Current")
    let existingTarget = try files.destinationOfSymbolicLink(atPath: current.path)
    guard existingTarget.hasPrefix("Versions/"), existingTarget.split(separator: "/").count == 2
    else {
      throw LauncherError.operation("The active game generation is invalid.")
    }
    if existingTarget == "Versions/\(manifest.version)" {
      guard files.fileExists(atPath: generation.appendingPathComponent("Game/speed.exe").path)
      else {
        throw LauncherError.operation("The installed game executable is missing.")
      }
      return
    }
    if !files.fileExists(atPath: generation.path) {
      let stage = paths.data.appendingPathComponent("Versions/.preparing")
      if files.fileExists(atPath: stage.path) { try files.removeItem(at: stage) }
      do {
        try copyVerifiedGame(to: stage.appendingPathComponent("Game"))
        for name in [
          "mtld3d.conf", "scripts/NFS_XtendedInput.ini", "scripts/NFSMostWanted.WidescreenFix.ini",
          "scripts/XtendedInputMaps",
        ] {
          let previous = paths.currentGame.appendingPathComponent(name)
          guard files.fileExists(atPath: previous.path) else { continue }
          let destination = stage.appendingPathComponent("Game/\(name)")
          try files.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
          if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
          try files.copyItem(at: previous, to: destination)
        }
        try files.moveItem(at: stage, to: generation)
      } catch {
        if files.fileExists(atPath: stage.path) {
          do { try files.removeItem(at: stage) } catch {
            print("Could not remove incomplete generation: \(error)")
          }
        }
        throw error
      }
    }
    let link = paths.data.appendingPathComponent(".current-\(UUID().uuidString)")
    try files.createSymbolicLink(
      atPath: link.path, withDestinationPath: "Versions/\(manifest.version)")
    // Both paths share a parent; rename publishes one complete generation atomically.
    guard rename(link.path, current.path) == 0 else {
      let code = errno
      try files.removeItem(at: link)
      throw LauncherError.operation("Could not activate the new game generation (\(code)).")
    }
  }

  private func copyVerifiedGame(to destination: URL) throws {
    try files.createDirectory(at: destination, withIntermediateDirectories: true)
    for file in manifest.gameFiles {
      let source = paths.template.appendingPathComponent(file.path)
      let values = try source.resourceValues(forKeys: [
        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        values.fileSize == file.size,
        source.resolvingSymlinksInPath().path.hasPrefix(paths.template.path + "/")
      else {
        throw LauncherError.operation("Missing or invalid game file: \(file.path)")
      }
      let target = destination.appendingPathComponent(file.path)
      try files.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try files.copyItem(at: source, to: target)
      guard try digest(of: target) == file.sha256 else {
        throw LauncherError.operation("Game file verification failed: \(file.path)")
      }
    }
  }

  private func digest(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      do { try handle.close() } catch { print("Could not close verification input: \(error)") }
    }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
