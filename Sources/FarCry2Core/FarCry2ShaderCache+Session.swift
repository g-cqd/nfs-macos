import Foundation
import LauncherCore

/// How a launch starts, for the session log.
package enum ShaderCacheLaunch: Equatable, Sendable {
  case unavailable
  case cold
  case warm(bytes: Int)
}

/// What taking the cache back after the game did.
package enum ShaderCacheHarvest: Equatable, Sendable {
  /// No cache of this build was in the game folder.
  case none
  /// The game folder held a cache that was not this build's, or an unusable one, and it was removed.
  case discarded
  /// The game wrote nothing worth keeping; the saved cache is unchanged.
  case unchanged
  case saved(bytes: Int)
  /// The result exceeded the size limit; the saved cache is unchanged.
  case tooLarge
}

extension FarCry2ShaderCache {
  private var tidyNames: Set<String> {
    [Self.cacheName, Self.markerName, Self.cacheName + ".lock"]
  }

  private func workingFile(_ game: URL) -> URL {
    game.appendingPathComponent("bin").appendingPathComponent(Self.cacheName)
  }

  private func markerFile(_ game: URL) -> URL {
    game.appendingPathComponent("bin").appendingPathComponent(Self.markerName)
  }

  /// Puts the saved cache where mtld3d reads it, after taking back anything a crashed session left.
  /// - Parameter game: The active generation's game folder, which has a `bin` folder.
  package func prepare(game: URL) throws(LauncherError) -> ShaderCacheLaunch {
    guard let key else { return .unavailable }
    _ = try harvest(game: game)
    let identifier = key.identifier
    guard fileType(game.appendingPathComponent("bin")) == .typeDirectory else {
      throw .operation("The game has no bin folder to hold the shader cache.")
    }
    let saved = try savedCache(identifier)
    if saved == nil { try remove(cacheFile(identifier)) }
    try guarded("place the shader cache") {
      if let saved { try saved.write(to: workingFile(game), options: .atomic) }
      try Data((identifier + "\n").utf8).write(to: markerFile(game), options: .atomic)
    }
    return saved.map { .warm(bytes: $0.count) } ?? .cold
  }

  /// Takes the cache mtld3d wrote back into the player folder and empties the game folder of it.
  ///
  /// Call after the game exits, and again at the start of every session so a crash loses nothing.
  /// The game's file replaces the saved one: mtld3d starts from the saved cache, appends, and
  /// rewrites it compactly, so it is the newer superset. An empty or foreign file never replaces it.
  @discardableResult
  package func harvest(game: URL) throws(LauncherError) -> ShaderCacheHarvest {
    guard let key, let header = key.header else { return .none }
    let working = workingFile(game)
    var outcome = ShaderCacheHarvest.none
    if let type = fileType(working) {
      if readMarker(game) == key.identifier, type == .typeRegular {
        outcome = try keep(working, header: header)
      } else {
        outcome = .discarded
      }
    }
    try tidy(game)
    return outcome
  }

  private func keep(_ working: URL, header: ShaderCacheFormat.Header) throws(LauncherError)
    -> ShaderCacheHarvest
  {
    let size = try guarded("measure the shader cache") {
      try working.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
    guard size <= limit else { return .tooLarge }
    guard let data = try readFile(working, limit: limit),
      let layout = ShaderCacheFormat.scan(data), layout.header == header
    else { return .discarded }
    guard layout.hasRecords else { return .unchanged }
    let kept = ShaderCacheFormat.trimmed(data, layout: layout)
    try save(kept)
    return .saved(bytes: kept.count)
  }

  /// The build id the marker names; nil when it is missing, not a regular file or malformed, so a
  /// planted link or odd file is never followed and simply fails to vouch for the cache.
  private func readMarker(_ game: URL) -> String? {
    let url = markerFile(game)
    guard fileType(url) == .typeRegular, let data = try? BoundedFile.read(url, limit: 64),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return Self.isIdentifier(name) ? name : nil
  }

  /// Removes the cache, its marker, its lock and any compaction leftovers from the game's `bin`.
  private func tidy(_ game: URL) throws(LauncherError) {
    let bin = game.appendingPathComponent("bin")
    guard fileType(bin) == .typeDirectory else { return }
    let names = try guarded("list the game's bin folder") {
      try files.contentsOfDirectory(atPath: bin.path)
    }
    for name in names
    where tidyNames.contains(name)
      || (name.hasPrefix(Self.cacheName + ".") && name.hasSuffix(".tmp"))
    {
      try remove(bin.appendingPathComponent(name))
    }
  }

  /// Deletes every saved cache, and the game folder's copy when given.
  /// - Returns: The bytes removed.
  @discardableResult
  package func reset(game: URL?) throws(LauncherError) -> Int {
    var removed = 0
    if let game { try tidy(game) }
    guard fileType(root) != nil else { return 0 }
    guard fileType(root) == .typeDirectory else {
      throw .operation("ShaderCache must be a folder inside the player folder.")
    }
    let entries = try guarded("list the saved shader caches") {
      try files.contentsOfDirectory(atPath: root.path)
    }
    for name in entries where Self.isIdentifier(name) {
      let folder = directory(name)
      removed += try size(of: folder)
      try remove(folder)
    }
    return removed
  }

  private func size(of folder: URL) throws(LauncherError) -> Int {
    guard fileType(folder) == .typeDirectory else { return 0 }
    return try guarded("measure the shader cache") {
      try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
  }
}
