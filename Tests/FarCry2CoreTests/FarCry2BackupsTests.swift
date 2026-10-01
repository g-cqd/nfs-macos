import Foundation
import Testing

@testable import FarCry2Core
@testable import LauncherCore

struct FarCry2BackupsTests {
  private func prepared() throws -> (FarCry2Fixture, FarCry2Backups) {
    let fixture = try FarCry2Fixture()
    try fixture.user.install()
    try fixture.write("profile v1", to: fixture.user.profileFile)
    try fixture.write(
      "career v1", to: fixture.user.documents.appendingPathComponent("Saved Games/a.sav"))
    try fixture.write(
      "keys v1", to: fixture.user.localData.appendingPathComponent("InputUserActionMap.xml"))
    return (fixture, FarCry2Backups(paths: fixture.paths))
  }

  @Test
  func `a backup copies settings, saves and input map and lists newest first`() throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    #expect(try backups.list().isEmpty)
    let first = try backups.create(label: "Manual backup")
    #expect(first.files == 3)
    #expect(first.bytes == "profile v1".utf8.count + "career v1".utf8.count + "keys v1".utf8.count)
    let second = try backups.create(label: "Second")
    #expect(try backups.list().map(\.id) == [second.id, first.id])
  }

  @Test
  func `restore replaces current data and first saves what it replaces`() throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    let original = try backups.create(label: "Original")
    try fixture.write("profile v2", to: fixture.user.profileFile)
    try fixture.write(
      "career v2", to: fixture.user.documents.appendingPathComponent("Saved Games/b.sav"))
    let listed = try backups.perform(.init(action: .restore, id: original.id))
    #expect(try fixture.read(fixture.user.profileFile) == "profile v1")
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.user.documents.appendingPathComponent("Saved Games/b.sav").path))
    #expect(listed.count == 2)
    let safety = try #require(listed.first { $0.label == "Before restoring a backup" })
    try fixture.write("scratch", to: fixture.user.profileFile)
    try backups.perform(.init(action: .restore, id: safety.id))
    #expect(try fixture.read(fixture.user.profileFile) == "profile v2")
    #expect(
      try fixture.read(fixture.user.documents.appendingPathComponent("Saved Games/b.sav"))
        == "career v2")
  }

  @Test
  func `the Wine link still reaches restored data`() throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    let original = try backups.create(label: "Original")
    try fixture.write("profile v2", to: fixture.user.profileFile)
    try backups.perform(.init(action: .restore, id: original.id))
    let viaWine = fixture.wineProfile.appendingPathComponent(
      "Documents/My Games/Far Cry 2/GamerProfile.xml")
    #expect(try fixture.read(viaWine) == "profile v1")
  }

  @Test
  func `removing a backup deletes only that backup`() throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    let first = try backups.create(label: "One")
    let second = try backups.create(label: "Two")
    try backups.perform(.init(action: .remove, id: first.id))
    #expect(try backups.list().map(\.id) == [second.id])
    #expect(try fixture.read(fixture.user.profileFile) == "profile v1")
  }

  @Test
  func `enforces the backup limit`() throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    for index in 0..<FarCry2Backups.limit { _ = try backups.create(label: "b\(index)") }
    #expect(throws: LauncherError.self) { try backups.create(label: "one too many") }
    #expect(throws: LauncherError.self) { try backups.perform(.init(action: .create)) }
    #expect(try backups.list().count == FarCry2Backups.limit)
  }

  @Test(arguments: [nil, "", "../escape", "not-a-uuid", "00000000-0000-0000-0000-000000000000"])
  func `rejects invalid or unknown backup ids`(id: String?) throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    #expect(throws: LauncherError.self) { try backups.perform(.init(action: .restore, id: id)) }
    #expect(throws: LauncherError.self) { try backups.perform(.init(action: .remove, id: id)) }
    #expect(try fixture.read(fixture.user.profileFile) == "profile v1")
  }

  @Test
  func `links inside player data stop a backup and leave no partial copy`() throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    try FileManager.default.createSymbolicLink(
      at: fixture.user.documents.appendingPathComponent("Saved Games/link"),
      withDestinationURL: fixture.root)
    #expect(throws: LauncherError.self) { try backups.create(label: "linked") }
    #expect(try backups.list().isEmpty)
    let leftovers = try FileManager.default.contentsOfDirectory(
      at: backups.root, includingPropertiesForKeys: nil)
    #expect(leftovers.isEmpty)
  }

  @Test
  func `a damaged backup record is skipped and never trusted`() throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    let good = try backups.create(label: "Good")
    let bad = try backups.create(label: "Bad")
    try Data("{".utf8).write(to: backups.root.appendingPathComponent(bad.id + "/backup.json"))
    #expect(try backups.list().map(\.id) == [good.id])
    #expect(throws: LauncherError.self) { try backups.perform(.init(action: .restore, id: bad.id)) }
  }

  @Test
  func `recovery completes or reverses an interrupted restore`() throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    let documents = fixture.user.documents
    let parent = documents.deletingLastPathComponent()
    // Interrupted after moving the live folder aside but before the replacement arrived.
    try FileManager.default.moveItem(
      at: documents, to: parent.appendingPathComponent("Documents.replaced-X"))
    try FileManager.default.createDirectory(
      at: parent.appendingPathComponent("Documents.restoring-X"), withIntermediateDirectories: true)
    try backups.recover()
    #expect(try fixture.read(fixture.user.profileFile) == "profile v1")
    let names = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
    #expect(names == ["Documents", "LocalAppData"])
    // Interrupted after the replacement arrived but before the old folder was deleted.
    try FileManager.default.createDirectory(
      at: parent.appendingPathComponent("Documents.replaced-Y"), withIntermediateDirectories: true)
    try backups.recover()
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() == names)
  }

  @Test
  func `unfinished staging folders are removed`() throws {
    let (fixture, backups) = try prepared()
    defer { fixture.remove() }
    let stage = backups.root.appendingPathComponent(".staging-abc")
    try fixture.write("partial", to: stage.appendingPathComponent("x"))
    try backups.recover()
    #expect(!FileManager.default.fileExists(atPath: stage.path))
  }
}
