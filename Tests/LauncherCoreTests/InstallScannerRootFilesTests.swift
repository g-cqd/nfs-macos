import Foundation
import GameFixtures
import Testing

@testable import LauncherCore

/// A 64-bit game folder whose executable and launcher sit at its root, beside `Data`.
struct InstallScannerRootFilesTests {
  private struct Folder {
    let root: URL
    let install: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath()
      install = root.appendingPathComponent("Sample 64")
      var options = PEFixture.Options()
      options.machine = PortableExecutable.machineAMD64
      options.pe32Plus = true
      try write("Game64.exe", PEFixture.make(options))
      try write("Launcher64.exe", Array("synthetic launcher".utf8))
      try write("Data/level.cas", Array("synthetic level data".utf8))
      try write("readme.txt", Array("not selected".utf8))
    }

    func url(_ relative: String) -> URL { install.appendingPathComponent(relative) }

    func write(_ relative: String, _ bytes: [UInt8]) throws {
      let target = url(relative)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(bytes).write(to: target)
    }

    func cleanup() {
      do { try FileManager.default.removeItem(at: root) } catch {
        print("Fixture cleanup failed: \(error)")
      }
    }
  }

  private func rules(
    minimumLauncher: Int = 1, maximumFiles: Int = 100, maximumBytes: Int = 1_000_000
  ) -> ImportRules {
    ImportRules(
      executable: "Game64.exe", machine: "x86_64",
      required: [
        .init(path: "Game64.exe", minimumSize: 1),
        .init(path: "Launcher64.exe", minimumSize: minimumLauncher),
        .init(path: "Data/level.cas", minimumSize: 1),
      ],
      directories: [.init(path: "Data")], maximumFiles: maximumFiles, maximumBytes: maximumBytes,
      rootFiles: ["Game64.exe", "Launcher64.exe"])
  }

  @Test
  func `inventories the root files and recognises a PE32+ AMD64 executable`() throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    let scan = try InstallScanner.scan(folder.install, rules: rules())
    #expect(scan.files.map(\.path) == ["Data/level.cas", "Game64.exe", "Launcher64.exe"])
    #expect(scan.game.fileCount == 3)
    #expect(scan.game.totalBytes == scan.files.reduce(0) { $0 + $1.size })
    #expect(scan.game.executableSHA256 == scan.files.first { $0.path == "Game64.exe" }?.sha256)
  }

  @Test
  func `matches root files case-insensitively and keeps the on-disk spelling`() throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    try FileManager.default.moveItem(at: folder.url("Launcher64.exe"), to: folder.url("x.tmp"))
    try FileManager.default.moveItem(at: folder.url("x.tmp"), to: folder.url("LAUNCHER64.EXE"))
    let scan = try InstallScanner.scan(folder.install, rules: rules())
    #expect(scan.files.contains { $0.path == "LAUNCHER64.EXE" })
  }

  @Test
  func `a missing root file names itself`() throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    try FileManager.default.removeItem(at: folder.url("Launcher64.exe"))
    let error = try #require(throws: LauncherError.self) {
      try InstallScanner.scan(folder.install, rules: rules())
    }
    #expect(error.localizedDescription.contains("Launcher64.exe"))
  }

  @Test
  func `a linked root file is refused`() throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    let outside = folder.root.appendingPathComponent("outside.exe")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.removeItem(at: folder.url("Launcher64.exe"))
    try FileManager.default.createSymbolicLink(
      at: folder.url("Launcher64.exe"), withDestinationURL: outside)
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(folder.install, rules: rules())
    }
  }

  @Test
  func `a root file below its minimum size is refused`() throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(folder.install, rules: rules(minimumLauncher: 1_000))
    }
  }

  @Test
  func `root files count against the file and byte limits`() throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    // One file in Data fits both limits; the root files then exceed them.
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(folder.install, rules: rules(maximumFiles: 2))
    }
    let dataBytes = "synthetic level data".utf8.count
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(folder.install, rules: rules(maximumBytes: dataBytes + 1))
    }
  }

  @Test
  func `a 32-bit executable is refused by a 64-bit rule and named as such`() throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    try folder.write("Game64.exe", PEFixture.make())
    let error = try #require(throws: LauncherError.self) {
      try InstallScanner.scan(folder.install, rules: rules())
    }
    #expect(error.localizedDescription.contains("64-bit"))
  }
}
