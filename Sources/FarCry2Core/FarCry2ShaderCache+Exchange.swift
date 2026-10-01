import Foundation
import LauncherCore

/// How an imported cache joined the saved one.
package enum ShaderCacheImport: Equatable, Sendable {
  /// There was no saved cache; the imported one is now it.
  case installed(bytes: Int)
  /// Its records were added to the saved cache; mtld3d removes duplicates at its next start.
  case merged(bytes: Int)
  /// The same cache was imported before, or is what is already saved.
  case alreadyPresent
}

extension FarCry2ShaderCache {
  /// Imports remembered per cache, enough to recognise a repeated import without unbounded growth.
  private static let rememberedImports = 16
  /// Room for the export's own description around the largest payload.
  private static let exportOverhead = 32_768

  /// Writes the saved cache and a description of the renderer build it belongs to.
  /// - Parameters:
  ///   - destination: A new `.fc2shadercache` file outside the player folder.
  ///   - game: The active game folder, so a cache a crashed session left is taken back first.
  /// - Throws: When there is nothing to export or the destination is not acceptable.
  @discardableResult
  package func export(to destination: URL, game: URL, now: Date = Date()) throws(LauncherError)
    -> ShaderCacheExport.Manifest
  {
    guard let key else { throw unavailable }
    try harvest(game: game)
    guard let saved = try savedCache(key.identifier) else {
      throw .operation("There is no saved shader cache yet. Play the game once, then export it.")
    }
    let target = try checkedExportTarget(destination)
    let (container, manifest) = try ShaderCacheExport.encode(
      payload: saved, key: key, created: now, origin: origin)
    try guarded("write the shader cache export") {
      try container.write(to: target, options: .atomic)
    }
    return manifest
  }

  /// Adds a cache exported by this app, for the same renderer build, to the saved one.
  /// - Throws: A message naming the problem; the saved cache is never changed on failure.
  @discardableResult
  package func importCache(from source: URL, game: URL) throws(LauncherError) -> ShaderCacheImport {
    guard let key, let header = key.header else { throw unavailable }
    try harvest(game: game)
    guard let file = try readFile(source, limit: limit + Self.exportOverhead) else {
      throw .operation("The shader cache export could not be found.")
    }
    let (manifest, payload) = try ShaderCacheExport.decode(file, limit: limit)
    guard manifest.key == key else {
      throw .operation(
        "This shader cache was made for a different renderer build (\(manifest.key.summary)). "
          + "This app uses \(key.summary), so the cache cannot be used.")
    }
    guard let layout = ShaderCacheFormat.scan(payload), layout.header == header, layout.hasRecords
    else { throw .operation("The shader cache export holds no usable shader records.") }
    let incoming = ShaderCacheFormat.trimmed(payload, layout: layout)
    let digest = ShaderCacheExport.digest(incoming)
    let remembered = readInfo(key.identifier)?.imported ?? []
    let saved = try savedCache(key.identifier)
    if remembered.contains(digest) || saved.map(ShaderCacheExport.digest) == digest {
      return .alreadyPresent
    }
    var combined: Data?
    if let saved { combined = try ShaderCacheFormat.joined(saved, incoming, limit: limit) }
    let history = Array((remembered + [digest]).suffix(Self.rememberedImports))
    try save(combined ?? incoming, imported: history)
    return combined == nil
      ? .installed(bytes: incoming.count) : .merged(bytes: combined?.count ?? 0)
  }

  private var unavailable: LauncherError {
    .operation("This build of the starter has no persistent shader cache.")
  }

  /// The destination must be a new or replaceable regular file outside the player folder.
  private func checkedExportTarget(_ destination: URL) throws(LauncherError) -> URL {
    let target = destination.standardizedFileURL
    let support = paths.support.standardizedFileURL.resolvingSymlinksInPath().path
    let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
    guard target.isFileURL, target.pathExtension == ShaderCacheExport.fileExtension,
      fileType(parent) == .typeDirectory,
      parent.path != support, !parent.path.hasPrefix(support + "/")
    else {
      throw .operation(
        "Export the shader cache to a .\(ShaderCacheExport.fileExtension) file outside the game's player data folder."
      )
    }
    if let type = fileType(target), type != .typeRegular {
      throw .operation("\(target.lastPathComponent) already exists and is not a file.")
    }
    return parent.appendingPathComponent(target.lastPathComponent)
  }
}
