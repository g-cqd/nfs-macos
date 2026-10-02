import Foundation

/// Creates the app's own Windows prefix once and seeds it with the game files the app carries.
///
/// A store-client game cannot use the generation scheme of `GameInstaller`: its client activates
/// and updates the installation in place, and the account session, the client's registry state and
/// the machine activation all live in the one prefix. So the packaged files are copied exactly
/// once, into the folder the game's own installer would have used, and from then on belong to the
/// player's prefix and to the store client. An app update never replaces them.
package struct PrefixSeed {
  /// What was seeded, kept beside the prefix so a later launch knows the preparation completed.
  package struct Record: Codable, Equatable, Sendable {
    package let bundleVersion: String
    package let gameRoot: String
    package let files: Int
    package let bytes: Int
  }

  /// Free space the preparation must leave on the player's volume.
  static let reserve = 1_000_000_000

  private let paths: AppPaths
  private let manifest: BundleManifest
  private let freeSpace: @Sendable (URL) -> Int?
  private let files = FileManager.default

  package init(
    paths: AppPaths, manifest: BundleManifest,
    freeSpace: @escaping @Sendable (URL) -> Int? = PrefixSeed.availableCapacity
  ) {
    self.paths = paths
    self.manifest = manifest
    self.freeSpace = freeSpace
  }

  /// The record written after a complete preparation.
  package var recordURL: URL { paths.data.appendingPathComponent("seed.json") }

  /// Whether the preparation completed on an earlier launch.
  package var isSeeded: Bool { files.fileExists(atPath: recordURL.path) }

  package static func availableCapacity(at url: URL) -> Int? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage.map { Int($0) }
  }

  /// Initializes a new prefix, copies every verified game file into it, and publishes both at once.
  ///
  /// Must run while holding the session lock, on the synchronous session helper.
  /// - Parameter initializePrefix: Builds the unpublished prefix, including its registry; it
  ///   must stop its Wine server before returning.
  /// - Returns: The published prefix. An already prepared prefix is returned untouched.
  /// - Throws: A preparation failure; nothing is published, and a retry starts clean.
  /// - Complexity: O(payload bytes) for the first launch, O(1) afterwards.
  package func prepare(initializePrefix: (URL) throws -> Void) throws(LauncherError) -> URL {
    do {
      try manifest.validate()
      guard manifest.kind == paths.kind, manifest.seedsPrefix, let plan = manifest.client else {
        throw LauncherError.operation("This app does not seed a Windows folder with its game.")
      }
      try files.createDirectory(at: paths.support, withIntermediateDirectories: true)
      if files.fileExists(atPath: paths.data.path) {
        guard isSeeded,
          files.fileExists(atPath: paths.prefix.appendingPathComponent("drive_c").path)
        else {
          throw LauncherError.operation(
            "Player data is incomplete. Keep this folder and check the session log.")
        }
        return paths.prefix
      }
      let total = manifest.gameFiles.reduce(0) { $0 + $1.size }
      try requireSpace(for: total)
      let stage = paths.support.appendingPathComponent(".preparing")
      if files.fileExists(atPath: stage.path) { try files.removeItem(at: stage) }
      try files.createDirectory(at: stage, withIntermediateDirectories: false)
      do {
        let prefix = stage.appendingPathComponent("Prefix")
        try initializePrefix(prefix)
        let game = prefix.appendingPathComponent("drive_c").appendingPathComponent(plan.gameRoot)
        try files.createDirectory(at: game, withIntermediateDirectories: true)
        for file in manifest.gameFiles {
          try VerifiedGameFile.copy(
            file, from: paths.template, to: game.appendingPathComponent(file.path))
        }
        let record = Record(
          bundleVersion: manifest.version, gameRoot: plan.gameRoot, files: manifest.gameFiles.count,
          bytes: total)
        try JSONEncoder().encode(record).write(
          to: stage.appendingPathComponent("seed.json"), options: .withoutOverwriting)
        try files.moveItem(at: stage, to: paths.data)
      } catch {
        do { try files.removeItem(at: stage) } catch {
          print("Could not remove incomplete preparation: \(error)")
        }
        throw error
      }
      return paths.prefix
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not prepare the game: \(error.localizedDescription)")
    }
  }

  /// A copy on the same APFS volume is a clone and needs almost no space; a copy from another
  /// volume needs the whole payload, so that is checked before the first byte is written.
  private func requireSpace(for payload: Int) throws {
    let needed = (try sharesVolume() ? 0 : payload) + Self.reserve
    if let available = freeSpace(paths.support), available < needed {
      throw LauncherError.operation(
        """
        There is not enough free space to prepare the game. It needs about \
        \((needed + 999_999_999) / 1_000_000_000) GB free on the disk that holds your \
        Library folder.
        """)
    }
  }

  /// Whether the packaged files and the player's folder are on one volume; unknown counts as no.
  private func sharesVolume() throws -> Bool {
    func identifier(of url: URL) throws -> NSObject? {
      var location = url
      while !files.fileExists(atPath: location.path), location.path != "/" {
        location.deleteLastPathComponent()
      }
      return try location.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        as? NSObject
    }
    guard let template = try identifier(of: paths.template),
      let support = try identifier(of: paths.support)
    else { return false }
    return template.isEqual(support)
  }
}
