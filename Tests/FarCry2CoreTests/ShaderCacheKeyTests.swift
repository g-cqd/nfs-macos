import Foundation
import LauncherCore
import Testing

@testable import FarCry2Core

/// A key matching the golden cache files, and variants that differ in exactly one field.
enum ShaderCacheKeys {
  static let revision = String(repeating: "a", count: 40)
  static let emitter = String(repeating: "b", count: 64)

  static func make(
    revision: String = revision, format: Int = 20, schema: Int = 79, emitter: String = emitter
  ) -> ShaderCacheKey {
    ShaderCacheKey(
      mtld3dRevision: revision, cacheFormatVersion: format, shaderSchemaVersion: schema,
      emitterDigest: emitter, emitterFileCount: 9)
  }
}

struct ShaderCacheKeyTests {
  /// The folder holding the packager's synthetic-tree output, checked byte for byte by
  /// `check_shader_cache.py`, so the writer and this reader cannot drift apart.
  private func packagerFixture(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Packaging/fixtures")
  }

  private func folder(containing json: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: folder.appendingPathComponent(ShaderCacheKey.fileName))
    return folder
  }

  @Test
  func `reads the key file the packager writes`() throws {
    let key = try #require(try ShaderCacheKey.read(from: packagerFixture()))
    #expect(key.mtld3dRevision == "0123456789abcdef0123456789abcdef01234567")
    #expect(key.shaderSchemaVersion == 79 && key.cacheFormatVersion == 20)
    #expect(key.emitterFileCount == 6)
    #expect(key.header == .init(format: 20, schema: 79))
    #expect(key.identifier == "bc2c6e3fc5342833")
  }

  @Test
  func `a build without a key file has no persistent cache`() throws {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(try ShaderCacheKey.read(from: empty) == nil)
  }

  @Test
  func `the identifier is stable and changes with every field`() {
    let base = ShaderCacheKeys.make()
    #expect(base.identifier == ShaderCacheKeys.make().identifier)
    #expect(base.identifier.count == 16)
    let others = [
      ShaderCacheKeys.make(revision: String(repeating: "c", count: 40)),
      ShaderCacheKeys.make(format: 21), ShaderCacheKeys.make(schema: 80),
      ShaderCacheKeys.make(emitter: String(repeating: "d", count: 64)),
    ]
    #expect(Set(others.map(\.identifier) + [base.identifier]).count == others.count + 1)
  }

  @Test
  func `the identifier is only ever lowercase hex, so it cannot name another path`() {
    let identifier = ShaderCacheKeys.make().identifier
    #expect(FarCry2ShaderCache.isIdentifier(identifier))
  }

  @Test(arguments: [
    "{}", "not json", "[]",
    #"{"schemaVersion":2,"mtld3dRevision":"\#(String(repeating: "a", count: 40))","cacheFormatVersion":20,"shaderSchemaVersion":79,"emitterDigest":"\#(String(repeating: "b", count: 64))","emitterFileCount":9}"#,
    #"{"schemaVersion":1,"mtld3dRevision":"../..","cacheFormatVersion":20,"shaderSchemaVersion":79,"emitterDigest":"\#(String(repeating: "b", count: 64))","emitterFileCount":9}"#,
    #"{"schemaVersion":1,"mtld3dRevision":"\#(String(repeating: "A", count: 40))","cacheFormatVersion":20,"shaderSchemaVersion":79,"emitterDigest":"\#(String(repeating: "b", count: 64))","emitterFileCount":9}"#,
    #"{"schemaVersion":1,"mtld3dRevision":"\#(String(repeating: "a", count: 40))","cacheFormatVersion":-1,"shaderSchemaVersion":79,"emitterDigest":"\#(String(repeating: "b", count: 64))","emitterFileCount":9}"#,
    #"{"schemaVersion":1,"mtld3dRevision":"\#(String(repeating: "a", count: 40))","cacheFormatVersion":20,"shaderSchemaVersion":79,"emitterDigest":"short","emitterFileCount":9}"#,
    #"{"schemaVersion":1,"mtld3dRevision":"\#(String(repeating: "a", count: 40))","cacheFormatVersion":20,"shaderSchemaVersion":79,"emitterDigest":"\#(String(repeating: "b", count: 64))","emitterFileCount":0}"#,
  ])
  func `a malformed or unsafe key file is rejected`(json: String) throws {
    let folder = try folder(containing: json)
    #expect(throws: LauncherError.self) { try ShaderCacheKey.read(from: folder) }
  }

  @Test
  func `an oversized key file is rejected before it is parsed`() throws {
    let folder = try folder(containing: String(repeating: " ", count: 5000))
    #expect(throws: LauncherError.self) { try ShaderCacheKey.read(from: folder) }
  }
}
