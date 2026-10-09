import Foundation
import Testing

@testable import LauncherCore

/// The native side of `Packaging/check_bf4_recipe_schema.py`: machine types and root files.
struct ImportRulesRootFilesTests {
  private static let directory = ImportRules.Directory(path: "Game")

  private func rules(
    executable: String = "Game64.exe", machine: String = "x86_64",
    required: [String] = ["Game64.exe", "Launcher64.exe", "Game/Game64.dat"],
    rootFiles: [String]? = ["Game64.exe", "Launcher64.exe"]
  ) -> ImportRules {
    ImportRules(
      executable: executable, machine: machine,
      required: required.map { .init(path: $0, minimumSize: 1) },
      directories: [Self.directory], maximumFiles: 100, maximumBytes: 1_000_000,
      rootFiles: rootFiles)
  }

  @Test(arguments: ["i386", "x86_64"])
  func `both supported machine types validate`(machine: String) throws {
    try ImportRules(
      executable: "Game/Game64.exe", machine: machine,
      required: [.init(path: "Game/Game64.exe", minimumSize: 1)], directories: [Self.directory]
    ).validate()
  }

  @Test(arguments: ["arm64", "X86_64", "amd64", "x64", ""])
  func `any other machine spelling is refused`(machine: String) {
    let candidate = ImportRules(
      executable: "Game/Game64.exe", machine: machine,
      required: [.init(path: "Game/Game64.exe", minimumSize: 1)], directories: [Self.directory])
    #expect(throws: LauncherError.self) { try candidate.validate() }
  }

  @Test
  func `x86_64 names the AMD64 machine type`() {
    #expect(rules().expectedMachine == PortableExecutable.machineAMD64)
    #expect(rules(machine: "i386").expectedMachine == PortableExecutable.machineI386)
  }

  @Test
  func `root files satisfy required paths and may hold the executable`() throws {
    try rules().validate()
    try rules(rootFiles: ["game64.EXE", "LAUNCHER64.exe"]).validate()
    let spaced = ["Game64.exe", "Launcher 64 (x).exe"]
    try rules(required: spaced, rootFiles: spaced).validate()
    let sixteen = (0..<16).map { "File\($0).exe" }
    try rules(executable: "File0.exe", required: sixteen, rootFiles: sixteen).validate()
  }

  @Test
  func `without the key a root level required file is outside every directory`() {
    #expect(throws: LauncherError.self) { try rules(rootFiles: nil).validate() }
  }

  @Test(arguments: [
    [], [".."], ["."], ["../Game64.exe"], ["Game/Game64.exe"], ["Game\\Game64.exe"],
    ["/Game64.exe"], [".hidden.exe"], [""], ["Game64.exe\u{0}"], ["Game64.exe\n"],
    [String(repeating: "A", count: 65) + ".exe"], ["Gamé64.exe"], ["Game64.exe", "Game64.exe"],
    ["Game64.exe", "GAME64.EXE"], ["Game64.exe", "Game"], ["Game64.exe", "GAME"],
    [" Game64.exe"],
  ])
  func `refuses unsafe, duplicate or colliding root files`(listed: [String]) {
    #expect(throws: LauncherError.self) { try rules(rootFiles: listed).validate() }
  }

  @Test
  func `refuses more than sixteen root files`() {
    let seventeen = (0..<17).map { "File\($0).exe" }
    #expect(throws: LauncherError.self) {
      try rules(executable: "File0.exe", required: seventeen, rootFiles: seventeen).validate()
    }
  }

  @Test
  func `every root file must be required and every root level required file listed`() {
    #expect(throws: LauncherError.self) {
      try rules(rootFiles: ["Game64.exe", "Launcher64.exe", "Extra.exe"]).validate()
    }
    #expect(throws: LauncherError.self) { try rules(rootFiles: ["Game64.exe"]).validate() }
  }

  @Test(arguments: ["Other.exe", "Game/Missing.exe", "game64.dat"])
  func `the executable must still be a required file`(executable: String) {
    #expect(throws: LauncherError.self) { try rules(executable: executable).validate() }
  }

  @Test
  func `an absent list stays absent when the rules are encoded again`() throws {
    let plain = ImportRules(
      executable: "Game/Game64.exe", required: [.init(path: "Game/Game64.exe", minimumSize: 1)],
      directories: [Self.directory])
    let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
    #expect(!encoded.contains("rootFiles"))
    let json = Data(
      """
      {"executable":"Game64.exe","machine":"x86_64","required":[{"path":"Game64.exe","minimumSize":1}],
      "directories":[{"path":"Game","minimumBytes":0,"excludedNames":[],"excludedSuffixes":[],
      "excludedDirectories":[]}],"pairings":[],"markers":[],"knownBuilds":[],"maximumFiles":10,
      "maximumBytes":100,"rootFiles":["Game64.exe"]}
      """.utf8)
    let decoded = try JSONDecoder().decode(ImportRules.self, from: json)
    #expect(decoded.rootFiles == ["Game64.exe"])
    try decoded.validate()
    let empty = try JSONDecoder().decode(
      ImportRules.self,
      from: Data(
        String(decoding: json, as: UTF8.self).replacingOccurrences(
          of: "[\"Game64.exe\"]}", with: "[]}"
        ).utf8))
    #expect(empty.rootFiles == [])
    #expect(throws: LauncherError.self) { try empty.validate() }
  }
}
