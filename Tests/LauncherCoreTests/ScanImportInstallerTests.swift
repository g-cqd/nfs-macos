import CryptoKit
import Foundation
import GameFixtures
import Testing

@testable import LauncherCore

/// Import-only apps ship no game bytes: the installation is recognised and hashed on the player's Mac.
struct ScanImportInstallerTests {
  private struct Fixture {
    let install: SyntheticInstall
    let paths: AppPaths
    let manifest: BundleManifest
    let compatibility: Data

    init(version: String = "v1") throws {
      install = try SyntheticInstall()
      let root = install.root
      paths = try AppPaths(
        bundle: root.appendingPathComponent("Far Cry 2.app"),
        support: root.appendingPathComponent("Player"), game: .farcry2)
      compatibility = Data("shader.asyncCompile = false\n".utf8)
      try FileManager.default.createDirectory(
        at: paths.template.appendingPathComponent("bin"), withIntermediateDirectories: true)
      try compatibility.write(to: paths.template.appendingPathComponent("bin/mtld3d.conf"))
      manifest = try Fixture.manifest(version: version, compatibility: compatibility)
    }

    static func manifest(version: String, compatibility: Data) throws -> BundleManifest {
      BundleManifest(
        version: version,
        gameFiles: [
          ManifestFile(
            path: "bin/mtld3d.conf", size: compatibility.count,
            sha256: SHA256.hash(data: compatibility).map { String(format: "%02x", $0) }.joined())
        ], gameID: .farcry2, importRules: try RecipeRules.farCry2Scaled())
    }

    func installer(_ manifest: BundleManifest? = nil) -> GameInstaller {
      GameInstaller(paths: paths, manifest: manifest ?? self.manifest)
    }

    func prefix(_ url: URL) throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { install.cleanup() }
  }

  @Test
  func `importing copies recognised files, keeps app-owned renderer config, and records the build`()
    throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try Data("player override".utf8).write(to: fixture.install.url("bin/mtld3d.conf"))
    let game = try fixture.installer().prepare(importing: fixture.install.install) {
      try fixture.prefix($0)
    }
    #expect(fixture.paths.hasGameData)
    #expect(
      try Data(contentsOf: game.appendingPathComponent("bin/Dunia.dll"))
        == Data("synthetic engine library".utf8))
    #expect(
      try Data(contentsOf: game.appendingPathComponent("bin/mtld3d.conf")) == fixture.compatibility)
    #expect(
      !FileManager.default.fileExists(atPath: game.appendingPathComponent("unins000.exe").path))
    #expect(!FileManager.default.fileExists(atPath: game.appendingPathComponent("Support").path))
    let installed = try #require(GameInstaller.installedGame(paths: fixture.paths))
    #expect(installed.fileVersion == "1.0.3.0")
    #expect(installed.markers == ["gog"])
    #expect(installed.build == nil)
    let prefixLink = fixture.paths.prefix.appendingPathComponent("drive_c/FarCry2")
    #expect(
      prefixLink.resolvingSymlinksInPath() == fixture.paths.currentGame.resolvingSymlinksInPath())
  }

  @Test
  func `the player's installation is never modified or linked into the copy`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let before = try Data(contentsOf: fixture.install.url("bin/FarCry2.exe"))
    let game = try fixture.installer().prepare(importing: fixture.install.install) {
      try fixture.prefix($0)
    }
    try Data("modified working copy".utf8).write(to: game.appendingPathComponent("bin/FarCry2.exe"))
    #expect(try Data(contentsOf: fixture.install.url("bin/FarCry2.exe")) == before)
  }

  @Test
  func `without an import there is nothing to prepare and no player folder is created`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(!fixture.paths.hasGameData)
    let error = try #require(throws: LauncherError.self) {
      try fixture.installer().prepare { _ in throw LauncherError.operation("must not run") }
    }
    #expect(error.localizedDescription.contains("Import"))
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
  }

  @Test
  func `an app update re-verifies the imported copy from its saved inventory`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try fixture.installer().prepare(importing: fixture.install.install) {
      try fixture.prefix($0)
    }
    try Data("progress".utf8).write(to: fixture.paths.saves.appendingPathComponent("slot"))
    try Data("player cap".utf8).write(to: first.appendingPathComponent("bin/mtld3d.conf"))
    // The original folder may be gone by the time the app updates.
    try FileManager.default.removeItem(at: fixture.install.install)
    let updated = try fixture.installer(
      Fixture.manifest(version: "v2", compatibility: fixture.compatibility)
    ).prepare { _ in throw LauncherError.operation("The prefix must survive updates") }
    #expect(updated != first)
    #expect(
      try Data(contentsOf: updated.appendingPathComponent("Data_Win32/worlds.dat"))
        == Data("worlds payload".utf8))
    #expect(
      try Data(contentsOf: updated.appendingPathComponent("bin/mtld3d.conf"))
        == Data("player cap".utf8),
      "the player's renderer settings survive generation updates")
    #expect(
      try Data(contentsOf: fixture.paths.saves.appendingPathComponent("slot"))
        == Data("progress".utf8))
    #expect(GameInstaller.installedGame(paths: fixture.paths)?.fileVersion == "1.0.3.0")
  }

  @Test
  func `a modified imported file blocks the update and keeps the active generation`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try fixture.installer().prepare(importing: fixture.install.install) {
      try fixture.prefix($0)
    }
    try Data("tampered".utf8).write(to: first.appendingPathComponent("Data_Win32/common.dat"))
    #expect(throws: LauncherError.self) {
      try fixture.installer(
        Fixture.manifest(version: "v2", compatibility: fixture.compatibility)
      ).prepare { _ in throw LauncherError.operation("unused") }
    }
    #expect(fixture.paths.currentGame.resolvingSymlinksInPath() == first)
  }

  @Test(arguments: ["missing executable", "incomplete archive", "link"])
  func `a rejected import keeps the active game and leaves no partial generation`(kind: String)
    throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try fixture.installer().prepare(importing: fixture.install.install) {
      try fixture.prefix($0)
    }
    let broken = try SyntheticInstall()
    defer { broken.cleanup() }
    switch kind {
    case "missing executable": try broken.remove("bin/FarCry2.exe")
    case "incomplete archive": try broken.remove("Data_Win32/common.dat")
    default:
      try FileManager.default.createSymbolicLink(
        at: broken.url("Data_Win32/extra.dat"),
        withDestinationURL: broken.url("Data_Win32/common.dat"))
    }
    #expect(throws: LauncherError.self) {
      try fixture.installer().prepare(importing: broken.install) { _ in
        throw LauncherError.operation("unused")
      }
    }
    #expect(fixture.paths.currentGame.resolvingSymlinksInPath() == first)
    let versions = try FileManager.default.contentsOfDirectory(
      at: fixture.paths.data.appendingPathComponent("Versions"), includingPropertiesForKeys: nil)
    #expect(
      versions.map(\.lastPathComponent) == [first.deletingLastPathComponent().lastPathComponent])
  }

  @Test
  func `a file that changes between recognition and copy is rejected`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let rules = try RecipeRules.farCry2Scaled()
    let scan = try InstallScanner.scan(fixture.install.install, rules: rules)
    let entry = try #require(scan.files.first { $0.path == "Data_Win32/worlds.dat" })
    try Data("changed after recognition".utf8).write(
      to: fixture.install.url("Data_Win32/worlds.dat"))
    let target = fixture.install.root.appendingPathComponent("copy/worlds.dat")
    #expect(throws: LauncherError.self) {
      try VerifiedGameFile.copy(entry, from: fixture.install.install, to: target)
    }
  }
}
