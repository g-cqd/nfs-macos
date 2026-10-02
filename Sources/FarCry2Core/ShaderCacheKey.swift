import CryptoKit
import Foundation
import LauncherCore

/// What a shader cache is valid for: one pinned mtld3d build.
///
/// The packager writes this beside the game manifest (`Packaging/shader_cache_key.py`). A cache is
/// stored and exchanged under its `identifier`, so a different renderer pin, container format, shader
/// schema or emitter source never loads another build's cache. The Mac's GPU and macOS version are
/// not part of the key: the cache holds shader source and pipeline recipes, which the renderer
/// recompiles on the Mac that loads them.
package struct ShaderCacheKey: Codable, Equatable, Sendable {
  package static let fileName = "renderer-cache-key.json"
  package static let schemaVersion = 1

  package let schemaVersion: Int
  /// The mtld3d commit the renderer was built from.
  package let mtld3dRevision: String
  /// The container format and shader schema integers in every cache header.
  package let cacheFormatVersion: Int
  package let shaderSchemaVersion: Int
  /// SHA-256 over the sources that define mtld3d's MSL emitter.
  package let emitterDigest: String
  package let emitterFileCount: Int

  package init(
    mtld3dRevision: String, cacheFormatVersion: Int, shaderSchemaVersion: Int,
    emitterDigest: String, emitterFileCount: Int
  ) {
    schemaVersion = Self.schemaVersion
    self.mtld3dRevision = mtld3dRevision
    self.cacheFormatVersion = cacheFormatVersion
    self.shaderSchemaVersion = shaderSchemaVersion
    self.emitterDigest = emitterDigest
    self.emitterFileCount = emitterFileCount
  }

  /// Sixteen lowercase hex digits naming the cache directory and export files.
  package var identifier: String {
    let canonical = [
      "farcry2-shader-cache", "revision=\(mtld3dRevision)", "format=\(cacheFormatVersion)",
      "schema=\(shaderSchemaVersion)", "emitter=\(emitterDigest)",
    ].joined(separator: "\n")
    return SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }
      .joined()
  }

  /// The header an up-to-date mtld3d writes, and the only one it keeps instead of wiping.
  package var header: ShaderCacheFormat.Header? {
    guard let format = UInt32(exactly: cacheFormatVersion),
      let schema = UInt32(exactly: shaderSchemaVersion)
    else { return nil }
    return .init(format: format, schema: schema)
  }

  /// A short description for the session log and the starter.
  package var summary: String {
    "mtld3d \(mtld3dRevision.prefix(8)), shader schema \(shaderSchemaVersion), emitter \(emitterDigest.prefix(8))"
  }

  /// Rejects a key that could name a path or collide: only lowercase hex of the exact lengths.
  package func validate() throws(LauncherError) {
    guard schemaVersion == Self.schemaVersion,
      Self.isHex(mtld3dRevision, count: 40), Self.isHex(emitterDigest, count: 64),
      header != nil, (1...Int(UInt16.max)).contains(emitterFileCount)
    else { throw .operation("The renderer cache key is invalid.") }
  }

  /// Reads the key a build carries; a missing file means the build has no persistent cache.
  /// - Returns: Nil when the file does not exist.
  /// - Throws: When the file exists but is oversized, malformed or invalid.
  package static func read(from resources: URL) throws(LauncherError) -> Self? {
    let url = resources.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let key: Self
    do {
      key = try JSONDecoder().decode(Self.self, from: BoundedFile.read(url, limit: 4096))
    } catch let error as LauncherError {
      throw error
    } catch {
      throw .operation("The renderer cache key is unreadable: \(error.localizedDescription)")
    }
    try key.validate()
    return key
  }

  private static func isHex(_ text: String, count: Int) -> Bool {
    text.utf8.count == count
      && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
