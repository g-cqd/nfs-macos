import Foundation
import LauncherCore
import Testing

@testable import FarCry2Core

struct FarCry2ShaderCacheTests {
  // MARK: Launch cycle

  @Test
  func `the first launch is cold, claims the game folder and leaves no cache there`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    #expect(try harness.cache.prepare(game: harness.game) == .cold)
    #expect(!harness.exists(harness.working))
    #expect(try harness.bytes(harness.marker) == Data((harness.key.identifier + "\n").utf8))
    let status = try harness.cache.status()
    #expect(status.state == .empty && status.bytes == 0 && status.saved == nil)
    #expect(status.firstRunNotice?.contains("first launch") == true)
  }

  @Test
  func `what the game writes is saved, then placed again for the next launch`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    #expect(
      try harness.cache.harvest(game: harness.game)
        == .saved(bytes: ShaderCacheGolden.singles.count))
    #expect(try harness.bytes(harness.saved) == ShaderCacheGolden.singles)
    #expect(!harness.exists(harness.working) && !harness.exists(harness.marker))
    let status = try harness.cache.status()
    #expect(status.state == .warm && status.bytes == ShaderCacheGolden.singles.count)
    #expect(status.saved != nil && status.origin == ShaderCacheHarness.origin)
    #expect(status.firstRunNotice == nil)
    #expect(
      try harness.cache.prepare(game: harness.game) == .warm(bytes: ShaderCacheGolden.singles.count)
    )
    #expect(try harness.bytes(harness.working) == ShaderCacheGolden.singles)
  }

  @Test
  func `a game that compacts the cache replaces the saved one with the newer file`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    try harness.cache.harvest(game: harness.game)
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.bundle)
    try harness.cache.harvest(game: harness.game)
    #expect(try harness.bytes(harness.saved) == ShaderCacheGolden.bundle)
  }

  @Test
  func `a crashed session loses nothing because the next session takes the cache back first`()
    throws
  {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.mixed)
    // No harvest: the helper was killed. The next launch must keep the work and start from it.
    #expect(
      try harness.cache.prepare(game: harness.game) == .warm(bytes: ShaderCacheGolden.mixed.count))
    #expect(try harness.bytes(harness.saved) == ShaderCacheGolden.mixed)
    #expect(try harness.bytes(harness.working) == ShaderCacheGolden.mixed)
  }

  @Test
  func `a torn tail from a killed game is cut off before the cache is saved`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.torn)
    try harness.cache.harvest(game: harness.game)
    #expect(
      try harness.bytes(harness.saved)
        == Data(ShaderCacheGolden.torn.prefix(ShaderCacheGolden.staleSchema.count)))
  }

  // MARK: What is never trusted

  @Test
  func `an empty or unusable game file never replaces a good saved cache`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    try harness.cache.harvest(game: harness.game)
    for (data, expected) in [
      (ShaderCacheGolden.empty, ShaderCacheHarvest.unchanged),
      (ShaderCacheGolden.staleSchema, .discarded),
      (Data("not a cache at all".utf8), .discarded),
      (Data(), .discarded),
    ] {
      _ = try harness.cache.prepare(game: harness.game)
      try harness.gameWrites(data)
      #expect(try harness.cache.harvest(game: harness.game) == expected)
      #expect(try harness.bytes(harness.saved) == ShaderCacheGolden.singles)
    }
  }

  @Test
  func `a cache the starter did not place is removed and never saved`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    try harness.gameWrites(ShaderCacheGolden.singles)
    #expect(try harness.cache.harvest(game: harness.game) == .discarded)
    #expect(!harness.exists(harness.working) && !harness.exists(harness.saved))
  }

  @Test
  func `a cache placed for another renderer build is not taken as this build's`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    let previous = harness.other(ShaderCacheKeys.make(revision: String(repeating: "c", count: 40)))
    _ = try previous.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    #expect(try harness.cache.harvest(game: harness.game) == .discarded)
    #expect(!harness.exists(harness.saved))
  }

  @Test
  func `a link in the game folder is removed without touching what it points at`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    let decoy = try harness.outside("decoy.bin")
    try Data("precious".utf8).write(to: decoy)
    _ = try harness.cache.prepare(game: harness.game)
    try FileManager.default.createSymbolicLink(at: harness.working, withDestinationURL: decoy)
    #expect(try harness.cache.harvest(game: harness.game) == .discarded)
    #expect(!harness.isLink(harness.working) && !harness.exists(harness.working))
    #expect(try harness.bytes(decoy) == Data("precious".utf8))
    #expect(!harness.exists(harness.saved))
  }

  @Test
  func `a marker that is a link is not followed and does not vouch for the file`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    let decoy = try harness.outside("marker.txt")
    try Data((harness.key.identifier + "\n").utf8).write(to: decoy)
    try FileManager.default.createSymbolicLink(at: harness.marker, withDestinationURL: decoy)
    try harness.gameWrites(ShaderCacheGolden.singles)
    #expect(try harness.cache.harvest(game: harness.game) == .discarded)
    #expect(!harness.exists(harness.saved) && !harness.exists(harness.working))
    #expect(!harness.isLink(harness.marker))
    #expect(try harness.bytes(decoy) == Data((harness.key.identifier + "\n").utf8))
  }

  @Test
  func `a file beyond the size limit is refused and the saved cache stays`() throws {
    let harness = try ShaderCacheHarness(limit: ShaderCacheGolden.singles.count)
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    #expect(
      try harness.cache.harvest(game: harness.game)
        == .saved(bytes: ShaderCacheGolden.singles.count))
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.concatChunks)
    #expect(try harness.cache.harvest(game: harness.game) == .tooLarge)
    #expect(try harness.bytes(harness.saved) == ShaderCacheGolden.singles)
    #expect(!harness.exists(harness.working))
  }

  @Test
  func `a damaged saved cache is replaced by a cold start, not loaded`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    try FileManager.default.createDirectory(
      at: harness.saved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("garbage".utf8).write(to: harness.saved)
    #expect(try harness.cache.status().state == .empty)
    #expect(try harness.cache.prepare(game: harness.game) == .cold)
    #expect(!harness.exists(harness.saved) && !harness.exists(harness.working))
  }

  @Test
  func `leftover lock and compaction files are cleaned from the game folder`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    let bin = harness.game.appendingPathComponent("bin")
    for name in ["mtld3d_shaders.bin.lock", "mtld3d_shaders.bin.123-4.tmp", "mtld3d.conf"] {
      try Data("x".utf8).write(to: bin.appendingPathComponent(name))
    }
    _ = try harness.cache.prepare(game: harness.game)
    #expect(!harness.exists(bin.appendingPathComponent("mtld3d_shaders.bin.lock")))
    #expect(!harness.exists(bin.appendingPathComponent("mtld3d_shaders.bin.123-4.tmp")))
    #expect(harness.exists(bin.appendingPathComponent("mtld3d.conf")), "the renderer config stays")
  }

  // MARK: Where the cache lives

  @Test
  func `the cache lives outside the prefix and the game generation`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    let root = harness.cache.root.path
    #expect(!root.hasPrefix(harness.fixture.paths.data.path + "/"))
    #expect(root.hasPrefix(harness.fixture.paths.support.path + "/"))
    #expect(harness.cache.root.lastPathComponent == "ShaderCache")
  }

  @Test
  func `repairing the prefix or replacing the game generation keeps the saved cache`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    try harness.cache.harvest(game: harness.game)
    try FileManager.default.removeItem(at: harness.fixture.paths.prefix)
    try FileManager.default.removeItem(at: harness.game.deletingLastPathComponent())
    #expect(try harness.cache.status().state == .warm)
    let update = harness.fixture.paths.game(version: "import-next")
    try FileManager.default.createDirectory(
      at: update.appendingPathComponent("bin"), withIntermediateDirectories: true)
    #expect(
      try harness.cache.prepare(game: update) == .warm(bytes: ShaderCacheGolden.singles.count))
    #expect(
      try harness.bytes(update.appendingPathComponent("bin/mtld3d_shaders.bin"))
        == ShaderCacheGolden.singles)
  }

  @Test
  func `a different renderer build starts empty and never loads another build's cache`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    try harness.cache.harvest(game: harness.game)
    for changed in [
      ShaderCacheKeys.make(revision: String(repeating: "c", count: 40)),
      ShaderCacheKeys.make(emitter: String(repeating: "d", count: 64)),
      ShaderCacheKeys.make(schema: 80), ShaderCacheKeys.make(format: 21),
    ] {
      let update = harness.other(changed)
      #expect(try update.prepare(game: harness.game) == .cold)
      #expect(!harness.exists(harness.working))
      let status = try update.status()
      #expect(status.state == .empty && status.otherBuilds == 1)
    }
    #expect(try harness.bytes(harness.saved) == ShaderCacheGolden.singles, "kept for a rollback")
  }

  @Test
  func `only the newest few caches of other builds are kept`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    let files = FileManager.default
    try files.createDirectory(at: harness.cache.root, withIntermediateDirectories: true)
    for index in 1...4 {
      let folder = harness.cache.root.appendingPathComponent(String(format: "%016x", index))
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
      try files.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: Double(index) * 1000)],
        ofItemAtPath: folder.path)
    }
    let stranger = harness.cache.root.appendingPathComponent("notes.txt")
    try Data("mine".utf8).write(to: stranger)
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    try harness.cache.harvest(game: harness.game)
    let remaining = try files.contentsOfDirectory(atPath: harness.cache.root.path).sorted()
    #expect(
      remaining
        == [harness.key.identifier, "0000000000000003", "0000000000000004", "notes.txt"].sorted())
  }

  @Test
  func `a build without a key leaves the game folder alone`() throws {
    let harness = try ShaderCacheHarness(key: nil)
    defer { harness.remove() }
    try harness.gameWrites(ShaderCacheGolden.singles)
    #expect(try harness.cache.prepare(game: harness.game) == .unavailable)
    #expect(try harness.cache.harvest(game: harness.game) == .none)
    #expect(try harness.bytes(harness.working) == ShaderCacheGolden.singles)
    #expect(try harness.cache.status() == ShaderCacheStatus(state: .unavailable))
    #expect(throws: LauncherError.self) {
      try harness.cache.importCache(from: harness.working, game: harness.game)
    }
  }

  @Test
  func `a link where the cache folder belongs is refused and nothing is written through it`() throws
  {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    let elsewhere = try harness.outside("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: harness.cache.root, withDestinationURL: elsewhere)
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    #expect(throws: LauncherError.self) { try harness.cache.harvest(game: harness.game) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    #expect(harness.exists(harness.working), "the file is kept for another attempt")
  }

  // MARK: Reset

  @Test
  func `reset removes every saved cache and the game folder's copy, and only those`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    try harness.cache.harvest(game: harness.game)
    let older = harness.cache.root.appendingPathComponent("00000000000000aa")
    try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 10).write(to: older.appendingPathComponent("mtld3d_shaders.bin"))
    _ = try harness.cache.prepare(game: harness.game)
    let stranger = harness.cache.root.appendingPathComponent("keep-me")
    try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
    let removed = try harness.cache.reset(game: harness.game)
    #expect(removed >= ShaderCacheGolden.singles.count + 10)
    #expect(!harness.exists(harness.saved) && !harness.exists(harness.working))
    #expect(!harness.exists(older))
    #expect(!harness.exists(harness.marker))
    #expect(harness.exists(stranger))
    let status = try harness.cache.status()
    #expect(status.state == .empty && status.otherBuilds == 0)
  }

  @Test
  func `reset refuses a cache folder that is a link and deletes nothing through it`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    let elsewhere = try harness.outside("elsewhere")
    let victim = elsewhere.appendingPathComponent("00000000000000aa")
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: harness.cache.root, withDestinationURL: elsewhere)
    #expect(throws: LauncherError.self) { try harness.cache.reset(game: harness.game) }
    #expect(harness.exists(victim))
    #expect(try harness.cache.status().otherBuilds == 0)
  }

  @Test
  func `a link or folder where the saved cache belongs counts as no cache and is replaced`() throws
  {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    let decoy = try harness.outside("decoy.bin")
    try Data("precious".utf8).write(to: decoy)
    try FileManager.default.createDirectory(
      at: harness.saved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: harness.saved, withDestinationURL: decoy)
    #expect(try harness.cache.status().state == .empty)
    #expect(try harness.cache.prepare(game: harness.game) == .cold)
    #expect(!harness.isLink(harness.saved))
    #expect(try harness.bytes(decoy) == Data("precious".utf8))
    try harness.gameWrites(ShaderCacheGolden.singles)
    try harness.cache.harvest(game: harness.game)
    #expect(try harness.bytes(harness.saved) == ShaderCacheGolden.singles)
  }

  @Test
  func `reset with nothing saved is not an error`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    #expect(try harness.cache.reset(game: nil) == 0)
    #expect(try harness.cache.reset(game: harness.game) == 0)
  }

  @Test
  func `after a reset the next launch is cold again`() throws {
    let harness = try ShaderCacheHarness()
    defer { harness.remove() }
    _ = try harness.cache.prepare(game: harness.game)
    try harness.gameWrites(ShaderCacheGolden.singles)
    try harness.cache.harvest(game: harness.game)
    try harness.cache.reset(game: harness.game)
    #expect(try harness.cache.prepare(game: harness.game) == .cold)
  }
}
