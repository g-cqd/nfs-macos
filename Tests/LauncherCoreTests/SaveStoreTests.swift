import Foundation
import Testing

@testable import LauncherCore

struct SaveStoreTests {
  @Test func `import and cheat preserve recoverable originals and reject stale edits`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.paths.support, withIntermediateDirectories: true)
    let sut = SaveStore(paths: fixture.paths)
    let original = try CareerSaveTests.fixture()
    try sut.perform(.replace(profile: "TestDriver", data: original, expected: nil))
    let before = try #require(sut.profiles().first)
    try sut.perform(
      .cheat(
        profile: before.id, expected: before.fingerprint,
        action: .money(operation: .add, amount: 50)))
    let after = try #require(sut.profiles().first)
    #expect(after.cash == 1050)
    let backup = try #require(sut.backups(profile: before.id).first)
    #expect(try BoundedFile.read(sut.backupURL(profile: before.id, name: backup)) == original)
    #expect(throws: LauncherError.self) {
      try sut.perform(
        .cheat(
          profile: before.id, expected: before.fingerprint,
          action: .money(operation: .add, amount: 50)))
    }
    #expect(try sut.profiles().first?.cash == 1050)
  }

  @Test func `path traversal and corrupt imports leave no save`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.paths.support, withIntermediateDirectories: true)
    let sut = SaveStore(paths: fixture.paths)
    #expect(throws: LauncherError.self) {
      try sut.perform(
        .replace(profile: "../outside", data: CareerSaveTests.fixture(), expected: nil))
    }
    #expect(throws: LauncherError.self) {
      try sut.perform(.replace(profile: "TestDriver", data: Data(), expected: nil))
    }
    #expect(try sut.profiles().isEmpty)
  }
}
