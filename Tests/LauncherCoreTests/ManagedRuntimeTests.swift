import CryptoKit
import Foundation
import Testing

@testable import LauncherCore

/// EA's installer runs a managed (.NET) custom action. The bundled Windows folder has no .NET, so
/// the app carries Wine's own free replacement and installs it before the EA installer runs.
struct ManagedRuntimeTests {
  private static let marker64 = "drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86_64.dll"
  private static let marker32 = "drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86.dll"

  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func remove(_ url: URL) {
    do { try FileManager.default.removeItem(at: url) } catch {
      print("Scratch cleanup failed: \(error)")
    }
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func runtime(for bytes: String, file: String = "Addons/mono.msi") -> ManagedRuntime {
    ManagedRuntime(
      file: file,
      sha256: SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined(),
      version: "10.4.1")
  }

  @Test
  func `accepts a plain pinned installer`() throws {
    try runtime(for: "x").validate()
  }

  @Test(arguments: [
    ManagedRuntime(file: "../mono.msi", sha256: String(repeating: "a", count: 64), version: "1"),
    ManagedRuntime(file: "/abs/mono.msi", sha256: String(repeating: "a", count: 64), version: "1"),
    ManagedRuntime(file: "a\\b.msi", sha256: String(repeating: "a", count: 64), version: "1"),
    ManagedRuntime(file: "mono.msi", sha256: String(repeating: "A", count: 64), version: "1"),
    ManagedRuntime(file: "mono.msi", sha256: "abc", version: "1"),
    ManagedRuntime(file: "mono.msi", sha256: String(repeating: "a", count: 64), version: ""),
    ManagedRuntime(file: "mono.msi", sha256: String(repeating: "a", count: 64), version: "1; rm"),
    ManagedRuntime(file: "mono.exe", sha256: String(repeating: "a", count: 64), version: "1"),
  ])
  func `rejects an unsafe or unpinned declaration`(declared: ManagedRuntime) {
    #expect(throws: LauncherError.self) { try declared.validate() }
  }

  @Test
  func `is installed only when both the 32 and 64 bit libraries are in the prefix`() throws {
    let prefix = try scratch()
    defer { remove(prefix) }
    let sut = runtime(for: "x")
    #expect(!sut.isInstalled(in: prefix))
    try write("x", to: prefix.appendingPathComponent(Self.marker64))
    #expect(!sut.isInstalled(in: prefix))
    try write("x", to: prefix.appendingPathComponent(Self.marker32))
    #expect(sut.isInstalled(in: prefix))
  }

  @Test
  func `a directory where a library should be does not count as installed`() throws {
    let prefix = try scratch()
    defer { remove(prefix) }
    try FileManager.default.createDirectory(
      at: prefix.appendingPathComponent(Self.marker64), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: prefix.appendingPathComponent(Self.marker32), withIntermediateDirectories: true)
    #expect(!runtime(for: "x").isInstalled(in: prefix))
  }

  @Test
  func `hands back the installer only when its bytes match the pin`() throws {
    let resources = try scratch()
    defer { remove(resources) }
    try write("wine mono bytes", to: resources.appendingPathComponent("Addons/mono.msi"))
    let url = try runtime(for: "wine mono bytes").installer(in: resources)
    #expect(url.lastPathComponent == "mono.msi")
  }

  @Test
  func `refuses an installer that was altered, is missing or is a link`() throws {
    let resources = try scratch()
    defer { remove(resources) }
    let sut = runtime(for: "pinned bytes")
    #expect(throws: LauncherError.self) { try sut.installer(in: resources) }
    try write("other bytes", to: resources.appendingPathComponent("Addons/mono.msi"))
    #expect(throws: LauncherError.self) { try sut.installer(in: resources) }
    let real = resources.appendingPathComponent("Addons/real.msi")
    try write("pinned bytes", to: real)
    let link = resources.appendingPathComponent("Addons/linked.msi")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let linked = runtime(for: "pinned bytes", file: "Addons/linked.msi")
    #expect(throws: LauncherError.self) { try linked.installer(in: resources) }
  }

  @Test
  func `the manifest carries the declaration and only a bundled store client game may have one`()
    throws
  {
    let sut = runtime(for: "x")
    let seeded = BundleManifest(
      version: "v1",
      gameFiles: [
        ManifestFile(path: "NFS16.exe", size: 1, sha256: String(repeating: "a", count: 64))
      ],
      gameID: .nfs2015, storeClient: SeededFixture.plan, renderers: SeededFixture.renderers,
      managedRuntime: sut)
    try seeded.validate()
    #expect(seeded.managed == sut)
    let decoded = try JSONDecoder().decode(
      BundleManifest.self, from: JSONEncoder().encode(seeded))
    #expect(decoded.managed == sut)
    let importing = BundleManifest(
      version: "v1", gameFiles: [], gameID: .nfs2015, referencesInstallation: true,
      storeClient: SeededFixture.plan, renderers: SeededFixture.renderers, managedRuntime: sut)
    #expect(throws: LauncherError.self) { try importing.validate() }
    let copying = BundleManifest(
      version: "v1",
      gameFiles: [
        ManifestFile(path: "speed.exe", size: 1, sha256: String(repeating: "a", count: 64))
      ],
      gameID: .nfsmw, managedRuntime: sut)
    #expect(throws: LauncherError.self) { try copying.validate() }
  }

  @Test
  func `a manifest without the field still decodes`() throws {
    let json = Data(#"{"version":"v1","gameFiles":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(BundleManifest.self, from: json)
    #expect(decoded.managed == nil)
  }

  // MARK: launch environment

  @Test
  func `the managed runtime is enabled for Need for Speed only once it is available`() {
    #expect(
      LaunchEnvironment.overrides(.nfs2015, managedCode: false)
        == "IGOProxy32.exe=d;winemenubuilder.exe=d;mscoree,mshtml=")
    #expect(
      LaunchEnvironment.overrides(.nfs2015, managedCode: true)
        == "IGOProxy32.exe=d;winemenubuilder.exe=d;mshtml=")
    for kind in [GameKind.nfsmw, .cod4, .farcry2] {
      #expect(
        LaunchEnvironment.overrides(kind, managedCode: true)
          == LaunchEnvironment.overrides(kind, managedCode: false))
    }
  }

  @Test
  func `the runtime environment follows what the prefix really contains`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let sut = WineRuntime(
      paths: fixture.paths, output: .nullDevice, managedRuntime: runtime(for: "x"))
    let before = try sut.environment(prefix: fixture.paths.prefix)
    #expect(before["WINEDLLOVERRIDES"]?.contains("mscoree,mshtml=") == true)
    try write("x", to: fixture.paths.prefix.appendingPathComponent(Self.marker64))
    try write("x", to: fixture.paths.prefix.appendingPathComponent(Self.marker32))
    let after = try sut.environment(prefix: fixture.paths.prefix)
    #expect(after["WINEDLLOVERRIDES"] == "IGOProxy32.exe=d;winemenubuilder.exe=d;mshtml=")
    // An app without a declaration never enables it, whatever the prefix holds.
    let plain = WineRuntime(paths: fixture.paths, output: .nullDevice)
    #expect(
      try plain.environment(prefix: fixture.paths.prefix)["WINEDLLOVERRIDES"]
        == "IGOProxy32.exe=d;winemenubuilder.exe=d;mscoree,mshtml=")
  }

  // MARK: installation

  /// A stand-in for Wine that records its arguments, and creates the libraries when asked to
  /// run msiexec, so the real command line is observed without Wine.
  private func fakeWine(in fixture: SeededFixture, status: Int32 = 0, installs: Bool = true) throws
    -> URL
  {
    let log = fixture.root.appendingPathComponent("wine-arguments")
    let script = """
      #!/bin/sh
      printf '%s\\n' "$@" >> '\(log.path)'
      echo "overrides=$WINEDLLOVERRIDES" >> '\(log.path)'
      \(installs ? """
      mkdir -p "$WINEPREFIX/drive_c/windows/mono/mono-2.0/bin"
      : > "$WINEPREFIX/drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86_64.dll"
      : > "$WINEPREFIX/drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86.dll"
      """ : "")
      exit \(status)
      """
    try write(script, to: fixture.paths.wine)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.paths.wine.path)
    let server = fixture.paths.wineServer
    try write("#!/bin/sh\nexit 0\n", to: server)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: server.path)
    return log
  }

  private func stage(_ fixture: SeededFixture, bytes: String = "msi bytes") throws
    -> ManagedRuntime
  {
    try write(bytes, to: fixture.paths.resources.appendingPathComponent("Addons/mono.msi"))
    try FileManager.default.createDirectory(
      at: fixture.paths.prefix, withIntermediateDirectories: true)
    return runtime(for: bytes)
  }

  @Test
  func `installs it with msiexec through the bundled Wine and then reports it installed`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let managed = try stage(fixture)
    let log = try fakeWine(in: fixture)
    let sut = WineRuntime(paths: fixture.paths, output: .nullDevice, managedRuntime: managed)
    #expect(try sut.installManagedRuntime(into: fixture.paths.prefix))
    let recorded = try String(contentsOf: log, encoding: .utf8)
    #expect(recorded.contains("msiexec\n/i\nZ:"))
    #expect(recorded.contains("\\Addons\\mono.msi\n/qn"))
    // The installer runs with the managed runtime still off, as the app always started it.
    #expect(recorded.contains("overrides=IGOProxy32.exe=d;winemenubuilder.exe=d;mscoree,mshtml="))
    #expect(managed.isInstalled(in: fixture.paths.prefix))
  }

  @Test
  func `does nothing when it is already installed`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let managed = try stage(fixture)
    let log = try fakeWine(in: fixture)
    let sut = WineRuntime(paths: fixture.paths, output: .nullDevice, managedRuntime: managed)
    #expect(try sut.installManagedRuntime(into: fixture.paths.prefix))
    try FileManager.default.removeItem(at: log)
    #expect(try !sut.installManagedRuntime(into: fixture.paths.prefix))
    #expect(!FileManager.default.fileExists(atPath: log.path))
  }

  @Test
  func `does nothing when the app declares no managed runtime`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    let log = try fakeWine(in: fixture)
    let sut = WineRuntime(paths: fixture.paths, output: .nullDevice)
    #expect(try !sut.installManagedRuntime(into: fixture.paths.prefix))
    #expect(!FileManager.default.fileExists(atPath: log.path))
  }

  @Test
  func `fails when Wine fails, and when the libraries still are not there`() throws {
    for (status, installs) in [(Int32(1), true), (0, false)] {
      let fixture = try SeededFixture()
      defer { fixture.remove() }
      let managed = try stage(fixture)
      _ = try fakeWine(in: fixture, status: status, installs: installs)
      let sut = WineRuntime(paths: fixture.paths, output: .nullDevice, managedRuntime: managed)
      #expect(throws: LauncherError.self) {
        try sut.installManagedRuntime(into: fixture.paths.prefix)
      }
    }
  }

  @Test
  func `never runs an installer whose bytes do not match the pin`() throws {
    let fixture = try SeededFixture()
    defer { fixture.remove() }
    _ = try stage(fixture, bytes: "tampered")
    let log = try fakeWine(in: fixture)
    let pinned = runtime(for: "the pinned installer")
    let sut = WineRuntime(paths: fixture.paths, output: .nullDevice, managedRuntime: pinned)
    #expect(throws: LauncherError.self) {
      try sut.installManagedRuntime(into: fixture.paths.prefix)
    }
    #expect(!FileManager.default.fileExists(atPath: log.path))
  }
}
