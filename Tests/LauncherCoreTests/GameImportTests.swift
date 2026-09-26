import CryptoKit
import Foundation
import Testing

@testable import LauncherCore

struct GameImportTests {
  @Test
  func `import initializes without bundled assets and keeps compatibility files`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("My installation")
    try FileManager.default.copyItem(at: fixture.paths.template, to: source)
    try FileManager.default.removeItem(
      at: fixture.paths.template.appendingPathComponent("speed.exe"))
    let compatibility = Data("trusted compatibility loader".utf8)
    try compatibility.write(to: fixture.paths.template.appendingPathComponent("dinput8.dll"))
    try Data("untrusted override".utf8).write(to: source.appendingPathComponent("dinput8.dll"))
    let manifest = BundleManifest(
      version: "v1",
      gameFiles: fixture.manifest.gameFiles + [
        ManifestFile(
          path: "dinput8.dll", size: compatibility.count,
          sha256: SHA256.hash(data: compatibility).map { String(format: "%02x", $0) }.joined())
      ])
    let sut = GameInstaller(paths: fixture.paths, manifest: manifest)
    let game = try sut.prepare(importing: source) { prefix in
      try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }
    #expect(
      try Data(contentsOf: game.appendingPathComponent("speed.exe")) == Data("test executable".utf8)
    )
    #expect(try Data(contentsOf: game.appendingPathComponent("dinput8.dll")) == compatibility)
    try FileManager.default.removeItem(at: source)
    let again = try sut.prepare { _ in throw LauncherError.operation("Must preserve prefix") }
    #expect(game == again)
  }

  @Test
  func `import preserves careers and settings and publishes a new generation`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let sut = GameInstaller(paths: fixture.paths, manifest: fixture.manifest)
    let original = try sut.prepare { prefix in
      try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }
    let save = fixture.paths.saves.appendingPathComponent("latest career")
    try Data("progress".utf8).write(to: save)
    try Data("cap120".utf8).write(to: original.appendingPathComponent("mtld3d.conf"))
    let imported = try sut.prepare(importing: fixture.paths.template) { _ in
      throw LauncherError.operation("Must preserve prefix")
    }
    #expect(imported != original)
    #expect(try Data(contentsOf: save) == Data("progress".utf8))
    #expect(
      try String(contentsOf: imported.appendingPathComponent("mtld3d.conf"), encoding: .utf8)
        == "cap120")
    #expect(fixture.paths.currentGame.resolvingSymlinksInPath() == imported)
    let next = try GameInstaller(
      paths: fixture.paths,
      manifest: BundleManifest(version: "v2", gameFiles: fixture.manifest.gameFiles)
    ).prepare { _ in
      throw LauncherError.operation("Must preserve prefix")
    }
    #expect(next != imported)
    #expect(
      try Data(contentsOf: next.appendingPathComponent("speed.exe")) == Data("test executable".utf8)
    )
    #expect(try Data(contentsOf: save) == Data("progress".utf8))
  }

  @Test(arguments: ["missing", "size", "digest", "link"])
  func `invalid import keeps the active game intact`(kind: String) throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let sut = GameInstaller(paths: fixture.paths, manifest: fixture.manifest)
    let original = try sut.prepare { prefix in
      try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }
    let source = fixture.root.appendingPathComponent("Invalid installation")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let executable = source.appendingPathComponent("speed.exe")
    switch kind {
    case "size": try Data("short".utf8).write(to: executable)
    case "digest": try Data("bad! executable".utf8).write(to: executable)
    case "link":
      try FileManager.default.createSymbolicLink(
        at: executable,
        withDestinationURL: fixture.paths.template.appendingPathComponent("speed.exe"))
    default: break
    }
    #expect(throws: LauncherError.self) {
      try sut.prepare(importing: source) { _ in
        throw LauncherError.operation("Must preserve prefix")
      }
    }
    #expect(fixture.paths.currentGame.resolvingSymlinksInPath() == original)
    #expect(
      try Data(contentsOf: original.appendingPathComponent("speed.exe"))
        == Data("test executable".utf8))
  }
}

extension GameImportTests {
  @Test
  func `missing bundled data requires import until a working copy is installed`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    #expect(fixture.paths.hasGameData)
    let source = fixture.root.appendingPathComponent("Own game")
    try FileManager.default.copyItem(at: fixture.paths.template, to: source)
    try FileManager.default.removeItem(at: fixture.paths.template)
    #expect(!fixture.paths.hasGameData)
    _ = try GameInstaller(paths: fixture.paths, manifest: fixture.manifest).prepare(
      importing: source
    ) { prefix in
      try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }
    #expect(fixture.paths.hasGameData)
  }
}
