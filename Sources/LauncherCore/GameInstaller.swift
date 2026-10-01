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
  /// - Parameter source: An installed PC folder to verify and copy; nil retains the current origin.
  /// - Parameter initializePrefix: Initializes the unpublished prefix; must stop its Wine server before returning.
  /// - Returns: The verified generation's working directory.
  /// - Throws: A preparation failure; existing saves and the active generation remain available.
  /// - Complexity: O(payload bytes) for a new generation, O(1) for an existing generation.
  package func prepare(importing source: URL? = nil, initializePrefix: (URL) throws -> Void)
    throws(LauncherError) -> URL
  {
    do {
      try manifest.validate()
      guard manifest.kind == paths.kind else {
        throw LauncherError.operation("The game manifest belongs to a different app.")
      }
      guard manifest.kind.copiesGameData else {
        // A referencing app never republishes game bytes; ReferencedInstall owns that contract.
        throw LauncherError.operation(
          "This app runs the player's own installation and publishes no copy of it.")
      }
      try files.createDirectory(at: paths.support, withIntermediateDirectories: true)
      let current = try currentGeneration()
      if let current, source == nil, current.metadata.bundleVersion == manifest.version {
        guard
          files.fileExists(atPath: current.game.appendingPathComponent(paths.kind.executable).path),
          files.fileExists(atPath: paths.prefix.path), files.fileExists(atPath: paths.saves.path)
        else {
          throw LauncherError.operation(
            "Player data is incomplete. Keep this folder and check the session log.")
        }
        return current.game
      }
      let originalData = source ?? (current?.metadata.imported == true ? current?.game : nil)
      if let originalData {
        let values = try originalData.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard originalData.isFileURL, values.isDirectory == true, values.isSymbolicLink != true
        else {
          throw LauncherError.operation(
            "Select the matching installed PC game folder, without symbolic links.")
        }
      }
      let origin = originalData?.standardizedFileURL.resolvingSymlinksInPath()
      let version = origin == nil ? manifest.version : "import-" + UUID().uuidString
      let plan = try plan(origin: origin, isNewSource: source != nil, current: current)
      let metadata = GameGeneration(
        bundleVersion: manifest.version, imported: origin != nil, installation: plan.installation)
      if !files.fileExists(atPath: paths.data.path) {
        try initialize(
          version: version, originalData: origin, metadata: metadata, plan: plan, initializePrefix)
      } else {
        guard files.fileExists(atPath: paths.prefix.path),
          files.fileExists(atPath: paths.saves.path)
        else {
          throw LauncherError.operation(
            "Player data is incomplete. Keep this folder and check the session log.")
        }
        try updateGeneration(version: version, originalData: origin, metadata: metadata, plan: plan)
      }
      return paths.game(version: version)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not prepare the game: \(error.localizedDescription)")
    }
  }

  /// The files one generation is built from, and what is recorded about the installation they came from.
  private struct Plan {
    let files: [ManifestFile]
    let installation: InstalledGame?
    /// The player's own files, when recognised at import time; saved so an app update can verify them.
    let inventory: [ManifestFile]?
  }

  /// Fixed-manifest games copy their manifest. Import-only games recognise the selected folder first,
  /// then reuse the saved inventory when an app update re-verifies the active imported copy.
  private func plan(
    origin: URL?, isNewSource: Bool, current: (game: URL, metadata: GameGeneration)?
  ) throws -> Plan {
    guard let rules = manifest.importRules else {
      return Plan(files: manifest.gameFiles, installation: nil, inventory: nil)
    }
    guard let origin else {
      throw LauncherError.operation("Import your installed PC game folder first.")
    }
    let inventory: [ManifestFile]
    let installation: InstalledGame?
    if isNewSource {
      let scan = try InstallScanner.scan(origin, rules: rules)
      try scan.game.validate()
      inventory = scan.files
      installation = scan.game
    } else {
      guard let current else {
        throw LauncherError.operation("The imported game copy is missing. Import it again.")
      }
      inventory = try Self.storedInventory(of: current.game)
      installation = current.metadata.installation
    }
    let combined = BundleManifest(
      version: manifest.version, gameFiles: inventory + manifest.gameFiles, gameID: manifest.gameID)
    try combined.validate()
    return Plan(
      files: combined.gameFiles, installation: installation, inventory: inventory)
  }

  private static func storedInventory(of game: URL) throws -> [ManifestFile] {
    let url = game.deletingLastPathComponent().appendingPathComponent("inventory.json")
    // 30,000 entries at up to 512-byte paths stay well below this cap, so a saved inventory is always readable.
    let entries = try JSONDecoder().decode(
      [ManifestFile].self, from: BoundedFile.read(url, limit: 32 * 1024 * 1024))
    guard !entries.isEmpty, entries.count <= 30_000 else {
      throw LauncherError.operation("The imported game inventory is invalid. Import it again.")
    }
    for entry in entries { try ManifestFile.validate(path: entry.path) }
    return entries
  }

  /// What the active imported generation was recognised as, or nil for a fixed-manifest game.
  package static func installedGame(paths: AppPaths) -> InstalledGame? {
    let url = paths.data.appendingPathComponent("Current/origin.json")
    guard let data = try? BoundedFile.read(url, limit: 16_384) else { return nil }
    return (try? JSONDecoder().decode(GameGeneration.self, from: data))?.installation
  }

  private func initialize(
    version: String, originalData: URL?, metadata: GameGeneration, plan: Plan,
    _ initializePrefix: (URL) throws -> Void
  ) throws {
    let stage = paths.support.appendingPathComponent(".preparing")
    if files.fileExists(atPath: stage.path) { try files.removeItem(at: stage) }
    try files.createDirectory(at: stage, withIntermediateDirectories: false)
    do {
      let game = stage.appendingPathComponent("Versions/\(version)/Game")
      try copyVerifiedGame(to: game, originalData: originalData, metadata: metadata, plan: plan)
      try files.createDirectory(
        at: stage.appendingPathComponent("Saves"), withIntermediateDirectories: false)
      try files.createSymbolicLink(
        atPath: stage.appendingPathComponent("Current").path,
        withDestinationPath: "Versions/\(version)")
      let prefix = stage.appendingPathComponent("Prefix")
      try initializePrefix(prefix)
      try files.createDirectory(
        at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
      try files.createSymbolicLink(
        atPath: prefix.appendingPathComponent("drive_c/" + paths.kind.folder).path,
        withDestinationPath: "../../Current/Game")
      if paths.kind == .nfsmw {
        try files.createSymbolicLink(
          atPath: prefix.appendingPathComponent("drive_c/NFSMWSaves").path,
          withDestinationPath: "../../Saves")
      }
      try files.moveItem(at: stage, to: paths.data)
    } catch {
      do { try files.removeItem(at: stage) } catch {
        print("Could not remove incomplete initialization: \(error)")
      }
      throw error
    }
  }

  private func updateGeneration(
    version: String, originalData: URL?, metadata: GameGeneration, plan: Plan
  ) throws {
    let generation = paths.game(version: version).deletingLastPathComponent()
    let current = paths.data.appendingPathComponent("Current")
    if !files.fileExists(atPath: generation.path) {
      let stage = paths.data.appendingPathComponent("Versions/.preparing")
      if files.fileExists(atPath: stage.path) { try files.removeItem(at: stage) }
      do {
        try copyVerifiedGame(
          to: stage.appendingPathComponent("Game"), originalData: originalData, metadata: metadata,
          plan: plan)
        for name in paths.kind.preservedConfiguration {
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
      atPath: link.path, withDestinationPath: "Versions/\(version)")
    // Both paths share a parent; rename publishes one complete generation atomically.
    guard rename(link.path, current.path) == 0 else {
      let code = errno
      try files.removeItem(at: link)
      throw LauncherError.operation("Could not activate the new game generation (\(code)).")
    }
  }

  private func currentGeneration() throws -> (game: URL, metadata: GameGeneration)? {
    guard files.fileExists(atPath: paths.data.path) else { return nil }
    let target = try files.destinationOfSymbolicLink(
      atPath: paths.data.appendingPathComponent("Current").path)
    try ManifestFile.validate(path: target)
    let components = target.split(separator: "/")
    guard components.count == 2, components[0] == "Versions" else {
      throw LauncherError.operation("The active game generation is invalid.")
    }
    let name = String(components[1])
    let game = paths.game(version: name)
    guard game.resolvingSymlinksInPath().path == game.standardizedFileURL.path else {
      throw LauncherError.operation("The active game generation contains a symbolic link.")
    }
    let metadataURL = game.deletingLastPathComponent().appendingPathComponent("origin.json")
    let metadata: GameGeneration
    if files.fileExists(atPath: metadataURL.path) {
      metadata = try JSONDecoder().decode(
        GameGeneration.self, from: BoundedFile.read(metadataURL, limit: 16_384))
    } else {
      metadata = GameGeneration(bundleVersion: name, imported: false)
    }
    return (game, metadata)
  }

  private func copyVerifiedGame(
    to destination: URL, originalData: URL?, metadata: GameGeneration, plan: Plan
  ) throws {
    try files.createDirectory(at: destination, withIntermediateDirectories: true)
    for file in plan.files {
      let root =
        paths.kind.isOriginalData(file.path) ? (originalData ?? paths.template) : paths.template
      try VerifiedGameFile.copy(file, from: root, to: destination.appendingPathComponent(file.path))
    }
    if paths.kind == .cod4 {
      try files.createSymbolicLink(
        atPath: destination.appendingPathComponent("players").path,
        withDestinationPath: "../../../Saves")
    }
    let generation = destination.deletingLastPathComponent()
    if let inventory = plan.inventory {
      try JSONEncoder().encode(inventory).write(
        to: generation.appendingPathComponent("inventory.json"), options: .withoutOverwriting)
    }
    try JSONEncoder().encode(metadata).write(
      to: generation.appendingPathComponent("origin.json"), options: .withoutOverwriting)
  }
}
