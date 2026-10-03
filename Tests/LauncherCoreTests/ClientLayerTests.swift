import CryptoKit
import Darwin
import Foundation
import Testing

@testable import LauncherCore

/// The EA client that comes with a bundled app: applying it to a fresh prefix, and refusing
/// everything a hostile or damaged layer could do. The fixture layer is written by
/// `Packaging/client_layer.py`, so these tests also pin the format both sides agree on.
struct ClientLayerTests {
  private static let junction = "Program Files/Electronic Arts/EA Desktop/EA Desktop?"
  private static let client = "Program Files/Electronic Arts/EA Desktop/1.2.3.4/EA Desktop"

  private static let hive =
    "WINE REGISTRY Version 2\n;; All keys relative to REGISTRY\\\\Machine\n\n#arch=win64\n\n"
    + "[Software\\\\Wine] 1700000000\n#time=1d00000000000000\n\"Version\"=\"win10\"\n\n"

  /// A scratch prefix and a private copy of the fixture layer that a test may damage.
  private struct Workspace {
    let root: URL
    let layer: URL
    let prefix: URL

    init(file: StaticString = #filePath) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      layer = root.appendingPathComponent("ClientLayer")
      prefix = root.appendingPathComponent("Prefix")
      let source = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        .appendingPathComponent("Fixtures/client-layer")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: layer)
      try FileManager.default.createDirectory(
        at: prefix.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
      for name in ["system.reg", "user.reg"] {
        try Data(ClientLayerTests.hive.utf8).write(to: prefix.appendingPathComponent(name))
      }
    }

    var driveC: URL { prefix.appendingPathComponent("drive_c") }
    var manifest: URL { layer.appendingPathComponent("client-layer.json") }

    var digest: String {
      get throws {
        SHA256.hash(data: try Data(contentsOf: manifest)).map { String(format: "%02x", $0) }
          .joined()
      }
    }

    func open() throws -> ClientLayer { try ClientLayer(root: layer, expectedSHA256: try digest) }

    /// Rewrites the manifest after `change`, so its digest follows and only the rule under test fails.
    func edit(_ change: (inout [String: Any]) throws -> Void) throws {
      var object = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
      try change(&object)
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifest)
    }

    /// Replaces a registry part and re-pins it in the manifest, so only the part's own rules can refuse it.
    func rewritePart(_ hive: String, keys: Int? = nil, _ transform: (String) -> String) throws {
      let url = layer.appendingPathComponent("registry/\(hive).part")
      let data = Data(transform(try String(contentsOf: url, encoding: .utf8)).utf8)
      try data.write(to: url)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      try edit { object in
        var parts = try #require(object["registry"] as? [[String: Any]])
        for index in parts.indices where parts[index]["hive"] as? String == hive {
          parts[index]["sha256"] = digest
          if let keys { parts[index]["keys"] = keys }
        }
        object["registry"] = parts
      }
    }

    func entries(_ object: [String: Any]) throws -> [[String: Any]] {
      try #require(object["entries"] as? [[String: Any]])
    }

