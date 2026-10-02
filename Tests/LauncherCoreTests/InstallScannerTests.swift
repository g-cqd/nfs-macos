import CryptoKit
import Foundation
import GameFixtures
import Testing

@testable import LauncherCore

struct InstallScannerTests {
  private func digest(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
  }

  @Test
  func `recognises a synthetic installation and inventories only the files to copy`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    let scan = try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled())
    #expect(
      scan.files.map(\.path) == [
        "Data_Win32/common.dat", "Data_Win32/common.fat", "Data_Win32/sound_english.dat",
        "Data_Win32/sound_english.fat", "Data_Win32/worlds.dat", "Data_Win32/worlds.fat",
        "bin/Dunia.dll", "bin/FarCry2.exe", "bin/binkw32.dll",
      ])
    let dunia = try #require(scan.files.first { $0.path == "bin/Dunia.dll" })
    #expect(dunia.sha256 == digest(Array("synthetic engine library".utf8)))
    #expect(dunia.size == "synthetic engine library".utf8.count)
    #expect(scan.game.fileCount == 9)
    #expect(scan.game.totalBytes == scan.files.reduce(0) { $0 + $1.size })
    #expect(scan.game.fileVersion == "1.0.3.0")
    #expect(scan.game.build == nil)
    #expect(scan.game.markers == ["gog"])
    #expect(scan.game.executableSHA256 == scan.files.first { $0.path == "bin/FarCry2.exe" }?.sha256)
  }

  @Test
  func `skips player and renderer files the app owns`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    let paths = try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled()).files
      .map(\.path)
    for excluded in [
      "bin/mtld3d.conf", "bin/mtld3d_shaders.bin", "bin/mtld3d-logs/FarCry2-1.log",
      "bin/.DS_Store", "unins000.exe", "Support/vcredist_x86.exe",
      "goggame-0000000000.info",
    ] {
      #expect(!paths.contains(excluded), "\(excluded) must not be imported")
    }
  }

  @Test
  func `scanning never modifies the player's installation`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    func snapshot() throws -> [String: String] {
      var result: [String: String] = [:]
      let enumerator = try #require(
        FileManager.default.enumerator(at: install.install, includingPropertiesForKeys: nil))
      for case let url as URL in enumerator where !url.hasDirectoryPath {
        let data = try Data(contentsOf: url)
        result[url.path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      }
      return result
    }
    let before = try snapshot()
    _ = try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled())
    #expect(try snapshot() == before)
  }

  @Test
  func `accepts installations whose folders differ only in letter case`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    try FileManager.default.moveItem(at: install.url("bin"), to: install.url("bin-temp"))
    try FileManager.default.moveItem(at: install.url("bin-temp"), to: install.url("BIN"))
    try FileManager.default.moveItem(
      at: install.url("Data_Win32"), to: install.url("data_win32-temp"))
    try FileManager.default.moveItem(
      at: install.url("data_win32-temp"), to: install.url("DATA_WIN32"))
    let scan = try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled())
    #expect(scan.files.contains { $0.path == "BIN/FarCry2.exe" })
    #expect(scan.files.contains { $0.path == "DATA_WIN32/worlds.fat" })
    #expect(!scan.files.contains { $0.path.hasPrefix("bin/") })
  }

  @Test
  func `recognises a recorded build and reports store markers`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    try install.write("bin/steam_api.dll", Array("steam".utf8))
    let image = PEFixture.make()
    let base = try RecipeRules.farCry2Scaled()
    let rules = ImportRules(
      executable: base.executable, machine: base.machine, required: base.required,
      directories: base.directories, pairings: base.pairings, markers: base.markers,
      knownBuilds: [.init(name: "synthetic 1.03", executableSHA256: digest(image))])
    let scan = try InstallScanner.scan(install.install, rules: rules)
    #expect(scan.game.build == "synthetic 1.03")
    #expect(scan.game.markers == ["gog", "steam"])
  }

  @Test(arguments: [
    ("bin/FarCry2.exe", "FarCry2.exe"), ("bin/Dunia.dll", "Dunia.dll"),
    ("Data_Win32", "Data_Win32"),
  ])
  func `names the missing item and how to find the right folder`(missing: String, shown: String)
    throws
  {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    try install.remove(missing)
    let error = try #require(
      throws: LauncherError.self
    ) { try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled()) }
    #expect(error.localizedDescription.contains(shown))
  }

  @Test
  func `selecting the bin folder instead of the installation explains the mistake`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    let error = try #require(
      throws: LauncherError.self
    ) { try InstallScanner.scan(install.url("bin"), rules: RecipeRules.farCry2Scaled()) }
    #expect(error.localizedDescription.contains("Select the folder that contains"))
  }

  @Test
  func `rejects an archive that lacks its companion`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    try install.remove("Data_Win32/worlds.dat")
    let error = try #require(
      throws: LauncherError.self
    ) { try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled()) }
    #expect(error.localizedDescription.contains("worlds.fat"))
    try install.write("Data_Win32/worlds.dat", Array("restored".utf8))
    try install.remove("Data_Win32/common.fat")
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled())
    }
  }

  @Test
  func `real recipe thresholds reject a partial copy that only has the small files`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(install.install, rules: RecipeRules.farCry2())
    }
  }

  @Test
  func `rejects links anywhere in the selected tree`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    let outside = install.root.appendingPathComponent("outside.dat")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: install.url("Data_Win32/linked.dat"), withDestinationURL: outside)
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled())
    }
    try FileManager.default.removeItem(at: install.url("Data_Win32/linked.dat"))
    let link = install.root.appendingPathComponent("Linked Far Cry 2")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: install.install)
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(link, rules: RecipeRules.farCry2Scaled())
    }
  }

  @Test
  func `rejects executables that are not 32-bit games`() throws {
    var options = PEFixture.Options()
    options.machine = PortableExecutable.machineAMD64
    options.pe32Plus = true
    for image in [PEFixture.make(options), Array("not an executable".utf8)] {
      let install = try SyntheticInstall(executable: image)
      defer { install.cleanup() }
      #expect(throws: LauncherError.self) {
        try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled())
      }
    }
    var library = PEFixture.Options()
    library.dynamicLibrary = true
    let install = try SyntheticInstall(executable: PEFixture.make(library))
    defer { install.cleanup() }
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(install.install, rules: RecipeRules.farCry2Scaled())
    }
  }

  @Test
  func `enforces file count and byte ceilings`() throws {
    let install = try SyntheticInstall()
    defer { install.cleanup() }
    let base = try RecipeRules.farCry2Scaled()
    func limited(files: Int, bytes: Int) -> ImportRules {
      ImportRules(
        executable: base.executable, machine: base.machine, required: base.required,
        directories: base.directories, pairings: base.pairings, maximumFiles: files,
        maximumBytes: bytes)
    }
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(install.install, rules: limited(files: 3, bytes: 1_000_000))
    }
    #expect(throws: LauncherError.self) {
      try InstallScanner.scan(install.install, rules: limited(files: 100, bytes: 20))
    }
    _ = try InstallScanner.scan(install.install, rules: limited(files: 100, bytes: 1_000_000))
  }

  @Test(arguments: [
    ("goggame-*.info", "goggame-123.info", true), ("goggame-*.info", "goggame-123.dat", false),
    ("steam_api.dll", "steam_api.dll", true), ("steam_api.dll", "steam_api64.dll", false),
    ("uplay*.dll", "uplay_r1_loader.dll", true), ("*.nfo", "readme.txt", false),
    ("a*b*c", "aXXbYYc", true), ("a*b*c", "aXXcYYb", false),
  ])
  func `wildcard patterns match whole names`(pattern: String, name: String, expected: Bool) {
    #expect(InstallScanner.matches(pattern, name) == expected)
  }
}
