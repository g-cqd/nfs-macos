import FarCry2Core
import Foundation
import LauncherCore

@testable import FarCry2Core

/// A player folder with one game generation, and the shader cache logic pointed at it.
struct ShaderCacheHarness {
  let fixture: FarCry2Fixture
  let key: ShaderCacheKey
  let cache: FarCry2ShaderCache

  static let origin = ShaderCacheOrigin(gpu: "Test GPU", system: "macOS Test")

  init(key: ShaderCacheKey? = ShaderCacheKeys.make(), limit: Int = FarCry2ShaderCache.defaultLimit)
    throws
  {
    fixture = try FarCry2Fixture()
    try fixture.installGameFolder()
    self.key = key ?? ShaderCacheKeys.make()
    cache = FarCry2ShaderCache(paths: fixture.paths, key: key, origin: Self.origin, limit: limit)
  }

  var game: URL { fixture.paths.game(version: "test") }
  var working: URL { game.appendingPathComponent("bin/mtld3d_shaders.bin") }
  var marker: URL { game.appendingPathComponent("bin/mtld3d_shaders.bin.owner") }
  var saved: URL {
    cache.root.appendingPathComponent(key.identifier).appendingPathComponent("mtld3d_shaders.bin")
  }

  /// The same player folder seen by a build with a different renderer key.
  func other(_ key: ShaderCacheKey) -> FarCry2ShaderCache {
    FarCry2ShaderCache(paths: fixture.paths, key: key, origin: Self.origin)
  }

  /// What mtld3d leaves in `bin` after a run: the file it appended to.
  func gameWrites(_ data: Data) throws {
    try data.write(to: working)
  }

  func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  func isLink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  /// A scratch folder outside the player folder, for exports and decoys.
  func outside(_ name: String = UUID().uuidString) throws -> URL {
    let folder = fixture.root.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name)
  }

  func remove() { fixture.remove() }
}
