import CryptoKit
import Foundation
import Testing

@testable import LauncherCore

struct GameKindTests {
  @Test
  func `cod4 generation keeps player files outside replaceable assets`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
      bundle: root.appendingPathComponent("Game.app"),
      support: root.appendingPathComponent("Player"), game: .cod4)
    try FileManager.default.createDirectory(at: paths.template, withIntermediateDirectories: true)
    let data = Data("test executable".utf8)
    let files = try ["iw3sp.exe", "iw3mp.exe"].map { name in
      try data.write(to: paths.template.appendingPathComponent(name))
      return ManifestFile(
        path: name, size: data.count,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    let manifest = BundleManifest(version: "one", gameFiles: files, gameID: .cod4)
    let game = try GameInstaller(paths: paths, manifest: manifest).prepare { prefix in
      try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }
    #expect(paths.hasGameData)
    #expect(game.appendingPathComponent("players").resolvingSymlinksInPath() == paths.saves)
    try Data("progress".utf8).write(to: paths.saves.appendingPathComponent("progress"))
    let next = try GameInstaller(
      paths: paths, manifest: BundleManifest(version: "two", gameFiles: files, gameID: .cod4)
    ).prepare { _ in
      throw LauncherError.operation("The prefix must survive updates")
    }
    #expect(next.appendingPathComponent("players").resolvingSymlinksInPath() == paths.saves)
    #expect(
      try Data(contentsOf: paths.saves.appendingPathComponent("progress")) == Data("progress".utf8))
    #expect(paths.session.lastPathComponent == "CoD4Session")
    try Data("modified working game".utf8).write(to: next.appendingPathComponent("iw3sp.exe"))
    #expect(try Data(contentsOf: paths.template.appendingPathComponent("iw3sp.exe")) == data)
  }

  @Test
  func `installer rejects a manifest for another game`() throws {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/unused.app"), support: URL(fileURLWithPath: "/unused-player"),
      game: .cod4)
    let manifest = BundleManifest(
      version: "one",
      gameFiles: [
        ManifestFile(path: "speed.exe", size: 0, sha256: String(repeating: "0", count: 64))
      ])
    #expect(throws: LauncherError.self) {
      try GameInstaller(paths: paths, manifest: manifest).prepare { _ in }
    }
  }
}
