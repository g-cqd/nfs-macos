import Darwin
import Foundation
import Synchronization
import Testing

@testable import HubCore

/// Answers `wine --version` from fixed values and records how it was asked.
private final class FakeRunner: RuntimeProcessRunner {
  struct Call: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    /// Whether the executable existed when it was asked for.
    let executableExisted: Bool
  }

  let calls = Mutex<[Call]>([])
  let result: RuntimeProcessResult
  let failure: HubError?
  /// Runs while the fake "runs wine", before the installer renames the staging folder.
  let onRun: (@Sendable () -> Void)?

  init(
    result: RuntimeProcessResult = RuntimeProcessResult(exitCode: 0, output: "wine-11.0\n"),
    failure: HubError? = nil, onRun: (@Sendable () -> Void)? = nil
  ) {
    self.result = result
    self.failure = failure
    self.onRun = onRun
  }

  func run(
    executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval
  ) throws(HubError) -> RuntimeProcessResult {
    let call = Call(
      executable: executable.path, arguments: arguments, environment: environment,
      timeout: timeout,
      executableExisted: FileManager.default.isExecutableFile(atPath: executable.path))
    calls.withLock { $0.append(call) }
    onRun?()
    if let failure { throw failure }
    return result
  }
}

/// A tiny runtime on disk, laid out like the real one, with its manifest and links file.
private final class Fixture {
  let root: URL
  let fileManager = FileManager.default
  var wineTree: URL { root.appendingPathComponent("src/wine") }
  var helpers: URL { root.appendingPathComponent("src/helpers") }
  var manifest: URL { root.appendingPathComponent("src/hub-9.manifest") }
  var links: URL { root.appendingPathComponent("src/hub-9.manifest.links") }
  var apps: URL { root.appendingPathComponent("Applications") }
  var app: URL { apps.appendingPathComponent("GameHub Runtime hub-9.app") }
  var staging: URL { apps.appendingPathComponent("GameHub Runtime hub-9.app.staging-4242") }
  private(set) var manifestSHA = ""

  init(sidecarInWine: Bool = false) throws {
    let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(resolved) }
    root = URL(fileURLWithPath: String(cString: resolved) + "/rt-\(UUID().uuidString)")
    try write("src/wine/bin/wine", "fake wine\n", mode: 0o755)
    try write("src/wine/bin/wineserver", "fake wineserver\n", mode: 0o755)
    try write("src/wine/lib/libfreetype.6.dylib", "freetype\n", mode: 0o644)
    try write("src/wine/lib/wine/x86_64-unix/winemetal.so", "metal\n", mode: 0o755)
    try fileManager.createDirectory(
      at: wineTree.appendingPathComponent("lib/wine/dxgi"), withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(
      atPath: wineTree.path + "/lib/wine/dxgi/winemetal.so",
      withDestinationPath: "../x86_64-unix/winemetal.so")
    if sidecarInWine { try write("src/wine/bin/x87sidecar", "sidecar\n", mode: 0o755) }
    try write("src/helpers/x87sidecar", "sidecar\n", mode: 0o755)

    var lines = ""
    for entry in try RuntimeTree.entries(under: wineTree.path) where entry.kind == .file {
      let hash = try #require(try DatastoreIO.sha256Hex(fileAt: wineTree.path + "/" + entry.path))
      lines += "\(hash)  ./\(entry.path)\n"
    }
    try lines.write(to: manifest, atomically: true, encoding: .utf8)
    try "./lib/wine/dxgi/winemetal.so -> ../x86_64-unix/winemetal.so\n".write(
      to: links, atomically: true, encoding: .utf8)
    manifestSHA = try #require(try DatastoreIO.sha256Hex(fileAt: manifest.path))
  }

  deinit { try? fileManager.removeItem(at: root) }

  func write(_ path: String, _ text: String, mode: Int) throws {
    let url = root.appendingPathComponent(path)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }

