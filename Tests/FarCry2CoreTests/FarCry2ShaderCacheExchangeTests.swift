import Foundation
import LauncherCore
import Testing

@testable import FarCry2Core

struct FarCry2ShaderCacheExchangeTests {
  /// A player folder whose game wrote `data`, the way a finished session leaves it.
  private func played(_ data: Data, key: ShaderCacheKey? = ShaderCacheKeys.make()) throws
    -> ShaderCacheHarness
  {
    let harness = try ShaderCacheHarness(key: key)
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(data)
    try harness.cache.harvest(game: harness.game)
    return harness
  }

  private func exported(_ harness: ShaderCacheHarness, name: String = "Far Cry 2.fc2shadercache")
    throws -> URL
  {
    let url = try harness.outside(name)
    try harness.cache.export(to: url, game: harness.game)
    return url
  }

  // MARK: Export

  @Test
  func `export then import on another Mac restores the same cache`() throws {
    let source = try played(ShaderCacheGolden.singles)
    let target = try ShaderCacheHarness()
    defer {
      source.remove()
      target.remove()
    }
    let file = try exported(source)
    #expect(
      try target.cache.importCache(from: file, game: target.game)
        == .installed(bytes: ShaderCacheGolden.singles.count))
    #expect(try target.bytes(target.saved) == ShaderCacheGolden.singles)
    #expect(
      try target.cache.prepare(game: target.game) == .warm(bytes: ShaderCacheGolden.singles.count))
    #expect(try target.bytes(target.working) == ShaderCacheGolden.singles)
  }

  @Test
  func `an export records the build, the checksum and where it was made`() throws {
    let source = try played(ShaderCacheGolden.bundle)
    defer { source.remove() }
    let url = try source.outside("a.fc2shadercache")
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let manifest = try source.cache.export(to: url, game: source.game, now: date)
    #expect(manifest.key == source.key && manifest.created == date)
    #expect(manifest.origin == ShaderCacheHarness.origin)
    let decoded = try ShaderCacheExport.decode(source.bytes(url), limit: 1 << 20)
    #expect(decoded.manifest == manifest && decoded.payload == ShaderCacheGolden.bundle)
  }

  @Test
  func `exporting takes back a cache a crashed session left, so it is included`() throws {
    let source = try ShaderCacheHarness()
    defer { source.remove() }
    _ = try source.cache.prepare(game: source.game)
    try source.gameWrites(ShaderCacheGolden.mixed)
    let url = try exported(source)
    #expect(
      try ShaderCacheExport.decode(source.bytes(url), limit: 1 << 20).payload
        == ShaderCacheGolden.mixed)
  }

  @Test
  func `exporting before any play says so and writes nothing`() throws {
    let source = try ShaderCacheHarness()
    defer { source.remove() }
    let url = try source.outside("none.fc2shadercache")
    #expect(throws: LauncherError.self) { try source.cache.export(to: url, game: source.game) }
    #expect(!source.exists(url))
  }

  @Test
  func `an export replaces an older export file`() throws {
    let source = try played(ShaderCacheGolden.singles)
    defer { source.remove() }
    let url = try source.outside("again.fc2shadercache")
    try Data("old".utf8).write(to: url)
    try source.cache.export(to: url, game: source.game)
    #expect(
      try ShaderCacheExport.decode(source.bytes(url), limit: 1 << 20).payload
        == ShaderCacheGolden.singles)
  }

  @Test
  func `an export destination must be a new file outside the player folder`() throws {
    let source = try played(ShaderCacheGolden.singles)
    defer { source.remove() }
    let inside = source.fixture.paths.support.appendingPathComponent("x.fc2shadercache")
    let nested = source.fixture.paths.saves.appendingPathComponent("x.fc2shadercache")
    let wrongName = try source.outside("x.bin")
    let missingParent = try source.outside("missing/x.fc2shadercache")
    let directory = try source.outside("dir.fc2shadercache")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let decoy = try source.outside("decoy")
    try Data("keep".utf8).write(to: decoy)
    let link = try source.outside("link.fc2shadercache")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: decoy)
    for destination in [inside, nested, wrongName, missingParent, directory, link] {
      #expect(throws: LauncherError.self, "\(destination.lastPathComponent)") {
        try source.cache.export(to: destination, game: source.game)
      }
    }
    #expect(try source.bytes(decoy) == Data("keep".utf8))
    #expect(!source.exists(inside) && !source.exists(nested))
  }

  // MARK: Import

  @Test
  func `importing into a cache that has records merges them and tells mtld3d nothing special`()
    throws
  {
    let source = try played(ShaderCacheGolden.singles)
    let target = try played(ShaderCacheGolden.bundle)
    defer {
      source.remove()
      target.remove()
    }
    let file = try exported(source)
    let result = try target.cache.importCache(from: file, game: target.game)
    let expected = try ShaderCacheFormat.joined(
      ShaderCacheGolden.bundle, ShaderCacheGolden.singles, limit: 1 << 20)
    #expect(result == .merged(bytes: expected.count))
    #expect(try target.bytes(target.saved) == expected)
    let layout = try #require(ShaderCacheFormat.scan(expected))
    #expect(layout.chunks == 4 && layout.header == .init(format: 20, schema: 79))
  }

  @Test
  func `importing the same file twice does not grow the cache`() throws {
    let source = try played(ShaderCacheGolden.singles)
    let target = try played(ShaderCacheGolden.bundle)
    defer {
      source.remove()
      target.remove()
    }
    let file = try exported(source)
    try target.cache.importCache(from: file, game: target.game)
    let size = try target.bytes(target.saved).count
    #expect(try target.cache.importCache(from: file, game: target.game) == .alreadyPresent)
    #expect(try target.bytes(target.saved).count == size)
  }

  @Test
  func `the repeated import is still recognised after the game compacted the cache`() throws {
    let source = try played(ShaderCacheGolden.singles)
    let target = try played(ShaderCacheGolden.bundle)
    defer {
      source.remove()
      target.remove()
    }
    let file = try exported(source)
    try target.cache.importCache(from: file, game: target.game)
    _ = try target.cache.prepare(game: target.game)
    try target.gameWrites(ShaderCacheGolden.mixed)
    try target.cache.harvest(game: target.game)
    #expect(try target.cache.importCache(from: file, game: target.game) == .alreadyPresent)
  }

  @Test
  func `importing what is already saved changes nothing`() throws {
    let source = try played(ShaderCacheGolden.singles)
    defer { source.remove() }
    let file = try exported(source)
    #expect(try source.cache.importCache(from: file, game: source.game) == .alreadyPresent)
    #expect(try source.bytes(source.saved) == ShaderCacheGolden.singles)
  }

  @Test
  func `a cache for another renderer build is refused and the saved one is untouched`() throws {
    let source = try played(
      ShaderCacheGolden.singles,
      key: ShaderCacheKeys.make(revision: String(repeating: "c", count: 40)))
    let target = try played(ShaderCacheGolden.bundle)
    defer {
      source.remove()
      target.remove()
    }
    let file = try exported(source)
    do {
      try target.cache.importCache(from: file, game: target.game)
      Issue.record("A cache for another build was accepted")
    } catch {
      let message = error.localizedDescription
      #expect(message.contains("cccccccc") && message.contains("aaaaaaaa"))
    }
    #expect(try target.bytes(target.saved) == ShaderCacheGolden.bundle)
  }

  @Test
  func `every other emitter, schema or format difference is refused too`() throws {
    let target = try played(ShaderCacheGolden.bundle)
    defer { target.remove() }
    for changed in [
      ShaderCacheKeys.make(emitter: String(repeating: "d", count: 64)),
      ShaderCacheKeys.make(schema: 80), ShaderCacheKeys.make(format: 21),
    ] {
      let (data, _) = try ShaderCacheExport.encode(
        payload: ShaderCacheGolden.singles, key: changed, created: Date(),
        origin: .init(gpu: nil, system: nil))
      let file = try target.outside()
      try data.write(to: file)
      #expect(throws: LauncherError.self) {
        try target.cache.importCache(from: file, game: target.game)
      }
    }
    #expect(try target.bytes(target.saved) == ShaderCacheGolden.bundle)
  }

  @Test
  func `a payload the renderer would wipe or that holds no records is refused`() throws {
    let target = try played(ShaderCacheGolden.bundle)
    defer { target.remove() }
    for payload in [ShaderCacheGolden.staleSchema, ShaderCacheGolden.empty, Data("junk".utf8)] {
      let (data, _) = try ShaderCacheExport.encode(
        payload: payload, key: target.key, created: Date(), origin: .init(gpu: nil, system: nil))
      let file = try target.outside()
      try data.write(to: file)
      #expect(throws: LauncherError.self) {
        try target.cache.importCache(from: file, game: target.game)
      }
    }
    #expect(try target.bytes(target.saved) == ShaderCacheGolden.bundle)
  }

  @Test
  func `a damaged, truncated or foreign file never changes the saved cache`() throws {
    let source = try played(ShaderCacheGolden.singles)
    let target = try played(ShaderCacheGolden.bundle)
    defer {
      source.remove()
      target.remove()
    }
    let good = try source.bytes(exported(source))
    var flipped = good
    flipped[flipped.count - 1] ^= 1
    for bytes in [
      flipped, Data(good.dropLast(3)), Data(good.prefix(20)), Data(),
      Data(repeating: 0x41, count: 99),
    ] {
      let file = try target.outside()
      try bytes.write(to: file)
      #expect(throws: LauncherError.self) {
        try target.cache.importCache(from: file, game: target.game)
      }
    }
    #expect(try target.bytes(target.saved) == ShaderCacheGolden.bundle)
  }

  @Test
  func `a missing file and a link are not imported`() throws {
    let source = try played(ShaderCacheGolden.singles)
    defer { source.remove() }
    let missing = try source.outside("missing.fc2shadercache")
    let link = try source.outside("link.fc2shadercache")
    let file = try exported(source)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    for url in [missing, link] {
      #expect(throws: LauncherError.self) {
        try source.cache.importCache(from: url, game: source.game)
      }
    }
  }

  @Test
  func `a merge that would pass the size limit is refused and nothing changes`() throws {
    let source = try played(ShaderCacheGolden.singles)
    let target = try ShaderCacheHarness(limit: 300)
    defer {
      source.remove()
      target.remove()
    }
    _ = try target.cache.prepare(game: target.game)
    try target.gameWrites(ShaderCacheGolden.bundle)
    try target.cache.harvest(game: target.game)
    let file = try exported(source)
    #expect(throws: LauncherError.self) {
      try target.cache.importCache(from: file, game: target.game)
    }
    #expect(try target.bytes(target.saved) == ShaderCacheGolden.bundle)
  }

  @Test
  func `an export larger than the limit is refused before it is read in full`() throws {
    let source = try played(ShaderCacheGolden.singles)
    let target = try ShaderCacheHarness(limit: 100)
    defer {
      source.remove()
      target.remove()
    }
    let file = try exported(source)
    #expect(throws: LauncherError.self) {
      try target.cache.importCache(from: file, game: target.game)
    }
    #expect(!target.exists(target.saved))
  }

  @Test
  func `an import takes back a crashed session's cache before merging so nothing is lost`() throws {
    let source = try played(ShaderCacheGolden.singles)
    let target = try ShaderCacheHarness()
    defer {
      source.remove()
      target.remove()
    }
    let file = try exported(source)
    _ = try target.cache.prepare(game: target.game)
    try target.gameWrites(ShaderCacheGolden.bundle)
    try target.cache.importCache(from: file, game: target.game)
    let saved = try target.bytes(target.saved)
    #expect(
      saved
        == (try ShaderCacheFormat.joined(
          ShaderCacheGolden.bundle, ShaderCacheGolden.singles, limit: 1 << 20)))
    #expect(!target.exists(target.working))
  }
}
