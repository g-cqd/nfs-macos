import Foundation
import Testing

@testable import LauncherCore

struct PrefixSeedTests {
  /// Stands in for `wineboot`: a prefix directory with a marker, nothing else.
  private static func wineboot(_ prefix: URL) throws {
    try FileManager.default.createDirectory(
      at: prefix.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
    try Data("initialized".utf8).write(to: prefix.appendingPathComponent("system.reg"))
  }

  private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  @Test
  func `seeds the game into the folder the installer would have used and publishes both together`()
    throws
  {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let prefix = try PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).prepare(
      initializePrefix: Self.wineboot)
    #expect(prefix == fixture.paths.prefix)
    #expect(try read(prefix.appendingPathComponent("system.reg")) == "initialized")
    for (path, text) in SeededFixture.contents {
      #expect(try read(fixture.seededGame.appendingPathComponent(path)) == text)
    }
    let record = try JSONDecoder().decode(
      PrefixSeed.Record.self,
      from: Data(contentsOf: PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).recordURL)
    )
    #expect(
      record
        == PrefixSeed.Record(
          bundleVersion: "v1", gameRoot: SeededFixture.gameRoot,
          files: SeededFixture.contents.count,
          bytes: SeededFixture.contents.values.reduce(0) { $0 + $1.utf8.count }))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.paths.support.appendingPathComponent(".preparing").path))
  }

  @Test
  func `never touches the bundled bytes when the seeded files change later`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    _ = try PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).prepare(
      initializePrefix: Self.wineboot)
    // The store client patches the installation in place, which must never reach the app's copy.
    let seeded = fixture.seededGame.appendingPathComponent("NFS16.exe")
    let handle = try FileHandle(forWritingTo: seeded)
    try handle.write(contentsOf: Data("patched by the store client".utf8))
    try handle.close()
    #expect(
      try read(fixture.paths.template.appendingPathComponent("NFS16.exe"))
        == SeededFixture.contents["NFS16.exe"])
  }

  @Test
  func `leaves the prefix, the player's files and the store client's patches alone afterwards`()
    throws
  {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let seed = PrefixSeed(paths: fixture.paths, manifest: fixture.manifest)
    _ = try seed.prepare(initializePrefix: Self.wineboot)
    let patched = fixture.seededGame.appendingPathComponent("Data/cas_01.cas")
    try Data("patched".utf8).write(to: patched)
    let save = fixture.paths.prefix.appendingPathComponent("drive_c/users/Player/save.dat")
    try FileManager.default.createDirectory(
      at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("progress".utf8).write(to: save)

    var initializations = 0
    let again = try seed.prepare { _ in initializations += 1 }
    #expect(again == fixture.paths.prefix)
    #expect(initializations == 0)
    #expect(try read(patched) == "patched")
    #expect(try read(save) == "progress")
  }

  @Test
  func `an app update with new files does not replace an installation the store client owns`()
    throws
  {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    _ = try PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).prepare(
      initializePrefix: Self.wineboot)
    let updated = try SeededFixture(version: "v2", contents: ["NFS16.exe": "a newer build"])
    try FileManager.default.removeItem(at: fixture.paths.template)
    try FileManager.default.copyItem(at: updated.paths.template, to: fixture.paths.template)
    defer { updated.remove() }
    _ = try PrefixSeed(paths: fixture.paths, manifest: updated.manifest).prepare { _ in
      throw LauncherError.operation("Must not run again")
    }
    #expect(
      try read(fixture.seededGame.appendingPathComponent("NFS16.exe"))
        == SeededFixture.contents["NFS16.exe"])
  }

  @Test
  func `a failed prefix initialization publishes nothing and a retry starts clean`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let seed = PrefixSeed(paths: fixture.paths, manifest: fixture.manifest)
    #expect(throws: LauncherError.self) {
      try seed.prepare { _ in throw LauncherError.operation("Injected wineboot failure") }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.paths.support.appendingPathComponent(".preparing").path))
    #expect(!seed.isSeeded)
    _ = try seed.prepare(initializePrefix: Self.wineboot)
    #expect(seed.isSeeded)
  }

  @Test
  func `refuses a packaged file whose bytes changed and publishes nothing`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    try Data("tampered".utf8).write(to: fixture.paths.template.appendingPathComponent("NFS16.exe"))
    #expect(throws: LauncherError.self) {
      try PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).prepare(
        initializePrefix: Self.wineboot)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
  }

  @Test
  func `refuses a packaged file that is missing or has the right size and the wrong bytes`() throws
  {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let target = fixture.paths.template.appendingPathComponent("Support/mnfst.txt")
    try Data(
      String(repeating: "x", count: SeededFixture.contents["Support/mnfst.txt"]!.utf8.count).utf8
    )
    .write(to: target)
    #expect(throws: LauncherError.self) {
      try PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).prepare(
        initializePrefix: Self.wineboot)
    }
    try FileManager.default.removeItem(at: target)
    #expect(throws: LauncherError.self) {
      try PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).prepare(
        initializePrefix: Self.wineboot)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
  }

  @Test
  func `refuses a linked packaged file`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let target = fixture.paths.template.appendingPathComponent("NFS16.exe")
    let elsewhere = fixture.root.appendingPathComponent("elsewhere.exe")
    try FileManager.default.moveItem(at: target, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)
    #expect(throws: LauncherError.self) {
      try PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).prepare(
        initializePrefix: Self.wineboot)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
  }

  @Test
  func `clears the leftovers of an interrupted preparation before starting`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let stale = fixture.paths.support.appendingPathComponent(".preparing/Prefix/stale.txt")
    try FileManager.default.createDirectory(
      at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("half done".utf8).write(to: stale)
    let prefix = try PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).prepare(
      initializePrefix: Self.wineboot)
    #expect(
      !FileManager.default.fileExists(atPath: prefix.appendingPathComponent("stale.txt").path))
    #expect(try read(prefix.appendingPathComponent("system.reg")) == "initialized")
  }

  @Test
  func `refuses player data that was never completely prepared`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.paths.prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
    var initializations = 0
    #expect(throws: LauncherError.self) {
      try PrefixSeed(paths: fixture.paths, manifest: fixture.manifest).prepare { _ in
        initializations += 1
      }
    }
    #expect(initializations == 0)
  }

  @Test
  func `refuses a manifest that does not seed a prefix`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let referencing = BundleManifest(
      version: "v1", gameFiles: [], gameID: .nfs2015, referencesInstallation: true,
      storeClient: SeededFixture.plan, renderers: SeededFixture.renderers)
    #expect(throws: LauncherError.self) {
      try PrefixSeed(paths: fixture.paths, manifest: referencing).prepare(
        initializePrefix: Self.wineboot)
    }
    let other = try AppPaths(
      bundle: fixture.root.appendingPathComponent("Game.app"),
      support: fixture.root.appendingPathComponent("Other"), game: .nfsmw)
    #expect(throws: LauncherError.self) {
      try PrefixSeed(paths: other, manifest: fixture.manifest).prepare(
        initializePrefix: Self.wineboot)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
  }

  @Test
  func `refuses to start when the disk cannot hold the preparation`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let cramped = PrefixSeed(
      paths: fixture.paths, manifest: fixture.manifest, freeSpace: { _ in 10 })
    #expect(throws: LauncherError.self) { try cramped.prepare(initializePrefix: Self.wineboot) }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.paths.support.appendingPathComponent(".preparing").path))
    let roomy = PrefixSeed(
      paths: fixture.paths, manifest: fixture.manifest, freeSpace: { _ in 100_000_000_000 })
    _ = try roomy.prepare(initializePrefix: Self.wineboot)
    #expect(roomy.isSeeded)
  }
}