  var request: RuntimeInstallRequest {
    RuntimeInstallRequest(
      id: "hub-9", wineTree: wineTree, helpersDir: helpers, manifest: manifest, links: links,
      appURL: app)
  }

  func installer(
    runner: FakeRunner = FakeRunner(), free: Int64 = 100 << 30
  ) -> RuntimeAppInstaller {
    var installer = RuntimeAppInstaller()
    installer.runner = runner
    installer.freeBytes = { _ in free }
    installer.processID = 4242
    installer.now = { Date(timeIntervalSince1970: 1_700_000_000) }
    return installer
  }

  func mode(_ url: URL) throws -> Int {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
  }

  /// The names in the Applications folder: what an install left behind.
  func appsContents() -> [String] {
    ((try? fileManager.contentsOfDirectory(atPath: apps.path)) ?? []).sorted()
  }
}

@Suite struct RuntimeAppInstallTests {
  @Test func installsTheLayoutAndRecordsIt() throws {
    let fixture = try Fixture()
    let runner = FakeRunner()
    let result = try fixture.installer(runner: runner).install(fixture.request)

    let app = fixture.app
    #expect(fixture.appsContents() == ["GameHub Runtime hub-9.app"])
    #expect(result.wineVersion == "wine-11.0")
    #expect(result.info.id == "hub-9")
    #expect(result.info.manifestSHA256 == fixture.manifestSHA)
    #expect(result.info.wine.path == app.path + "/Contents/SharedSupport/Wine")
    #expect(result.info.wineBinary.path == app.path + "/Contents/SharedSupport/Wine/bin/wine")
    #expect(result.info.helpersDir.path == app.path + "/Contents/Helpers")
    #expect(result.info.x87sidecar?.path == app.path + "/Contents/Helpers/x87sidecar")
    #expect(result.filesVerified == 5)

    let launcher = try fixture.fileManager.destinationOfSymbolicLink(
      atPath: app.path + "/Contents/MacOS/wine")
    #expect(launcher == "../SharedSupport/Wine/bin/wine")
    let link = try fixture.fileManager.destinationOfSymbolicLink(
      atPath: app.path + "/Contents/SharedSupport/Wine/lib/wine/dxgi/winemetal.so")
    #expect(link == "../x86_64-unix/winemetal.so")
    #expect(
      try fixture.mode(app.appendingPathComponent("Contents/SharedSupport/Wine/bin/wine")) == 0o755)
    #expect(
      try fixture.mode(
        app.appendingPathComponent("Contents/SharedSupport/Wine/lib/libfreetype.6.dylib")) == 0o644)
    #expect(try fixture.mode(app.appendingPathComponent("Contents/Helpers/x87sidecar")) == 0o755)
    #expect(
      !fixture.fileManager.fileExists(
        atPath: app.path + "/Contents/SharedSupport/Wine/bin/x87sidecar"))

    let plist = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil)
        as? [String: Any])
    #expect(plist["CFBundleIdentifier"] as? String == "local.gamehub.runtime.hub-9")
    #expect(plist["CFBundleName"] as? String == "GameHub Runtime hub-9")
    #expect(plist["CFBundlePackageType"] as? String == "APPL")
    #expect(plist["CFBundleExecutable"] as? String == "wine")
    #expect(plist["LSUIElement"] as? Bool == true)

    let metadata = app.appendingPathComponent("Contents/Resources/runtime")
    let record = try RuntimeRecord.read(at: metadata.appendingPathComponent("runtime.json").path)
    #expect(record.schemaVersion == 1)
    #expect(record.id == "hub-9")
    #expect(record.manifestSHA256 == fixture.manifestSHA)
    #expect(record.source == fixture.wineTree.path)
    #expect(record.installedAt == Date(timeIntervalSince1970: 1_700_000_000))
    let sidecarHash = try #require(
      try DatastoreIO.sha256Hex(fileAt: fixture.helpers.path + "/x87sidecar"))
    #expect(record.helpers == ["x87sidecar": sidecarHash])
    #expect(
      try Data(contentsOf: metadata.appendingPathComponent("hub-9.manifest"))
        == Data(contentsOf: fixture.manifest))
    #expect(
      try Data(contentsOf: metadata.appendingPathComponent("hub-9.manifest.links"))
        == Data(contentsOf: fixture.links))

    let call = try #require(runner.calls.withLock { $0 }.first)
    #expect(call.executable == fixture.staging.path + "/Contents/SharedSupport/Wine/bin/wine")
    #expect(call.executableExisted)
    #expect(call.arguments == ["--version"])
    #expect(call.timeout == 60)
    #expect(Set(call.environment.keys) == ["PATH", "HOME"])
    #expect(call.environment["PATH"] == "/usr/bin:/bin")
    let home = try #require(call.environment["HOME"])
    #expect(!fixture.fileManager.fileExists(atPath: home))

    #expect(try RuntimeApp.verify(app, expectedSHA256: fixture.manifestSHA).isOK)
  }

  @Test func refusesAnExistingTarget() throws {
    let fixture = try Fixture()
    try fixture.fileManager.createDirectory(at: fixture.app, withIntermediateDirectories: true)
    let marker = fixture.app.appendingPathComponent("keep")
    try "x".write(to: marker, atomically: true, encoding: .utf8)
    let runner = FakeRunner()
    do {
      _ = try fixture.installer(runner: runner).install(fixture.request)
      Issue.record("expected a refusal")
    } catch {
      guard case .blocked = error else {
        Issue.record("expected .blocked, got \(error)")
        return
      }
    }
    #expect(fixture.fileManager.fileExists(atPath: marker.path))
    #expect(fixture.appsContents() == ["GameHub Runtime hub-9.app"])
    #expect(runner.calls.withLock { $0.isEmpty })
  }

  @Test func refusesATargetUnderARefusedRoot() throws {
    let fixture = try Fixture()
    let refused = fixture.root.appendingPathComponent("refused")
    try fixture.fileManager.createDirectory(at: refused, withIntermediateDirectories: true)
    var installer = fixture.installer()
    installer.refusedRoots = [refused.path]

    var request = fixture.request
    request.appURL = refused.appendingPathComponent("Apps/GameHub Runtime hub-9.app")
    do {
      _ = try installer.install(request)
      Issue.record("expected a refusal")
    } catch {
      guard case .unsafePath = error else {
        Issue.record("expected .unsafePath, got \(error)")
        return
      }
    }
    #expect(!fixture.fileManager.fileExists(atPath: refused.path + "/Apps"))

    // A link in the way does not hide the root.
    try fixture.fileManager.createDirectory(at: fixture.apps, withIntermediateDirectories: true)
    try fixture.fileManager.createSymbolicLink(
      atPath: fixture.apps.path + "/inside", withDestinationPath: refused.path)
    request.appURL = fixture.apps.appendingPathComponent("inside/GameHub Runtime hub-9.app")
    do {
      _ = try installer.install(request)
      Issue.record("expected a refusal")
    } catch {
      guard case .unsafePath = error else {
        Issue.record("expected .unsafePath, got \(error)")
        return
      }
    }
    #expect(try fixture.fileManager.contentsOfDirectory(atPath: refused.path).isEmpty)
    #expect(RuntimeAppInstaller().refusedRoots == ["/Volumes/ExT2"])
  }

  @Test func refusesWhenSpaceIsShort() throws {
    let fixture = try Fixture()
    let sourceBytes = Int64(
      "fake wine\nfake wineserver\nfreetype\nmetal\nsidecar\n".utf8.count)
    do {
      _ = try fixture.installer(free: sourceBytes + 2 * 1024 * 1024 * 1024 - 1).install(
        fixture.request)
      Issue.record("expected a refusal")
    } catch {
      #expect(
        error == .belowFloor(needed: sourceBytes, free: sourceBytes + (2 << 30) - 1, floor: 2 << 30)
      )
    }
    #expect(!fixture.fileManager.fileExists(atPath: fixture.apps.path))

    var unknown = fixture.installer()
    unknown.freeBytes = { _ in nil }
    #expect(throws: HubError.self) { try unknown.install(fixture.request) }

    // Exactly enough is enough.
    _ = try fixture.installer(free: sourceBytes + 2 * 1024 * 1024 * 1024).install(fixture.request)
  }

  @Test func aCorruptedStagedFileLeavesNothing() throws {
    let fixture = try Fixture()
    let runner = FakeRunner()
    var installer = fixture.installer(runner: runner)
    installer.afterCopy = { (staging: URL) throws(HubError) in
      let file = staging.appendingPathComponent(
        "Contents/SharedSupport/Wine/lib/libfreetype.6.dylib")
      do {
        try "tampered\n".write(to: file, atomically: false, encoding: .utf8)
      } catch {
        throw .io("hook: \(error)")
      }
    }
    do {
      _ = try installer.install(fixture.request)
      Issue.record("expected a failure")
    } catch {
      guard case .io(let message) = error else {
        Issue.record("expected .io, got \(error)")
        return
      }
      #expect(message.contains("lib/libfreetype.6.dylib"))
    }
    #expect(fixture.appsContents().isEmpty)
    #expect(runner.calls.withLock { $0.isEmpty })
  }

  @Test func aFailingWineLeavesNothing() throws {
    let fixture = try Fixture()
    let failing = [
      FakeRunner(result: RuntimeProcessResult(exitCode: 1, output: "boom\n")),
      FakeRunner(result: RuntimeProcessResult(exitCode: 0, output: "\n")),
      FakeRunner(result: RuntimeProcessResult(exitCode: 0, output: "not wine\n")),
      FakeRunner(failure: .io("timed out")),
    ]
    for runner in failing {
      do {
        _ = try fixture.installer(runner: runner).install(fixture.request)
        Issue.record("expected a failure")
      } catch {
        guard case .io = error else {
          Issue.record("expected .io, got \(error)")
          return
        }
      }
      #expect(fixture.appsContents().isEmpty)
    }
  }

  @Test func aStagingFolderThatIsNotOursIsLeftAlone() throws {
    let fixture = try Fixture()
    try fixture.fileManager.createDirectory(at: fixture.staging, withIntermediateDirectories: true)
    do {
      _ = try fixture.installer().install(fixture.request)
      Issue.record("expected a refusal")
    } catch {
      guard case .blocked = error else {
        Issue.record("expected .blocked, got \(error)")
        return
      }
    }
    #expect(fixture.appsContents() == ["GameHub Runtime hub-9.app.staging-4242"])
  }

  @Test func keepsReadOnlyFoldersExactAndStillCleansUpAfterAFailure() throws {
    // Happy path: a 0555 source folder ends 0555 in the app.
    let fixture = try Fixture()
    let readOnly = fixture.wineTree.appendingPathComponent("lib")
    try fixture.fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    defer {
      RuntimeTreeCopier.makeRemovable(fixture.wineTree.path)
      RuntimeTreeCopier.makeRemovable(fixture.app.path)
    }
    _ = try fixture.installer().install(fixture.request)
    #expect(
      try fixture.mode(fixture.app.appendingPathComponent("Contents/SharedSupport/Wine/lib"))
        == 0o555)
    #expect(try RuntimeApp.verify(fixture.app).isOK)

    // Failure after the modes are restored (the target appears during the version check): the
    // read-only staging folder is still removed, and the intruder is left alone.
    let racing = try Fixture()
    try racing.fileManager.setAttributes(
      [.posixPermissions: 0o555],
      ofItemAtPath: racing.wineTree.appendingPathComponent("lib").path)
    defer { RuntimeTreeCopier.makeRemovable(racing.wineTree.path) }
    let target = racing.app
    let runner = FakeRunner(onRun: {
      try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    })
    do {
      _ = try racing.installer(runner: runner).install(racing.request)
      Issue.record("expected a refusal")
    } catch {
      guard case .blocked = error else {
        Issue.record("expected .blocked, got \(error)")
        return
      }
    }
    #expect(racing.appsContents() == ["GameHub Runtime hub-9.app"])
  }

  @Test func refusesATargetOnTheSameVolumeAsARefusedRoot() throws {
    // The Data volume is a mount point; /Users and the temporary folder live on it without being
    // under its path.
    try #require(FileManager.default.fileExists(atPath: "/System/Volumes/Data"))
    let fixture = try Fixture()
    var installer = fixture.installer()
    installer.refusedRoots = ["/System/Volumes/Data"]
    do {
      _ = try installer.install(fixture.request)
      Issue.record("expected a refusal")
    } catch {
      guard case .unsafePath(let message) = error else {
        Issue.record("expected .unsafePath, got \(error)")
        return
      }
      #expect(message.contains("same volume"))
    }
    #expect(!fixture.fileManager.fileExists(atPath: fixture.apps.path))

    // A refused root that is just a folder on this volume does not refuse everything.
    let folder = fixture.root.appendingPathComponent("not-mounted")
    try fixture.fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    installer.refusedRoots = [folder.path]
    _ = try installer.install(fixture.request)
  }

  @Test func defaultAppURLNamesTheBundle() {
    let url = RuntimeApp.defaultAppURL(id: "hub-0", home: URL(fileURLWithPath: "/Users/x"))
    #expect(url.path == "/Users/x/Applications/GameHub Runtime hub-0.app")
  }

  @Test func refusesSourcesThatDisagreeWithTheManifest() throws {
    let withSidecar = try Fixture(sidecarInWine: true)
    do {
      _ = try withSidecar.installer().install(withSidecar.request)
      Issue.record("expected a refusal")
    } catch {
      guard case .invalid(let message) = error else {
        Issue.record("expected .invalid, got \(error)")
        return
      }
      #expect(message.contains("bin/x87sidecar"))
    }

    let extra = try Fixture()
    try extra.write("src/wine/share/extra.txt", "x", mode: 0o644)
    #expect(throws: HubError.self) { try extra.installer().install(extra.request) }

    let missing = try Fixture()
    try missing.fileManager.removeItem(
      at: missing.wineTree.appendingPathComponent("bin/wineserver"))
    #expect(throws: HubError.self) { try missing.installer().install(missing.request) }

    let noHelper = try Fixture()
    try noHelper.fileManager.removeItem(at: noHelper.helpers.appendingPathComponent("x87sidecar"))
    #expect(throws: HubError.self) { try noHelper.installer().install(noHelper.request) }

    for fixture in [extra, missing, noHelper, withSidecar] {
      #expect(!fixture.fileManager.fileExists(atPath: fixture.apps.path))
    }
  }
}

