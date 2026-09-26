import Foundation
import Testing

@testable import LauncherCore

struct ProfileLifecycleTests {
  @Test func `creates a separately named profile without changing the template`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let template = fixture.paths.resources.appendingPathComponent("Defaults/FreshCareer.save")
    try FileManager.default.createDirectory(
      at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = try CareerSaveTests.fixture()
    try original.write(to: template)
    try FileManager.default.createDirectory(
      at: fixture.paths.support, withIntermediateDirectories: true)
    let sut = SaveStore(paths: fixture.paths)
    try sut.perform(.create(profile: "NewDriver"))
    let profile = try #require(sut.profiles().first)
    let save = try CareerSave(BoundedFile.read(sut.profileURL(profile.id)))
    #expect(save.alias == "NewDriver")
    #expect(save.cash == 1000)
    #expect(try BoundedFile.read(template) == original)
    #expect(throws: LauncherError.self) { try sut.perform(.create(profile: "newdriver")) }
    #expect(try sut.profiles().count == 1)
  }

  @Test(arguments: ["", "../escape", "TooLongProfileName", "Gígi"])
  func `rejects unsupported new profile names`(name: String) throws {
    let sut = try CareerSave(CareerSaveTests.fixture())
    #expect(throws: LauncherError.self) { try sut.renamed(name) }
  }

  @Test func `removal retains a discoverable backup and can restore the exact save`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.paths.support, withIntermediateDirectories: true)
    let sut = SaveStore(paths: fixture.paths)
    let bytes = try CareerSaveTests.fixture()
    try sut.perform(.replace(profile: "TestDriver", data: bytes, expected: nil))
    let before = try #require(sut.profiles().first)
    #expect(throws: LauncherError.self) {
      try sut.perform(.remove(profile: before.id, expected: "stale"))
    }
    try sut.perform(.remove(profile: before.id, expected: before.fingerprint))
    #expect(!FileManager.default.fileExists(atPath: try sut.profileURL(before.id).path))
    let removed = try #require(sut.profiles().first)
    #expect(removed.isRemoved)
    let backup = try #require(removed.backups.first)
    try sut.perform(.restore(profile: before.id, name: backup, expected: nil))
    #expect(try BoundedFile.read(sut.profileURL(before.id)) == bytes)
    #expect(try sut.profiles().first?.isRemoved == false)
  }
}
