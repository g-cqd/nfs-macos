import CryptoKit
import Foundation
import LauncherCore

/// Where the player's cache was produced; recorded in an export for the player's information only.
package struct ShaderCacheOrigin: Codable, Equatable, Sendable {
  package let gpu: String?
  package let system: String?
  package init(gpu: String?, system: String?) {
    self.gpu = gpu
    self.system = system
  }
}

/// A single-file container for moving one player's shader cache to another Mac or a fresh install.
///
/// ```text
/// "FC2SHCEX" | manifest length u32 LE | manifest JSON | payload (the cache file, header first)
/// ```
///
/// The manifest names the renderer key the payload belongs to and carries the payload's SHA-256, so a
/// damaged or mismatched file is refused before it can replace anything.
/// - Important: The payload holds shader bytecode the game generated for this player. It is for the
///   player's own use; the starter never uploads it and no cache is packaged with the app.
package enum ShaderCacheExport {
  package static let fileExtension = "fc2shadercache"
  package static let formatVersion = 1
  private static let magic = Array("FC2SHCEX".utf8)
  private static let maximumManifest = 16_384
  private static let maximumText = 256

  package struct Manifest: Codable, Equatable, Sendable {
    package let formatVersion: Int
    package let created: Date
    package let key: ShaderCacheKey
    package let payloadBytes: Int
    package let payloadSHA256: String
    package let origin: ShaderCacheOrigin
  }

  package static func encode(
    payload: Data, key: ShaderCacheKey, created: Date, origin: ShaderCacheOrigin
  ) throws(LauncherError) -> (container: Data, manifest: Manifest) {
    let manifest = Manifest(
      formatVersion: formatVersion, created: created, key: key, payloadBytes: payload.count,
      payloadSHA256: digest(payload), origin: origin)
    let json: Data
    do { json = try encoder.encode(manifest) } catch {
      throw .operation("Could not describe the shader cache export: \(error.localizedDescription)")
    }
    guard json.count <= maximumManifest else {
      throw .operation("The shader cache export description is too large.")
    }
    var data = Data(magic)
    data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: json.count >> (8 * $0)) })
    data.append(json)
    data.append(payload)
    return (data, manifest)
  }

  /// Checks every length, the key and the digest before returning the payload.
  /// - Parameter limit: The largest payload accepted.
  /// - Throws: A description of what is wrong with the file; nothing is returned partially.
  package static func decode(_ data: Data, limit: Int) throws(LauncherError) -> (
    manifest: Manifest, payload: Data
  ) {
    let invalid = LauncherError.operation("This is not a Far Cry 2 shader cache export.")
    guard data.count >= magic.count + 4, Array(data.prefix(magic.count)) == magic else {
      throw invalid
    }
    let start = data.startIndex
    var length = 0
    for index in 0..<4 { length |= Int(data[start + magic.count + index]) << (8 * index) }
    let bodyStart = magic.count + 4
    guard length > 0, length <= maximumManifest, bodyStart + length <= data.count else {
      throw invalid
    }
    let manifest: Manifest
    do {
      manifest = try decoder.decode(
        Manifest.self, from: data[(start + bodyStart)..<(start + bodyStart + length)])
    } catch { throw invalid }
    guard manifest.formatVersion == formatVersion else {
      throw .operation("This shader cache export was made by a newer version of the starter.")
    }
    try manifest.key.validate()
    let payload = Data(data[(start + bodyStart + length)...])
    guard manifest.payloadBytes == payload.count else {
      throw .operation("The shader cache export is incomplete or has extra data.")
    }
    guard payload.count <= limit else {
      throw .operation("The shader cache export is larger than the \(limit / 1_048_576) MiB limit.")
    }
    guard digest(payload) == manifest.payloadSHA256 else {
      throw .operation("The shader cache export is damaged: its checksum does not match.")
    }
    for text in [manifest.origin.gpu, manifest.origin.system].compactMap({ $0 }) {
      guard text.count <= maximumText, !text.unicodeScalars.contains(where: { $0.value < 32 })
      else {
        throw invalid
      }
    }
    return (manifest, payload)
  }

  package static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
