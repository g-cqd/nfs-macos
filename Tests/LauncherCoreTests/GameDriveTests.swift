import Foundation
import Testing

@testable import LauncherCore

struct GameDriveTests {
  private struct Fixture {
    let root: URL
    let paths: AppPaths
    var mapping: URL { paths.prefix.appendingPathComponent("dosdevices/g:") }

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath()
      paths = try AppPaths(
        bundle: root.appendingPathComponent("Far Cry 2.app"),
        support: root.appendingPathComponent("Support"), game: .farcry2)
      for directory in [mapping.deletingLastPathComponent(), paths.currentGame] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
    }

    func remove() {
      do { try FileManager.default.removeItem(at: root) } catch { print(error) }
    }
  }

  @Test
  func `maps only the private game and is removed after play`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let drive = GameDrive(paths: fixture.paths)
    try drive.install()
    #expect(fixture.mapping.resolvingSymlinksInPath() == fixture.paths.currentGame)
    #expect(throws: LauncherError.self) { try drive.install() }
    try drive.remove()
    #expect(!FileManager.default.fileExists(atPath: fixture.mapping.path))
  }

  @Test
  func `a game target outside the player folder is refused`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let files = FileManager.default
    try files.removeItem(at: fixture.paths.currentGame)
    try files.createSymbolicLink(at: fixture.paths.currentGame, withDestinationURL: fixture.root)
    #expect(throws: LauncherError.self) { try GameDrive(paths: fixture.paths).install() }
    #expect(!files.fileExists(atPath: fixture.mapping.path))
  }

  @Test
  func `an unrelated mapping is never removed`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let files = FileManager.default
    try files.createSymbolicLink(at: fixture.mapping, withDestinationURL: fixture.root)
    let drive = GameDrive(paths: fixture.paths)
    #expect(throws: LauncherError.self) { try drive.remove() }
    try drive.removeStale()
    #expect(try files.destinationOfSymbolicLink(atPath: fixture.mapping.path) == fixture.root.path)
  }

  @Test
  func `a mapping left by an interrupted session is cleaned up and absence is fine`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let drive = GameDrive(paths: fixture.paths)
    try drive.removeStale()
    try drive.install()
    try drive.removeStale()
    #expect(!FileManager.default.fileExists(atPath: fixture.mapping.path))
  }
}
