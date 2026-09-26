import Foundation
import Testing

@testable import LauncherCore

struct FileTransactionTests {
  @Test func `invalid recovery journal cannot partially restore files`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let first = fixture.root.appendingPathComponent("first")
    try Data("current".utf8).write(to: first)
    let journal =
      "[{\"path\":\"first\",\"bytes\":\"b2xk\"},{\"path\":\"../outside\",\"bytes\":\"b2xk\"}]"
    try Data(journal.utf8).write(
      to: fixture.root.appendingPathComponent("configuration-transaction.json"))
    #expect(throws: LauncherError.self) { try FileTransaction(root: fixture.root).recover() }
    #expect(try Data(contentsOf: first) == Data("current".utf8))
  }
  @Test func `failed multi file update restores every original`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let root = fixture.root
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    try Data("original".utf8).write(to: first)
    var writes = 0
    #expect(throws: LauncherError.self) {
      try FileTransaction(root: root).apply([
        FileChange(url: first, bytes: Data("changed".utf8)),
        FileChange(url: second, bytes: Data("new".utf8)),
      ]) { data, url in
        writes += 1
        if writes == 2 { throw LauncherError.operation("Injected write failure") }
        try data.write(to: url, options: .atomic)
      }
    }
    #expect(try Data(contentsOf: first) == Data("original".utf8))
    #expect(!FileManager.default.fileExists(atPath: second.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("configuration-transaction.json").path))
  }

  @Test func `rejects escaping and duplicate file targets before writing`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let sut = FileTransaction(root: fixture.root)
    let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("escape")
    #expect(throws: LauncherError.self) { try sut.apply([FileChange(url: outside, bytes: Data())]) }
    let file = FileChange(url: fixture.root.appendingPathComponent("inside"), bytes: Data())
    #expect(throws: LauncherError.self) { try sut.apply([file, file]) }
  }
}
