import Foundation
import LauncherCore
import Testing

@testable import CoD4Core

struct CoD4ProfileTests {
  @Test
  func `fresh profiles have clean settings and no inherited progress`() throws {
    let fixture = try CoD4ProfileFixture()
    defer { fixture.remove() }
    try fixture.store.perform(.init(action: .create, name: "New Player"))
    try Data("New Player".utf8).write(
      to: fixture.paths.saves.appendingPathComponent("profiles/active.txt"))
    let profile = try #require(fixture.store.list().first)
    #expect(profile.name == "New Player")
    #expect(!profile.hasCampaignSave)
    #expect(
      try String(
        contentsOf: fixture.profile("New Player").appendingPathComponent("config.cfg"),
        encoding: .utf8
      ).contains("bind W \"+forward\""))
    #expect(throws: Error.self) {
      try fixture.store.perform(.init(action: .create, name: "new player"))
    }
  }

  @Test
  func `backup restore removal and export preserve campaign bytes`() throws {
    let fixture = try CoD4ProfileFixture()
    defer { fixture.remove() }
    try fixture.store.perform(.init(action: .create, name: "Player"))
    let save = fixture.profile("Player").appendingPathComponent("save/autosave.svg")
    try FileManager.default.createDirectory(
      at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("original progress".utf8).write(to: save)
    try fixture.store.perform(.init(action: .backup, name: "Player"))
    let first = try #require(fixture.store.list().first?.backupNames.first)
    try Data("new progress".utf8).write(to: save)
    try fixture.store.perform(.init(action: .restore, name: "Player", backup: first))
    #expect(try Data(contentsOf: save) == Data("original progress".utf8))
    let export = fixture.root.appendingPathComponent("Export")
    try fixture.store.perform(
      .init(action: .exportProfile, name: "Player", destinationPath: export.path))
    #expect(
      try Data(contentsOf: export.appendingPathComponent("save/autosave.svg"))
        == Data("original progress".utf8))
    try fixture.store.perform(.init(action: .remove, name: "Player"))
    #expect(!FileManager.default.fileExists(atPath: fixture.profile("Player").path))
    #expect(try fixture.store.list().contains { $0.name == "Player" && !$0.backupNames.isEmpty })
    try fixture.store.perform(.init(action: .restore, name: "Player", backup: first))
    #expect(try Data(contentsOf: save) == Data("original progress".utf8))
  }

  @Test(arguments: ["../escape", "", "a;b", "a\"b", "a\nb", "abcdefghijklmnopqrstuvwxyz"])
  func `invalid profile names cannot reach the filesystem`(name: String) throws {
    #expect(!CoD4ProfileStore.validName(name))
  }

  @Test
  func `symlink imports are rejected without creating a profile`() throws {
    let fixture = try CoD4ProfileFixture()
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("Unsafe")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: source.appendingPathComponent("config.cfg"),
      withDestinationURL: fixture.paths.resources.appendingPathComponent("Defaults/config.cfg"))
    #expect(throws: Error.self) {
      try fixture.store.perform(
        .init(action: .importProfile, name: "Unsafe", sourcePath: source.path))
    }
    #expect(try fixture.store.list().isEmpty)
  }

  @Test
  func `interrupted replacement restores the original profile before another operation`() throws {
    let fixture = try CoD4ProfileFixture()
    defer { fixture.remove() }
    try fixture.store.perform(.init(action: .create, name: "Player"))
    let backupID = UUID().uuidString
    let backup = fixture.paths.support.appendingPathComponent("ProfileBackups/Player/" + backupID)
    try FileManager.default.createDirectory(
      at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: fixture.profile("Player"), to: backup)
    let stageName = ".profile-" + UUID().uuidString
    let stage = fixture.paths.support.appendingPathComponent(stageName)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    let journal = "{\"name\":\"Player\",\"stage\":\"\(stageName)\",\"backup\":\"\(backupID)\"}"
    try Data(journal.utf8).write(
      to: fixture.paths.support.appendingPathComponent("profile-transaction.json"))
    try fixture.store.recover()
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.profile("Player").appendingPathComponent("config.cfg").path))
    #expect(!FileManager.default.fileExists(atPath: stage.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.paths.support.appendingPathComponent("profile-transaction.json").path))
  }
}

private struct CoD4ProfileFixture {
  let root: URL
  let paths: AppPaths
  var store: CoD4ProfileStore { CoD4ProfileStore(paths: paths) }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    paths = try AppPaths(
      bundle: root.appendingPathComponent("CoD4.app"),
      support: root.appendingPathComponent("Support"), game: .cod4)
    let defaults = paths.resources.appendingPathComponent("Defaults")
    try FileManager.default.createDirectory(at: defaults, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.saves, withIntermediateDirectories: true)
    for name in ["config.cfg", "config_mp.cfg"] {
      try Data("seta r_fullscreen \"1\"\n".utf8).write(to: defaults.appendingPathComponent(name))
    }
  }
  func profile(_ name: String) -> URL { paths.saves.appendingPathComponent("profiles/" + name) }
  func remove() { do { try FileManager.default.removeItem(at: root) } catch { print(error) } }
}
