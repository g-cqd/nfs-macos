import Darwin
import Foundation
import Testing

@testable import LauncherCore

struct GameLeaseTests {
  @Test
  func `a surviving game remains protected after its helper exits`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let sut = GameLease(url: fixture.root.appendingPathComponent("game.json"))
    try sut.record(process: getpid())
    #expect(throws: LauncherError.alreadyRunning) { try sut.check() }
    try sut.clear()
    #expect(throws: Never.self) { try sut.check() }
  }

  @Test
  func `a reused process number does not keep an old session alive`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let path = fixture.root.appendingPathComponent("game.json")
    let stale = ProcessIdentity(pid: getpid(), seconds: 1, microseconds: 0)
    try JSONEncoder().encode(stale).write(to: path)
    let sut = GameLease(url: path)
    #expect(throws: Never.self) { try sut.check() }
    #expect(!FileManager.default.fileExists(atPath: path.path))
  }

  @Test
  func `the running game is found only while it is the recorded process`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let path = fixture.root.appendingPathComponent("game.json")
    let sut = GameLease(url: path)
    #expect(sut.activeProcess() == nil, "no record, no game")
    try sut.record(process: getpid())
    #expect(sut.activeProcess() == getpid())
    let stale = ProcessIdentity(pid: getpid(), seconds: 1, microseconds: 0)
    try JSONEncoder().encode(stale).write(to: path)
    #expect(sut.activeProcess() == nil, "a reused process number is never activated")
    try Data("not json".utf8).write(to: path)
    #expect(sut.activeProcess() == nil)
    try sut.clear()
    #expect(sut.activeProcess() == nil)
  }

  @Test(arguments: [-1, 0])
  func `rejects invalid process identifiers`(pid: Int32) {
    #expect(throws: LauncherError.self) { try ProcessIdentity.read(pid: pid) }
  }

  @Test
  func `rejects a corrupt session record`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let path = fixture.root.appendingPathComponent("game.json")
    try Data("invalid".utf8).write(to: path)
    #expect(throws: LauncherError.self) { try GameLease(url: path).check() }
  }
}
