import Foundation
import Testing

@testable import LauncherCore

struct SessionLockTests {
  @Test
  func `only one session can own a player folder`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.paths.support, withIntermediateDirectories: true)
    let path = fixture.paths.support.appendingPathComponent("session.lock")
    try SessionLock.withLock(at: path) { () -> Void in
      #expect(throws: LauncherError.alreadyRunning) {
        try SessionLock.withLock(at: path) {}
      }
    }
    #expect(throws: Never.self) { try SessionLock.withLock(at: path) {} }
  }

  @Test
  func `failed session releases its lock`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let path = fixture.root.appendingPathComponent("session.lock")
    #expect(throws: LauncherError.operation("failure")) {
      try SessionLock.withLock(at: path) { throw LauncherError.operation("failure") }
    }
    #expect(throws: Never.self) { try SessionLock.withLock(at: path) {} }
  }

  @Test
  func `never follows a substituted lock symlink`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let target = fixture.root.appendingPathComponent("untouched")
    try Data("private".utf8).write(to: target)
    let lock = fixture.root.appendingPathComponent("session.lock")
    try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
    #expect(throws: LauncherError.self) { try SessionLock.withLock(at: lock) {} }
    #expect(try Data(contentsOf: target) == Data("private".utf8))
  }
}