    func remove() {
      do { try FileManager.default.removeItem(at: root) } catch {
        print("Scratch cleanup failed: \(error)")
      }
    }
  }

  private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  private func attribute(_ name: String, of url: URL) -> Data? {
    let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard size >= 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard getxattr(url.path, name, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
    return Data(bytes)
  }

  private func attributeNames(of url: URL) -> [String] {
    let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return [] }
    var names = [CChar](repeating: 0, count: size)
    guard listxattr(url.path, &names, size, XATTR_NOFOLLOW) >= 0 else { return [] }
    return names.split(separator: 0).map {
      String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }

  @Test
  func `applies every file, folder and attribute of the layer to a fresh prefix`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let layer = try workspace.open()
    try layer.apply(to: workspace.prefix)
    for entry in layer.manifest.entries {
      let target = workspace.driveC.appendingPathComponent(entry.path)
      var isDirectory: ObjCBool = false
      #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
      #expect(isDirectory.boolValue == (entry.kind == .directory), "\(entry.path)")
      let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
      #expect(mode as? Int == entry.mode, "\(entry.path)")
      if let digest = entry.sha256, let size = entry.size {
        #expect(try FileDigest.sha256(of: target, size: size) == digest, "\(entry.path)")
      }
      for (name, encoded) in entry.xattrs ?? [:] {
        #expect(attribute(name, of: target) == Data(base64Encoded: encoded), "\(entry.path)")
      }
    }
    let executable = workspace.driveC.appendingPathComponent("\(Self.client)/EADesktop.exe")
    #expect(try text(executable) == "MZ client")
    #expect(
      attribute("user.WINEREPARSE", of: workspace.driveC.appendingPathComponent(Self.junction))
        != nil)
    #expect(
      attribute(
        "user.DOSATTRIB",
        of: workspace.driveC.appendingPathComponent("Program Files/Common Files/EAInstaller/EA app")
      ) == Data("0x2".utf8))
    #expect(layer.summary == "EA app 1.2.3.4")
  }

  @Test
  func `carries no extended attribute but Wine's own into the prefix`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    // A blob that picked up a quarantine mark where the app was downloaded must not pass it on.
    let first = try #require(try workspace.open().manifest.entries.first { $0.kind == .file })
    let blob = workspace.layer.appendingPathComponent("blobs/\(try #require(first.sha256))")
    #expect(setxattr(blob.path, "com.apple.quarantine", "0081;00000000;Safari;", 21, 0, 0) == 0)
    try workspace.open().apply(to: workspace.prefix)
    let installed = workspace.driveC.appendingPathComponent(first.path)
    #expect(
      attributeNames(of: installed).allSatisfy {
        $0.hasPrefix("com.apple.") && $0 != "com.apple.quarantine"
      })
    #expect(attribute("com.apple.quarantine", of: installed) == nil)
  }

  @Test
  func `stores the cached package once and installs it under both names`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let layer = try workspace.open()
    let packages = layer.manifest.entries.filter { $0.path.hasSuffix(".msi") }
    #expect(packages.count == 2)
    #expect(Set(packages.compactMap(\.sha256)).count == 1)
    try layer.apply(to: workspace.prefix)
    for package in packages {
      #expect(
        FileManager.default.fileExists(
          atPath: workspace.driveC.appendingPathComponent(package.path).path))
    }
  }

  @Test
  func `appends the registry sections after the hive and keeps what was there`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let layer = try workspace.open()
    try layer.apply(to: workspace.prefix)
    let system = try text(workspace.prefix.appendingPathComponent("system.reg"))
    let part = try text(workspace.layer.appendingPathComponent("registry/system.reg.part"))
    #expect(system == Self.hive + part)
    #expect(RegistryHiveText.keys(in: system).contains("software\\electronic arts\\ea desktop"))
    #expect(RegistryHiveText.keys(in: system).contains("software\\wine"))
    let user = try text(workspace.prefix.appendingPathComponent("user.reg"))
    #expect(user.contains("Xbox"))
    #expect(!system.contains("machine.ini") && !system.lowercased().contains("appdata"))
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.prefix.appendingPathComponent(".system.reg.client-layer").path))
  }

  @Test
  func `refuses a manifest that differs from its pin`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    #expect(throws: LauncherError.self) {
      try ClientLayer(root: workspace.layer, expectedSHA256: String(repeating: "0", count: 64))
    }
    let pinned = try workspace.digest
    try workspace.edit { $0["client"] = nil }
    #expect(throws: LauncherError.self) {
      try ClientLayer(root: workspace.layer, expectedSHA256: pinned)
    }
  }

  @Test
  func `refuses a blob that was changed after the layer was pinned`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let layer = try workspace.open()
    let entry = try #require(layer.manifest.entries.first { $0.path.hasSuffix("EADesktop.exe") })
    let blob = workspace.layer.appendingPathComponent("blobs/\(try #require(entry.sha256))")
    try Data("MZ clienT".utf8).write(to: blob)
    #expect(throws: LauncherError.self) { try layer.apply(to: workspace.prefix) }
  }

  @Test
  func `refuses a missing blob and a blob of the wrong size`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let layer = try workspace.open()
    let entry = try #require(layer.manifest.entries.first { $0.path.hasSuffix("main.qml") })
    let blob = workspace.layer.appendingPathComponent("blobs/\(try #require(entry.sha256))")
    try Data("short".utf8).write(to: blob)
    #expect(throws: LauncherError.self) { try layer.apply(to: workspace.prefix) }
    try FileManager.default.removeItem(at: blob)
    let fresh = try Workspace()
    defer { fresh.remove() }
    try FileManager.default.removeItem(
      at: fresh.layer.appendingPathComponent("blobs/\(try #require(entry.sha256))"))
    #expect(throws: LauncherError.self) { try fresh.open().apply(to: fresh.prefix) }
  }

  @Test
  func `refuses to overwrite a file the prefix already has`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let layer = try workspace.open()
    try layer.apply(to: workspace.prefix)
    #expect(throws: LauncherError.self) { try layer.apply(to: workspace.prefix) }
  }

  @Test
  func `does not follow a link where a folder should be`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let outside = workspace.root.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: workspace.driveC.appendingPathComponent("Program Files"), withDestinationURL: outside)
    #expect(throws: LauncherError.self) { try workspace.open().apply(to: workspace.prefix) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test
  func `refuses a registry key the prefix already has`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let clash =
      Self.hive + "[SOFTWARE\\\\ELECTRONIC ARTS\\\\EA DESKTOP] 1\n#time=1\n\"a\"=\"b\"\n\n"
    try Data(clash.utf8).write(to: workspace.prefix.appendingPathComponent("system.reg"))
    #expect(throws: LauncherError.self) { try workspace.open().apply(to: workspace.prefix) }
  }

  @Test
  func `refuses a hive that is not a Wine registry`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    try Data("not a hive".utf8).write(to: workspace.prefix.appendingPathComponent("system.reg"))
    #expect(throws: LauncherError.self) { try workspace.open().apply(to: workspace.prefix) }
  }

  @Test
  func `refuses a registry part that was changed after the layer was pinned`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let part = workspace.layer.appendingPathComponent("registry/system.reg.part")
    try Data((try text(part) + "[Software\\\\Evil] 1\n#time=1\n\"a\"=\"b\"\n\n").utf8).write(
      to: part)
    #expect(throws: LauncherError.self) { try workspace.open().apply(to: workspace.prefix) }
    #expect(try text(workspace.prefix.appendingPathComponent("system.reg")) == Self.hive)
  }

  @Test
  func `refuses a prefix without drive_c`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    try FileManager.default.removeItem(at: workspace.driveC)
    #expect(throws: LauncherError.self) { try workspace.open().apply(to: workspace.prefix) }
  }

  @Test
  func `refuses a registry part that names a key outside the client's own`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    try workspace.rewritePart("system.reg", keys: 2) {
      $0 + "[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run] 1\n#time=1\n\"x\"=\"y\"\n\n"
    }
    #expect(throws: LauncherError.self) { try workspace.open().apply(to: workspace.prefix) }
    #expect(try text(workspace.prefix.appendingPathComponent("system.reg")) == Self.hive)
  }

  @Test
  func `refuses a registry part with a stray line or a key count that differs from the manifest`()
    throws
  {
    let stray = try Workspace()
    defer { stray.remove() }
    try stray.rewritePart("user.reg") { "stray text\n" + $0 }
    #expect(throws: LauncherError.self) { try stray.open().apply(to: stray.prefix) }
    let shape = try Workspace()
    defer { shape.remove() }
    try shape.rewritePart("system.reg") {
      $0.replacingOccurrences(of: "\"ClientPath\"=", with: "ClientPath=")
    }
    #expect(throws: LauncherError.self) { try shape.open().apply(to: shape.prefix) }
    let count = try Workspace()
    defer { count.remove() }
    try count.rewritePart("system.reg", keys: 99) { $0 }
    #expect(throws: LauncherError.self) { try count.open().apply(to: count.prefix) }
  }

  private struct KeyCases: Decodable {
    struct Key: Decodable {
      let hive: String
      let key: String
    }
    let accepted: [Key]
    let rejected: [Key]
  }

  @Test
  func `accepts and refuses exactly the registry keys the packager's policy lists`() throws {
    let url = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
      .appendingPathComponent("Fixtures/client-layer-keys.json")
    let cases = try JSONDecoder().decode(KeyCases.self, from: Data(contentsOf: url))
    for entry in cases.accepted {
      #expect(throws: Never.self, "\(entry.key)") {
        try ClientLayerPolicy.validate(registryKey: entry.key, hive: entry.hive)
      }
    }
    for entry in cases.rejected {
      #expect(throws: LauncherError.self, "\(entry.key)") {
        try ClientLayerPolicy.validate(registryKey: entry.key, hive: entry.hive)
      }
    }
  }

  @Test
  func `does not chmod through a link planted where a file goes`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let outside = workspace.root.appendingPathComponent("outside.txt")
    try Data("private".utf8).write(to: outside)
    #expect(chmod(outside.path, 0o600) == 0)
    let target = workspace.driveC.appendingPathComponent("\(Self.client)/EADesktop.exe")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
    #expect(throws: LauncherError.self) { try workspace.open().apply(to: workspace.prefix) }
    let mode = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions]
    #expect(mode as? Int == 0o600)
    #expect(try text(outside) == "private")
  }

  /// The real layer, when this machine has it next to the checkout: every registry part passes the
  /// app's rules, and applying it to a prefix verifies every file. Skipped elsewhere.
  private static func realLayer(file: StaticString = #filePath) -> (root: URL, digest: String)? {
    let repository = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.deletingLastPathComponent().appendingPathComponent("inputs/client-layer")
    guard
      FileManager.default.fileExists(atPath: root.appendingPathComponent("client-layer.json").path),
      let recipe = try? Data(
        contentsOf: repository.appendingPathComponent("Packaging/Recipes/nfs2015.json")),
      let object = try? JSONSerialization.jsonObject(with: recipe) as? [String: Any],
      let declared = object["clientLayer"] as? [String: Any],
      let digest = declared["layerSHA256"] as? String
    else { return nil }
    return (root, digest)
  }

  @Test(.enabled(if: realLayer() != nil))
  func `applies the real pinned layer to a fresh prefix`() throws {
    let layer = try #require(Self.realLayer())
    let workspace = try Workspace()
    defer { workspace.remove() }
    let client = try ClientLayer(root: layer.root, expectedSHA256: layer.digest)
    for part in client.manifest.registry {
      let data = try Data(contentsOf: layer.root.appendingPathComponent(part.file))
      try RegistryHiveText.validate(part: data, hive: part.hive, keys: part.keys)
    }
    try client.apply(to: workspace.prefix)
    let files = client.manifest.entries.filter { $0.kind == .file }
    #expect(files.count > 900)
    let driveC = workspace.driveC
    let executable = driveC.appendingPathComponent(
      "Program Files/Electronic Arts/EA Desktop/\(client.manifest.client.version)/EA Desktop/EADesktop.exe"
    )
    #expect(FileManager.default.fileExists(atPath: executable.path))
    #expect(
      attribute(
        "user.WINEREPARSE", of: driveC.appendingPathComponent(Self.junction)) != nil)
    let system = try text(workspace.prefix.appendingPathComponent("system.reg"))
    #expect(
      RegistryHiveText.keys(in: system).contains(
        "system\\controlset001\\services\\eabackgroundservice"))
  }

  /// One mutation of a good manifest that the app must refuse before it writes anything.
  struct Mutation: Sendable, CustomTestStringConvertible {
    let name: String
    let change: @Sendable (inout [String: Any]) -> Void
    var testDescription: String { name }
  }

  private static func mutate(_ change: @escaping @Sendable (inout [[String: Any]]) -> Void)
    -> @Sendable (inout [String: Any]) -> Void
  {
    { object in
      var entries = object["entries"] as? [[String: Any]] ?? []
      change(&entries)
      object["entries"] = entries
    }
  }

  /// A well-formed extra file entry; each mutation breaks exactly one of its rules.
  private static func with(_ key: String, _ value: Any) -> [String: Any] {
    var entry: [String: Any] = [
      "path": "Program Files/Electronic Arts/EA Desktop/1.2.3.4/EA Desktop/extra.dll",
      "kind": "file", "mode": 420, "size": 1, "sha256": String(repeating: "a", count: 64),
    ]
    entry[key] = value
    return entry
  }

  private static let mutations: [Mutation] = [
    Mutation(
      name: "a path outside the layer's folders",
      change: mutate { $0.append(with("path", "windows/system32/kernel32.dll")) }),
    Mutation(name: "an unknown format") { $0["format"] = 2 },
    Mutation(name: "no entries") { $0["entries"] = [[String: Any]]() },
    Mutation(
      name: "a path in the game folder",
      change: mutate { $0.append(with("path", "Program Files/EA Games/Need for Speed/NFS16.exe")) }),
    Mutation(
      name: "machine state",
      change: mutate { $0.append(with("path", "ProgramData/EA Desktop/machine.ini")) }),
    Mutation(
      name: "a user profile",
      change: mutate { $0.append(with("path", "users/crossover/AppData/Local/x.bin")) }),
    Mutation(
      name: "a path that climbs out",
      change: mutate { $0.append(with("path", "Program Files/Electronic Arts/../../../evil.dll")) }),
    Mutation(
      name: "a duplicate that differs in case",
      change: mutate {
        $0.append(
          with("path", "PROGRAM FILES/ELECTRONIC ARTS/EA DESKTOP/1.2.3.4/EA DESKTOP/EADESKTOP.EXE"))
      }),
    Mutation(
      name: "a mode that is neither 644 nor 755", change: mutate { $0.append(with("mode", 0o777)) }),
    Mutation(name: "a file without a digest", change: mutate { $0.append(with("sha256", "xyz")) }),
    Mutation(name: "a negative size", change: mutate { $0.append(with("size", -1)) }),
    Mutation(
      name: "an unreviewed attribute",
      change: mutate { $0.append(with("xattrs", ["com.apple.quarantine": "AA=="])) }),
    Mutation(
      name: "an unreadable attribute",
      change: mutate { $0.append(with("xattrs", ["user.DOSATTRIB": "***"])) }),
    Mutation(
      name: "a folder with a digest",
      change: mutate {
        $0.append([
          "path": "Program Files/Electronic Arts/X", "kind": "directory", "mode": 493,
          "sha256": String(repeating: "a", count: 64),
        ])
      }),
    Mutation(name: "an unknown kind", change: mutate { $0.append(with("kind", "symlink")) }),
    Mutation(name: "a registry part for an unknown hive") { object in
      object["registry"] = [
        [
          "hive": "sam.reg", "file": "registry/sam.reg.part",
          "sha256": String(repeating: "a", count: 64), "keys": 1,
        ]
      ]
    },
    Mutation(name: "a registry part outside the registry folder") { object in
      object["registry"] = [
        [
          "hive": "system.reg", "file": "../system.reg",
          "sha256": String(repeating: "a", count: 64), "keys": 1,
        ]
      ]
    },
  ]

  @Test(arguments: mutations)
  func `refuses a manifest that breaks a rule`(mutation: Mutation) throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    try workspace.edit { mutation.change(&$0) }
    #expect(throws: LauncherError.self) { try workspace.open() }
  }

  private struct PathCases: Decodable {
    let accepted: [String]
    let rejected: [String]
  }

  @Test
  func `accepts and refuses exactly the paths the packager's policy lists`() throws {
    let url = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
      .appendingPathComponent("Fixtures/client-layer-paths.json")
    let cases = try JSONDecoder().decode(PathCases.self, from: Data(contentsOf: url))
    for path in cases.accepted {
      #expect(throws: Never.self, "\(path)") { try ClientLayerPolicy.validate(path: path) }
    }
    for path in cases.rejected {
      #expect(throws: LauncherError.self, "\(path)") { try ClientLayerPolicy.validate(path: path) }
    }
  }

  @Test
  func `the verified copy used on volumes that cannot clone checks every byte`() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let source = workspace.root.appendingPathComponent("source.bin")
    let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try bytes.write(to: source)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let good = workspace.root.appendingPathComponent("good.bin")
    try ClientLayerFile.copy(
      blob: source.path, to: good.path, size: bytes.count, digest: digest, name: "good.bin")
    #expect(try Data(contentsOf: good) == bytes)
    let bad = workspace.root.appendingPathComponent("bad.bin")
    #expect(throws: LauncherError.self) {
      try ClientLayerFile.copy(
        blob: source.path, to: bad.path, size: bytes.count,
        digest: String(repeating: "0", count: 64),
        name: "bad.bin")
    }
    #expect(throws: LauncherError.self) {
      try ClientLayerFile.copy(
        blob: source.path, to: good.path, size: bytes.count, digest: digest, name: "again")
    }
  }

  @Test
  func `reads hive keys with Wine's doubled backslashes undone and ignores value lines`() {
    let hive =
      Self.hive + "[Software\\\\Classes\\\\Foo] 1767225600\n#time=1\n\"[Not\\\\AKey] 5\"=\"x\"\n\n"
    #expect(
      RegistryHiveText.keys(in: hive) == ["software\\wine", "software\\classes\\foo"])
  }

  @Test
  func `joins a part to a hive that lacks its final blank line`() throws {
    let part = Data("[Software\\\\Added] 1\n#time=1\n\n".utf8)
    let bare = Data(Self.hive.dropLast(2).utf8)
    let merged = String(
      decoding: try RegistryHiveText.merged(hive: bare, part: part), as: UTF8.self)
    #expect(merged.contains("\"Version\"=\"win10\"\n\n[Software\\\\Added]"))
    #expect(RegistryHiveText.keys(in: merged).count == 2)
  }

  @Test
  func `a seeded prefix holds the client and the game together and publishes both at once`() throws
  {
    let fixture = try SeededFixture()
    let workspace = try Workspace()
    defer {
      fixture.remove()
      workspace.remove()
    }
    let layer = try workspace.open()
    let seed = PrefixSeed(paths: fixture.paths, manifest: fixture.manifest)
    let prefix = try seed.prepare { staged in
      try FileManager.default.createDirectory(
        at: staged.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
      for name in ["system.reg", "user.reg"] {
        try Data(Self.hive.utf8).write(to: staged.appendingPathComponent(name))
      }
      try layer.apply(to: staged)
    }
    let client = prefix.appendingPathComponent("drive_c/\(Self.client)/EADesktop.exe")
    #expect(try text(client) == "MZ client")
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.seededGame.appendingPathComponent("NFS16.exe").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: prefix.appendingPathComponent("drive_c/ProgramData/EA Desktop").path))
    #expect(
      !FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/users").path))
  }

  @Test
  func `a failed client layer leaves nothing published and the next launch starts clean`() throws {
    let fixture = try SeededFixture()
    let workspace = try Workspace()
    defer {
      fixture.remove()
      workspace.remove()
    }
    let layer = try workspace.open()
    let entry = try #require(layer.manifest.entries.first { $0.path.hasSuffix("main.qml") })
    try Data("x".utf8).write(
      to: workspace.layer.appendingPathComponent("blobs/\(try #require(entry.sha256))"))
    let seed = PrefixSeed(paths: fixture.paths, manifest: fixture.manifest)
    #expect(throws: LauncherError.self) {
      try seed.prepare { staged in
        try FileManager.default.createDirectory(
          at: staged.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        for name in ["system.reg", "user.reg"] {
          try Data(Self.hive.utf8).write(to: staged.appendingPathComponent(name))
        }
        try layer.apply(to: staged)
      }
    }
    #expect(!seed.isSeeded)
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.data.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.paths.support.appendingPathComponent(".preparing").path))
  }

  @Test
  func `a game manifest declares its layer only for the bundled edition`() throws {
    let reference = ClientLayerReference(
      path: "ClientLayer", manifestSHA256: String(repeating: "a", count: 64),
      version: "13.796.0.6309")
    try reference.validate()
    let seeded = BundleManifest(
      version: "v1",
      gameFiles: [
        ManifestFile(path: "NFS16.exe", size: 1, sha256: String(repeating: "a", count: 64))
      ],
      gameID: .nfs2015, storeClient: SeededFixture.plan, renderers: SeededFixture.renderers,
      clientLayer: reference)
    try seeded.validate()
    #expect(seeded.layer == reference)
    let encoded = try JSONEncoder().encode(seeded)
    #expect(try JSONDecoder().decode(BundleManifest.self, from: encoded).layer == reference)
    let referencing = BundleManifest(
      version: "v1", gameFiles: [], gameID: .nfs2015, referencesInstallation: true,
      storeClient: SeededFixture.plan, renderers: SeededFixture.renderers, clientLayer: reference)
    #expect(throws: LauncherError.self) { try referencing.validate() }
  }

  @Test(arguments: [
    ("", String(repeating: "a", count: 64), "1.0"),
    ("a/b", String(repeating: "a", count: 64), "1.0"),
    ("../ClientLayer", String(repeating: "a", count: 64), "1.0"),
    ("ClientLayer", String(repeating: "A", count: 64), "1.0"), ("ClientLayer", "abc", "1.0"),
    ("ClientLayer", String(repeating: "a", count: 64), ""),
    ("ClientLayer", String(repeating: "a", count: 64), "1.0; rm"),
  ])
  func `refuses an unpinned or unsafe layer declaration`(
    path: String, digest: String, version: String
  ) {
    let reference = ClientLayerReference(path: path, manifestSHA256: digest, version: version)
    #expect(throws: LauncherError.self) { try reference.validate() }
  }
}
