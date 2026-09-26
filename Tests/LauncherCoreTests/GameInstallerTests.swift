import CryptoKit
import Foundation
import Testing

@testable import LauncherCore

struct GameInstallerTests {
  @Test
  func `new generation preserves the previous game and shared career`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let sut = GameInstaller(paths: fixture.paths, manifest: fixture.manifest)
    let oldGame = try sut.prepare { prefix in
      try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }
    let save = fixture.paths.saves.appendingPathComponent("career")
    try Data("latest race".utf8).write(to: save)
    try Data("custom cap".utf8).write(to: oldGame.appendingPathComponent("mtld3d.conf"))
    let profileMap = "scripts/XtendedInputMaps/Player One/NFS_XtendedInput.usermap.ini"
    let oldMap = oldGame.appendingPathComponent(profileMap)
    try FileManager.default.createDirectory(
      at: oldMap.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bindings = Data("[Events]\nTHROTTLE=R2\nBRAKE=L2\n".utf8)
    try bindings.write(to: oldMap)
    let updated = BundleManifest(version: "v2", gameFiles: fixture.manifest.gameFiles)
    let newGame = try GameInstaller(paths: fixture.paths, manifest: updated).prepare { _ in
      throw LauncherError.operation("Existing prefix must be preserved")
    }
    #expect(newGame != oldGame)
    #expect(
      FileManager.default.fileExists(atPath: oldGame.appendingPathComponent("speed.exe").path))
    #expect(try Data(contentsOf: save) == Data("latest race".utf8))
    #expect(
      try String(contentsOf: newGame.appendingPathComponent("mtld3d.conf"), encoding: .utf8)
        == "custom cap")
    #expect(try Data(contentsOf: newGame.appendingPathComponent(profileMap)) == bindings)
    #expect(try Data(contentsOf: oldMap) == bindings)
    #expect(
      fixture.paths.currentGame.resolvingSymlinksInPath() == newGame.resolvingSymlinksInPath())
  }

  @Test
  func `a failed game update leaves the previous generation active`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let oldGame = try GameInstaller(paths: fixture.paths, manifest: fixture.manifest).prepare {
      prefix in
      try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }
    try Data("invalid".utf8).write(to: fixture.paths.template.appendingPathComponent("speed.exe"))
    let updated = BundleManifest(version: "v2", gameFiles: fixture.manifest.gameFiles)
    #expect(throws: LauncherError.self) {
      try GameInstaller(paths: fixture.paths, manifest: updated).prepare { _ in }
    }
    #expect(
      fixture.paths.currentGame.resolvingSymlinksInPath() == oldGame.resolvingSymlinksInPath())
  }
  @Test
  func `failed prefix initialization never publishes player data`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let sut = GameInstaller(paths: fixture.paths, manifest: fixture.manifest)
    #expect(throws: LauncherError.self) {
      try sut.prepare { _ in throw LauncherError.operation("Injected setup failure") }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
    let retry = try sut.prepare { prefix in
      try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }
    #expect(FileManager.default.fileExists(atPath: retry.appendingPathComponent("speed.exe").path))
  }

  @Test
  func `repeat launch preserves saves and edited settings`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let sut = GameInstaller(paths: fixture.paths, manifest: fixture.manifest)
    let game = try sut.prepare { prefix in
      try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }
    let save = fixture.paths.saves.appendingPathComponent("My career")
    try Data("new progress".utf8).write(to: save)
    try Data("my settings".utf8).write(to: game.appendingPathComponent("mtld3d.conf"))
    let again = try sut.prepare { _ in throw LauncherError.operation("Must not initialize again") }
    #expect(again == game)
    #expect(try Data(contentsOf: save) == Data("new progress".utf8))
    #expect(
      try String(contentsOf: again.appendingPathComponent("mtld3d.conf"), encoding: .utf8)
        == "my settings")
  }

  @Test
  func `rejects corrupt game assets before prefix initialization`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try Data("corrupt".utf8).write(to: fixture.paths.template.appendingPathComponent("speed.exe"))
    #expect(throws: LauncherError.self) {
      try GameInstaller(paths: fixture.paths, manifest: fixture.manifest).prepare { _ in
        throw LauncherError.operation("Unexpected initialization")
      }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
  }

  @Test(arguments: ["../outside", "/absolute", "a/../../bad", "a\\bad", "", "a//b"])
  func `rejects unsafe manifest paths`(path: String) {
    #expect(throws: LauncherError.self) { try ManifestFile.validate(path: path) }
  }
}
