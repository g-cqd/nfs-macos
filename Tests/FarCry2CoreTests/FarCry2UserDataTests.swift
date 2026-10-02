import Foundation
import Testing

@testable import FarCry2Core
@testable import LauncherCore

struct FarCry2UserDataTests {
  @Test
  func `links both player folders into the single Wine profile`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    let outcome = try fixture.user.install()
    #expect(outcome == FarCry2UserData.Outcome(migrated: [], conflicts: []))
    let documents = fixture.wineProfile.appendingPathComponent("Documents/My Games/Far Cry 2")
    let local = fixture.wineProfile.appendingPathComponent("AppData/Local/My Games/Far Cry 2")
    try fixture.write("saved", to: documents.appendingPathComponent("Saved Games/slot1.sav"))
    try fixture.write("input", to: local.appendingPathComponent("InputUserActionMap.xml"))
    #expect(
      try fixture.read(fixture.user.documents.appendingPathComponent("Saved Games/slot1.sav"))
        == "saved")
    #expect(
      try fixture.read(fixture.user.localData.appendingPathComponent("InputUserActionMap.xml"))
        == "input")
    #expect(documents.resolvingSymlinksInPath() == fixture.user.documents.resolvingSymlinksInPath())
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: documents.path)
    #expect(!destination.hasPrefix("/"), "links are relative so the player folder can move")
  }

  @Test
  func `is idempotent`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    try fixture.user.install()
    try fixture.write("x", to: fixture.user.documents.appendingPathComponent("GamerProfile.xml"))
    #expect(try fixture.user.install() == FarCry2UserData.Outcome(migrated: [], conflicts: []))
    #expect(try fixture.read(fixture.user.profileFile) == "x")
  }

  @Test
  func `a rebuilt prefix keeps saves because they live outside it`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    try fixture.user.install()
    try fixture.write(
      "career", to: fixture.user.documents.appendingPathComponent("Saved Games/a.sav"))
    try FileManager.default.removeItem(at: fixture.paths.prefix)
    try fixture.buildPrefix()
    try fixture.user.install()
    let visible = fixture.wineProfile.appendingPathComponent(
      "Documents/My Games/Far Cry 2/Saved Games/a.sav")
    #expect(try fixture.read(visible) == "career")
  }

  @Test
  func `moves an existing real folder into persistent storage`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    let existing = fixture.wineProfile.appendingPathComponent("Documents/My Games/Far Cry 2")
    try fixture.write("old profile", to: existing.appendingPathComponent("GamerProfile.xml"))
    let outcome = try fixture.user.install()
    #expect(outcome.migrated == ["Documents/My Games/Far Cry 2"])
    #expect(outcome.conflicts.isEmpty)
    #expect(try fixture.read(fixture.user.profileFile) == "old profile")
    #expect(try fixture.read(existing.appendingPathComponent("GamerProfile.xml")) == "old profile")
  }

  @Test
  func `never deletes a real folder that conflicts with existing persistent data`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    try fixture.write("kept", to: fixture.user.documents.appendingPathComponent("GamerProfile.xml"))
    let existing = fixture.wineProfile.appendingPathComponent("Documents/My Games/Far Cry 2")
    try fixture.write("other", to: existing.appendingPathComponent("stray.txt"))
    let outcome = try fixture.user.install()
    #expect(outcome.conflicts == ["Documents/My Games/Far Cry 2"])
    #expect(try fixture.read(fixture.user.profileFile) == "kept")
    let aside = try FileManager.default.contentsOfDirectory(
      at: fixture.user.conflicts, includingPropertiesForKeys: nil)
    #expect(aside.count == 1)
    #expect(try fixture.read(aside[0].appendingPathComponent("stray.txt")) == "other")
  }

  @Test
  func `reports how many folders were kept aside so the player can be told`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    #expect(try fixture.user.keptAside() == 0)
    try fixture.write("kept", to: fixture.user.documents.appendingPathComponent("GamerProfile.xml"))
    let existing = fixture.wineProfile.appendingPathComponent("Documents/My Games/Far Cry 2")
    try fixture.write("other", to: existing.appendingPathComponent("stray.txt"))
    try fixture.user.install()
    #expect(try fixture.user.keptAside() == 1)
  }

  @Test
  func `finds the profile whatever Wine named it and rejects ambiguity`() throws {
    let named = try FarCry2Fixture(profileName: "Player")
    defer { named.remove() }
    #expect(try named.user.windowsProfile().lastPathComponent == "Player")
    let ambiguous = try FarCry2Fixture(extraProfiles: ["second"])
    defer { ambiguous.remove() }
    #expect(throws: LauncherError.self) { try ambiguous.user.windowsProfile() }
    #expect(throws: LauncherError.self) { try ambiguous.user.install() }
  }

  @Test
  func `refuses to follow a host alias that guest isolation should have removed`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    let documents = fixture.wineProfile.appendingPathComponent("Documents")
    try FileManager.default.removeItem(at: documents)
    try FileManager.default.createSymbolicLink(at: documents, withDestinationURL: fixture.root)
    #expect(throws: LauncherError.self) { try fixture.user.install() }
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("My Games").path),
      "nothing may be created through the alias")
  }

  @Test
  func `a link that points somewhere unexpected is left untouched`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    let folder = fixture.wineProfile.appendingPathComponent("Documents/My Games")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: folder.appendingPathComponent("Far Cry 2"), withDestinationURL: fixture.root)
    #expect(throws: LauncherError.self) { try fixture.user.install() }
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: folder.appendingPathComponent("Far Cry 2").path) == fixture.root.path)
  }

  @Test
  func `a file where the folder belongs is refused`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    try fixture.write(
      "x", to: fixture.wineProfile.appendingPathComponent("Documents/My Games/Far Cry 2"))
    #expect(throws: LauncherError.self) { try fixture.user.install() }
  }

  @Test(arguments: [
    ("/a/b/c", "/a/b/c", ""), ("/a/b/c", "/a/b", ".."), ("/a/b/c", "/a/x/y", "../../x/y"),
    ("/a", "/a/b/c", "b/c"),
  ])
  func `relative paths between resolved folders`(from: String, to: String, expected: String) {
    #expect(
      FarCry2UserData.relativePath(from: URL(fileURLWithPath: from), to: URL(fileURLWithPath: to))
        == expected)
  }
}