@Suite struct RuntimeAppVerifyTests {
  private func installed() throws -> Fixture {
    let fixture = try Fixture()
    _ = try fixture.installer().install(fixture.request)
    return fixture
  }

  @Test func locateStates() throws {
    let fixture = try Fixture()
    #expect(RuntimeApp.locate(fixture.app) == .notFound)

    _ = try fixture.installer().install(fixture.request)
    guard case .ok(let info) = RuntimeApp.locate(fixture.app, expectedSHA256: fixture.manifestSHA)
    else {
      Issue.record("expected .ok")
      return
    }
    #expect(info.id == "hub-9")
    #expect(RuntimeApp.locate(fixture.app) == .ok(info))

    let other = String(repeating: "a", count: 64)
    #expect(
      RuntimeApp.locate(fixture.app, expectedSHA256: other)
        == .mismatch(expected: other, actual: fixture.manifestSHA))

    // A manifest that is not the one recorded.
    let manifest = fixture.app.appendingPathComponent("Contents/Resources/runtime/hub-9.manifest")
    try fixture.fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path)
    try "tampered\n".write(to: manifest, atomically: true, encoding: .utf8)
    guard case .invalid(let reason) = RuntimeApp.locate(fixture.app) else {
      Issue.record("expected .invalid for a changed manifest")
      return
    }
    #expect(reason.contains("runtime.json records"))
  }

  @Test func locateRejectsABrokenStructure() throws {
    let wineBinary = "Contents/SharedSupport/Wine/bin/wine"
    let breakers: [(String, (URL) throws -> Void)] = [
      (
        "runtime.json",
        {
          try FileManager.default.removeItem(
            at: $0.appendingPathComponent("Contents/Resources/runtime/runtime.json"))
        }
      ),
      (
        "Info.plist",
        { try FileManager.default.removeItem(at: $0.appendingPathComponent("Contents/Info.plist")) }
      ),
      (
        "wine binary",
        { try FileManager.default.removeItem(at: $0.appendingPathComponent(wineBinary)) }
      ),
      (
        "not executable",
        {
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: $0.appendingPathComponent(wineBinary).path)
        }
      ),
      (
        "sidecar",
        {
          try FileManager.default.removeItem(
            at: $0.appendingPathComponent("Contents/Helpers/x87sidecar"))
        }
      ),
      (
        "launcher",
        { try FileManager.default.removeItem(at: $0.appendingPathComponent("Contents/MacOS/wine")) }
      ),
    ]
    for (name, breaker) in breakers {
      let fixture = try installed()
      try breaker(fixture.app)
      guard case .invalid = RuntimeApp.locate(fixture.app) else {
        Issue.record("\(name): expected .invalid")
        continue
      }
    }
    let fixture = try Fixture()
    try fixture.write("Applications/GameHub Runtime hub-9.app", "a file", mode: 0o644)
    guard case .invalid = RuntimeApp.locate(fixture.app) else {
      Issue.record("a file is not an app")
      return
    }
  }

  @Test func locateRejectsAFolderThatIsALink() throws {
    for folder in [
      "Contents/SharedSupport/Wine", "Contents/SharedSupport", "Contents/Helpers",
      "Contents/Resources/runtime",
    ] {
      let fixture = try installed()
      let path = fixture.app.path + "/" + folder
      let moved = fixture.root.path + "/moved"
      try fixture.fileManager.moveItem(atPath: path, toPath: moved)
      try fixture.fileManager.createSymbolicLink(atPath: path, withDestinationPath: moved)
      guard case .invalid(let reason) = RuntimeApp.locate(fixture.app) else {
        Issue.record("\(folder): expected .invalid")
        continue
      }
      #expect(reason.contains(folder))
    }
  }

  @Test func verifyFindsExtraChangedAndMissingFiles() throws {
    let fixture = try installed()
    let wine = fixture.app.appendingPathComponent("Contents/SharedSupport/Wine")
    #expect(try RuntimeApp.verify(fixture.app).isOK)

    try "extra".write(
      to: wine.appendingPathComponent("lib/extra.dll"), atomically: true, encoding: .utf8)
    try "sidecar\n".write(
      to: wine.appendingPathComponent("bin/x87sidecar"), atomically: true, encoding: .utf8)
    let report = try RuntimeApp.verify(fixture.app)
    #expect(!report.isOK)
    #expect(report.problems.contains { $0.contains("unexpected file lib/extra.dll") })
    #expect(report.problems.contains { $0.contains("unexpected file bin/x87sidecar") })

    try fixture.fileManager.removeItem(at: wine.appendingPathComponent("lib/extra.dll"))
    try fixture.fileManager.removeItem(at: wine.appendingPathComponent("bin/x87sidecar"))
    try fixture.fileManager.removeItem(at: wine.appendingPathComponent("bin/wineserver"))
    try fixture.fileManager.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: wine.appendingPathComponent("lib/libfreetype.6.dylib").path)
    try "changed\n".write(
      to: wine.appendingPathComponent("lib/libfreetype.6.dylib"), atomically: true, encoding: .utf8)
    let link = wine.appendingPathComponent("lib/wine/dxgi/winemetal.so").path
    try fixture.fileManager.removeItem(atPath: link)
    try fixture.fileManager.createSymbolicLink(atPath: link, withDestinationPath: "elsewhere")
    let damaged = try RuntimeApp.verify(fixture.app)
    #expect(damaged.problems.contains { $0.contains("missing file bin/wineserver") })
    #expect(damaged.problems.contains { $0.contains("lib/libfreetype.6.dylib has SHA-256") })
    #expect(
      damaged.problems.contains { $0.contains("lib/wine/dxgi/winemetal.so is a link to elsewhere") }
    )

    // An extra helper is caught too.
    try "tool".write(
      to: fixture.app.appendingPathComponent("Contents/Helpers/other"), atomically: true,
      encoding: .utf8)
    let helpers = try RuntimeApp.verify(fixture.app)
    #expect(helpers.problems.contains { $0.contains("Helpers: unexpected file other") })
  }

  @Test func verifyReportsTheStateWithoutDeepChecksWhenNotOK() throws {
    let fixture = try installed()
    let other = String(repeating: "b", count: 64)
    let report = try RuntimeApp.verify(fixture.app, expectedSHA256: other)
    #expect(report.state == .mismatch(expected: other, actual: fixture.manifestSHA))
    #expect(!report.isOK)
    #expect(try RuntimeApp.verify(fixture.app.appendingPathComponent("nope")).state == .notFound)
  }
}

