import Foundation
import GameFixtures
import Testing

@testable import LauncherCore

struct ImportRulesTests {
  @Test
  func `the packaged Far Cry 2 rules are valid and unverified builds are accepted`() throws {
    let rules = try RecipeRules.farCry2()
    try rules.validate()
    #expect(rules.executable == "bin/FarCry2.exe")
    #expect(rules.machine == "i386")
    #expect(
      rules.knownBuilds.isEmpty, "no build digest is pinned until a legitimate install is hashed")
    #expect(rules.directories.map(\.path) == ["bin", "Data_Win32"])
    #expect(rules.directories.first { $0.path == "Data_Win32" }?.minimumBytes ?? 0 >= 1 << 30)
    // The app owns these in bin; a player's copy must never overwrite them.
    let bin = try #require(rules.directories.first { $0.path == "bin" })
    #expect(bin.excludedNames.contains("mtld3d.conf"))
    #expect(bin.excludedNames.contains("mtld3d_shaders.bin"))
    #expect(bin.excludedDirectories.contains("mtld3d-logs"))
  }

  private func rules(
    executable: String = "bin/game.exe", machine: String = "i386",
    required: [ImportRules.RequiredFile] = [.init(path: "bin/game.exe", minimumSize: 1)],
    directories: [ImportRules.Directory] = [.init(path: "bin")],
    pairings: [ImportRules.Pairing] = [], markers: [ImportRules.Marker] = [],
    builds: [ImportRules.KnownBuild] = []
  ) -> ImportRules {
    ImportRules(
      executable: executable, machine: machine, required: required, directories: directories,
      pairings: pairings, markers: markers, knownBuilds: builds)
  }

  @Test
  func `a minimal rule set validates`() throws { try rules().validate() }

  @Test(arguments: [
    "traversal executable", "absolute executable", "machine", "required outside folders",
    "executable not required", "uppercase suffix", "duplicate directory", "bad digest",
    "marker with path", "pairing with same suffix", "no directories",
  ])
  func `rejects unsafe or inconsistent rules`(kind: String) {
    let candidate: ImportRules
    switch kind {
    case "traversal executable":
      candidate = rules(
        executable: "../game.exe", required: [.init(path: "../game.exe", minimumSize: 1)])
    case "absolute executable":
      candidate = rules(
        executable: "/bin/game.exe", required: [.init(path: "/bin/game.exe", minimumSize: 1)])
    case "machine": candidate = rules(machine: "arm64")
    case "required outside folders":
      candidate = rules(required: [
        .init(path: "bin/game.exe", minimumSize: 1), .init(path: "docs/readme.txt", minimumSize: 1),
      ])
    case "executable not required":
      candidate = rules(required: [.init(path: "bin/other.exe", minimumSize: 1)])
    case "uppercase suffix":
      candidate = rules(directories: [.init(path: "bin", excludedSuffixes: [".LOG"])])
    case "duplicate directory":
      candidate = rules(directories: [.init(path: "bin"), .init(path: "BIN")])
    case "bad digest": candidate = rules(builds: [.init(name: "x", executableSHA256: "abc")])
    case "marker with path":
      candidate = rules(markers: [.init(name: "x", patterns: ["a/b"])])
    case "pairing with same suffix":
      candidate = rules(pairings: [
        .init(directory: "bin", primarySuffix: ".a", companionSuffix: ".a")
      ])
    default: candidate = rules(directories: [])
    }
    #expect(throws: LauncherError.self) { try candidate.validate() }
  }

  @Test
  func `a manifest with rules needs no executable among its files but must name the right one`()
    throws
  {
    let compat = ManifestFile(
      path: "bin/mtld3d.conf", size: 1, sha256: String(repeating: "0", count: 64))
    let valid = BundleManifest(
      version: "v1", gameFiles: [compat], gameID: .farcry2, importRules: try RecipeRules.farCry2())
    try valid.validate()
    let wrong = BundleManifest(
      version: "v1", gameFiles: [compat], gameID: .farcry2,
      importRules: rules())
    #expect(throws: LauncherError.self) { try wrong.validate() }
    let without = BundleManifest(version: "v1", gameFiles: [compat], gameID: .farcry2)
    #expect(throws: LauncherError.self) { try without.validate() }
  }

  @Test
  func `a manifest written by the packager round-trips`() throws {
    let compat = ManifestFile(
      path: "bin/mtld3d.conf", size: 1, sha256: String(repeating: "0", count: 64))
    let manifest = BundleManifest(
      version: "v1", gameFiles: [compat], gameID: .farcry2, importRules: try RecipeRules.farCry2())
    let decoded = try JSONDecoder().decode(
      BundleManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.importRules == manifest.importRules)
    try decoded.validate()
  }
}
