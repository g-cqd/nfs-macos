import Foundation
import LauncherCore

/// Whether the player has a shader cache the renderer can start from.
package enum ShaderCacheState: String, Codable, Sendable {
  /// This build carries no renderer key, so the cache stays in the game folder as mtld3d leaves it.
  case unavailable
  /// No cache yet: the first launch compiles every shader it meets and may pause.
  case empty
  case warm
}

/// What the starter shows about the saved cache.
package struct ShaderCacheStatus: Codable, Equatable, Sendable {
  package let state: ShaderCacheState
  package let bytes: Int
  package let saved: Date?
  /// The Mac and macOS that last wrote the cache; informational, not part of the key.
  package let origin: ShaderCacheOrigin?
  /// Caches of other renderer builds, kept for a short time and never loaded.
  package let otherBuilds: Int
  package let renderer: String?

  package init(
    state: ShaderCacheState, bytes: Int = 0, saved: Date? = nil, origin: ShaderCacheOrigin? = nil,
    otherBuilds: Int = 0, renderer: String? = nil
  ) {
    self.state = state
    self.bytes = bytes
    self.saved = saved
    self.origin = origin
    self.otherBuilds = otherBuilds
    self.renderer = renderer
  }

  /// The one-time pause notice, only while there is nothing to start from.
  package var firstRunNotice: String? {
    guard state == .empty else { return nil }
    return "The first launch compiles Far Cry 2's shaders on this Mac, so the game can pause while "
      + "it loads and the first scenes appear. The result is saved and reused, so later launches "
      + "start faster."
  }
}

/// What the starter records beside a saved cache.
struct ShaderCacheInfo: Codable, Equatable {
  let saved: Date
  let origin: ShaderCacheOrigin
  /// SHA-256 of recently imported payloads, so importing the same file twice cannot grow the cache.
  var imported: [String]
}