@Suite struct RuntimeFileListTests {
  private let hash = String(repeating: "0", count: 64)

  @Test func parsesTheTwoFiles() throws {
    let list = try RuntimeFileList.parse(
      manifest: "\(hash)  ./bin/wine\n\(hash)  ./lib/a b.dylib\n",
      links: "./lib/l.so -> ../bin/wine\n")
    #expect(list.files.map(\.path) == ["bin/wine", "lib/a b.dylib"])
    #expect(list.links == [.init(path: "lib/l.so", target: "../bin/wine")])
  }

  @Test func rejectsLinkChainsThatClimbOutOfTheTree() {
    // `d/up` climbs to the root, so `d/up/d/up/../../..` would climb out through it.
    #expect(throws: HubError.self) {
      try RuntimeFileList.parse(
        manifest: "\(hash)  ./bin/wine\n",
        links: "./d/up -> ..\n./e -> d/up/d/up/../../..\n")
    }
    // Nothing may sit under a link, files included.
    #expect(throws: HubError.self) {
      try RuntimeFileList.parse(
        manifest: "\(hash)  ./d/up/wine\n", links: "./d/up -> ../bin\n")
    }
    #expect(throws: HubError.self) {
      try RuntimeFileList.parse(
        manifest: "\(hash)  ./bin/wine\n", links: "./a -> .\n./a/b -> ../bin/wine\n")
    }
    // A link that only ends on a link is each checked by itself.
    #expect(
      throws: Never.self,
      performing: {
        try RuntimeFileList.parse(
          manifest: "\(hash)  ./bin/wine\n", links: "./a -> bin/wine\n./b -> a\n")
      })
  }

  @Test func rejectsMalformedInput() {
    let bad: [(String, String)] = [
      ("", ""),
      ("\(hash) ./bin/wine\n", ""),
      ("abc  ./bin/wine\n", ""),
      ("\(hash)  bin/wine\n", ""),
      ("\(hash)  ./bin/../wine\n", ""),
      ("\(hash)  ./bin/wine\n\n\(hash)  ./b\n", ""),
      ("\(hash)  ./bin/wine\n\(hash)  ./bin/wine\n", ""),
      ("\(hash)  ./bin/wine\n", "./l -> /abs\n"),
      ("\(hash)  ./bin/wine\n", "./l -> ../../out\n"),
      ("\(hash)  ./bin/wine\n", "./bin/wine -> x\n"),
      ("\(hash)  ./bin/wine\n", "./l => x\n"),
    ]
    for (manifest, links) in bad {
      #expect(throws: HubError.self) { try RuntimeFileList.parse(manifest: manifest, links: links) }
    }
  }
}

