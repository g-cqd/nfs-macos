import Foundation
import LauncherCore
import Testing

@testable import CoD4Core

struct CoD4GameDriveTests {
  @Test
  func `game drive maps only the private game and is removed after play`() throws {
    let fixture = try CoD4DriveFixture()
    defer { fixture.remove() }
    let drive = CoD4GameDrive(paths: fixture.paths)
    try drive.install()
    #expect(fixture.mapping.resolvingSymlinksInPath() == fixture.paths.currentGame)
    #expect(throws: Error.self) { try drive.install() }
    try drive.remove()
    #expect(!FileManager.default.fileExists(atPath: fixture.mapping.path))
  }

  @Test
  func `external game targets are rejected and existing mappings are preserved`() throws {
    let fixture = try CoD4DriveFixture()
    defer { fixture.remove() }
    let files = FileManager.default
    let drive = CoD4GameDrive(paths: fixture.paths)
    try files.removeItem(at: fixture.paths.currentGame)
    try files.createSymbolicLink(at: fixture.paths.currentGame, withDestinationURL: fixture.root)
    #expect(throws: Error.self) { try drive.install() }
    #expect(!files.fileExists(atPath: fixture.mapping.path))
    try files.createSymbolicLink(at: fixture.mapping, withDestinationURL: fixture.root)
    #expect(throws: Error.self) { try drive.remove() }
    #expect(try files.destinationOfSymbolicLink(atPath: fixture.mapping.path) == fixture.root.path)
  }
}

private struct CoD4DriveFixture {
  let root: URL
  let paths: AppPaths
  var mapping: URL { paths.prefix.appendingPathComponent("dosdevices/g:") }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    paths = try AppPaths(
      bundle: root.appendingPathComponent("CoD4.app"),
      support: root.appendingPathComponent("Support"), game: .cod4)
    for directory in [mapping.deletingLastPathComponent(), paths.currentGame] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  func remove() {
    do { try FileManager.default.removeItem(at: root) } catch { print(error) }
  }
}