/// Keeps the player's shader cache outside the replaceable game generation, keyed to one renderer build.
///
/// mtld3d reads and writes `mtld3d_shaders.bin` next to the executable, a path it cannot be told to
/// change. The starter therefore keeps the saved copy under `ShaderCache/<key>/` in the player
/// folder, puts it in the game's `bin` before play, and takes it back after the game exits.
/// Everything here runs under the session lock with no game running.
package struct FarCry2ShaderCache {
  /// Far above the few megabytes a full game produces; a bound for hostile or runaway files.
  package static let defaultLimit = 256 * 1024 * 1024
  /// Caches of older renderer builds that are kept before the oldest is removed.
  package static let keptOtherBuilds = 2
  package static let cacheName = "mtld3d_shaders.bin"
  /// Names the build whose cache sits in the game folder, so only that build's cache is taken back.
  package static let markerName = "mtld3d_shaders.bin.owner"

  let paths: AppPaths
  package let key: ShaderCacheKey?
  let origin: ShaderCacheOrigin
  /// The most bytes one cache, saved or exchanged, may hold.
  let limit: Int
  let files = FileManager.default

  package init(
    paths: AppPaths, key: ShaderCacheKey?, origin: ShaderCacheOrigin, limit: Int = Self.defaultLimit
  ) {
    self.paths = paths
    self.key = key
    self.origin = origin
    self.limit = limit
  }

  package var root: URL { paths.support.appendingPathComponent("ShaderCache") }
  func directory(_ identifier: String) -> URL { root.appendingPathComponent(identifier) }
  func cacheFile(_ identifier: String) -> URL {
    directory(identifier).appendingPathComponent(Self.cacheName)
  }
  func infoFile(_ identifier: String) -> URL {
    directory(identifier).appendingPathComponent("info.json")
  }

  /// The saved cache and the renderer build it belongs to.
  package func status() throws(LauncherError) -> ShaderCacheStatus {
    guard let key else { return ShaderCacheStatus(state: .unavailable) }
    let identifier = key.identifier
    let saved = try savedCache(identifier)
    let info = readInfo(identifier)
    return ShaderCacheStatus(
      state: saved == nil ? .empty : .warm, bytes: saved?.count ?? 0, saved: info?.saved,
      origin: info?.origin, otherBuilds: try otherBuilds().count, renderer: key.summary)
  }

  /// The saved cache cut back to its intact chunks, or nil when there is none or it cannot be used.
  func savedCache(_ identifier: String) throws(LauncherError) -> Data? {
    guard let key, let header = key.header else { return nil }
    let url = cacheFile(identifier)
    // A link, folder or oversized file where the cache belongs is not a cache; callers replace it.
    guard fileType(url) == .typeRegular, let data = try? BoundedFile.read(url, limit: limit),
      let layout = ShaderCacheFormat.scan(data), layout.header == header, layout.hasRecords
    else { return nil }
    return ShaderCacheFormat.trimmed(data, layout: layout)
  }

  /// The description beside a saved cache; nil when absent or unusable, as it only decorates the cache.
  func readInfo(_ identifier: String) -> ShaderCacheInfo? {
    let url = infoFile(identifier)
    guard fileType(url) == .typeRegular, let data = try? BoundedFile.read(url, limit: 16_384)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ShaderCacheInfo.self, from: data)
  }

  /// Replaces the saved cache and its description together, then drops the oldest other builds.
  func save(_ data: Data, imported: [String]? = nil) throws(LauncherError) {
    guard let key else { throw .operation("This build has no persistent shader cache.") }
    let identifier = key.identifier
    let previous = readInfo(identifier)
    let info = ShaderCacheInfo(
      saved: Date(), origin: origin, imported: imported ?? previous?.imported ?? [])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try ensureDirectory(root)
    try ensureDirectory(directory(identifier))
    try guarded("save the shader cache") {
      try data.write(to: cacheFile(identifier), options: .atomic)
      try encoder.encode(info).write(to: infoFile(identifier), options: .atomic)
    }
    try pruneOtherBuilds()
  }

  // MARK: Other builds

  /// Cache folders of other renderer builds, newest first.
  func otherBuilds() throws(LauncherError) -> [URL] {
    guard let key, fileType(root) == .typeDirectory else { return [] }
    return try guarded("list the saved shader caches") {
      try files.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey]
      ).filter {
        Self.isIdentifier($0.lastPathComponent) && $0.lastPathComponent != key.identifier
          && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
      }.sorted { modified($0) > modified($1) }
    }
  }

  private func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }

  func pruneOtherBuilds() throws(LauncherError) {
    for stale in try otherBuilds().dropFirst(Self.keptOtherBuilds) { try remove(stale) }
  }

  static func isIdentifier(_ name: String) -> Bool {
    name.utf8.count == 16
      && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  // MARK: File helpers

  /// Runs file work, turning any Foundation failure into one message.
  func guarded<T>(_ action: String, _ body: () throws -> T) throws(LauncherError) -> T {
    do { return try body() } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not \(action): \(error.localizedDescription)")
    }
  }

  func fileType(_ url: URL) -> FileAttributeType? {
    try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
  }

  /// Contents of a regular file, nil when absent. A link or special file is an error, never followed.
  func readFile(_ url: URL, limit: Int) throws(LauncherError) -> Data? {
    guard let type = fileType(url) else { return nil }
    guard type == .typeRegular else {
      throw .operation("\(url.lastPathComponent) is not a regular file.")
    }
    return try BoundedFile.read(url, limit: limit)
  }

  /// Removes a file or folder, never following a link.
  func remove(_ url: URL) throws(LauncherError) {
    guard fileType(url) != nil else { return }
    try guarded("remove \(url.lastPathComponent)") { try files.removeItem(at: url) }
  }

  /// Creates a folder inside the player folder, refusing a link where the folder should be.
  func ensureDirectory(_ url: URL) throws(LauncherError) {
    if let type = fileType(url) {
      guard type == .typeDirectory else {
        throw .operation("\(url.lastPathComponent) must be a folder inside the player folder.")
      }
      return
    }
    try guarded("create \(url.lastPathComponent)") {
      try files.createDirectory(at: url, withIntermediateDirectories: false)
    }
  }
}