@Suite struct RuntimeCommandTests {
  private func run(_ arguments: [String]) -> (status: Int32, out: String, err: String) {
    let out = Mutex("")
    let err = Mutex("")
    let status = RuntimeCommand.run(
      arguments, output: { text in out.withLock { $0 += text } },
      diagnostics: { text in err.withLock { $0 += text } })
    return (status, out.withLock { $0 }, err.withLock { $0 })
  }

  @Test func usageErrorsExitOne() {
    #expect(run([]).status == 1)
    #expect(run(["nope"]).status == 1)
    #expect(run(["install", "--id", "hub-9"]).status == 1)
    #expect(run(["verify"]).status == 1)
    #expect(run(["verify", "/x", "--expect-sha", "short"]).status == 1)
    #expect(run(["verify", "/x", "--bogus"]).status == 1)
  }

  @Test func verifyExitCodes() throws {
    let fixture = try Fixture()
    #expect(run(["verify", fixture.app.path]).status == 2)

    _ = try fixture.installer().install(fixture.request)
    let ok = run(["verify", fixture.app.path, "--expect-sha", fixture.manifestSHA])
    #expect(ok.status == 0)
    #expect(ok.out.contains("OK:"))

    let json = run(["verify", fixture.app.path, "--json"])
    #expect(json.status == 0)
    #expect(json.out.contains("\"status\" : \"ok\""))

    let other = String(repeating: "c", count: 64)
    let mismatch = run(["verify", fixture.app.path, "--expect-sha", other])
    #expect(mismatch.status == 4)
    #expect(mismatch.out.contains("MISMATCH"))

    try "extra".write(
      to: fixture.app.appendingPathComponent("Contents/SharedSupport/Wine/extra"), atomically: true,
      encoding: .utf8)
    #expect(run(["verify", fixture.app.path]).status == 4)
  }

  @Test func installPreconditionExitsTwo() throws {
    let fixture = try Fixture()
    try fixture.fileManager.createDirectory(at: fixture.app, withIntermediateDirectories: true)
    let result = run([
      "install", "--id", "hub-9", "--from", fixture.wineTree.path, "--helpers",
      fixture.helpers.path,
      "--manifest", fixture.manifest.path, "--links", fixture.links.path, "--to", fixture.app.path,
    ])
    #expect(result.status == 2)
    #expect(result.err.contains("already exists"))
  }
}

@Suite struct LiveRuntimeProcessRunnerTests {
  private let environment = ["PATH": "/usr/bin:/bin"]

  @Test func keepsAtMost64KiBOfOutput() throws {
    let result = try LiveRuntimeProcessRunner().run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a"], environment: environment,
      timeout: 30)
    #expect(result.exitCode == 0)
    #expect(result.output.utf8.count == 64 * 1024)
  }

  @Test func timesOutAndStopsTheChild() {
    let started = Date()
    do {
      _ = try LiveRuntimeProcessRunner().run(
        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
        environment: environment, timeout: 0.5)
      Issue.record("expected a timeout")
    } catch {
      guard case .io(let message) = error else {
        Issue.record("expected .io, got \(error)")
        return
      }
      #expect(message.contains("did not finish"))
    }
    #expect(Date().timeIntervalSince(started) < 20)
  }
}
