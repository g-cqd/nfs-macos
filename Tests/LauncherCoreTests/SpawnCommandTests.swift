import Darwin
import Foundation
import Testing

@testable import LauncherCore

/// Counts how often a fake 4 KiB page-size request was applied to the spawn attributes.
private final class Requests: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var applied: Int { lock.withLock { count } }
  func record() { lock.withLock { count += 1 } }
}

private func run(
  _ executable: String, _ arguments: [String], in directory: URL,
  environment: [String: String] = [:], fourKilobyte: Bool = false,
  support: FourKilobytePageSupport = .system, root: URL
) throws -> (status: Int32, output: String) {
  let log = root.appendingPathComponent("output-\(UUID().uuidString)")
  try Data().write(to: log)
  let handle = try FileHandle(forWritingTo: log)
  let status = try SpawnCommand(
    executable: URL(fileURLWithPath: executable), arguments: arguments, directory: directory,
    environment: environment, requestsFourKilobytePages: fourKilobyte, support: support
  ).run(output: handle)
  try handle.close()
  return (status, try String(contentsOf: log, encoding: .utf8))
}

struct SpawnCommandTests {
  @Test
  func `passes punctuation as data without shell expansion`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let literal = "spaces & $(touch should-not-exist) `literal` 'quoted'"
    let result = try run("/usr/bin/printf", ["%s", literal], in: fixture.root, root: fixture.root)
    #expect(result.status == 0)
    #expect(result.output == literal)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("should-not-exist").path))
  }

  @Test
  func `preserves exit status and reports signals like Process`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    #expect(try run("/usr/bin/true", [], in: fixture.root, root: fixture.root).status == 0)
    #expect(try run("/usr/bin/false", [], in: fixture.root, root: fixture.root).status == 1)
    #expect(
      try run("/bin/sh", ["-c", "exit 7"], in: fixture.root, root: fixture.root).status == 7)
    let killed = try run(
      "/bin/sh", ["-c", "kill -TERM $$"], in: fixture.root, root: fixture.root)
    #expect(killed.status == SIGTERM)
  }

  @Test
  func `gives the child exactly the requested environment`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let result = try run(
      "/usr/bin/env", [], in: fixture.root, environment: ["B": "two words", "A": "1"],
      root: fixture.root)
    #expect(result.status == 0)
    #expect(Set(result.output.split(separator: "\n").map(String.init)) == ["A=1", "B=two words"])
  }

  @Test
  func `starts in the requested directory`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let directory = fixture.root.appendingPathComponent("work dir")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let result = try run("/bin/pwd", ["-P"], in: directory, root: fixture.root)
    let expected = String(cString: realpath(directory.path, nil))
    #expect(result.output.trimmingCharacters(in: .newlines) == expected)
  }

  @Test
  func `routes standard output and error to the log and closes standard input`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let result = try run(
      "/bin/sh", ["-c", "echo out; echo err >&2; cat; echo eof"], in: fixture.root,
      root: fixture.root)
    #expect(result.status == 0)
    #expect(result.output == "out\nerr\neof\n")
  }

  @Test
  func `does not leak the launcher's descriptors`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let extra = open("/dev/null", O_RDONLY)
    defer { close(extra) }
    // Descriptor numbers 3 and up must not be open in the child.
    let script =
      "for fd in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do "
      + "if [ -e /dev/fd/$fd ]; then echo open$fd; fi; done"
    let result = try run("/bin/sh", ["-c", script], in: fixture.root, root: fixture.root)
    #expect(!result.output.contains("open\(extra)"))
  }

  @Test
  func `reports a missing executable without crashing`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    #expect(throws: LauncherError.self) {
      try run("/nonexistent/program", [], in: fixture.root, root: fixture.root)
    }
  }

  @Test
  func `reports a missing working directory without crashing`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    #expect(throws: LauncherError.self) {
      try run(
        "/usr/bin/true", [], in: fixture.root.appendingPathComponent("absent"),
        root: fixture.root)
    }
  }

  @Test
  func `terminate stops a running child`() throws {
    let process = try SpawnCommand(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
      directory: FileManager.default.temporaryDirectory, environment: [:]
    ).start(output: .nullDevice)
    process.terminate()
    #expect(process.wait() == SIGTERM)
  }
}

struct FourKilobytePageRequestTests {
  @Test
  func `the attribute is not requested unless the profile asks for it`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let requests = Requests()
    let support = FourKilobytePageSupport(isAvailable: true) { _ in
      requests.record()
      return 0
    }
    let result = try run(
      "/usr/bin/true", [], in: fixture.root, fourKilobyte: false, support: support,
      root: fixture.root)
    #expect(result.status == 0)
    #expect(requests.applied == 0)
  }

  @Test
  func `the attribute is applied once when requested and available`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let requests = Requests()
    let support = FourKilobytePageSupport(isAvailable: true) { _ in
      requests.record()
      return 0
    }
    // The fake sets nothing, so the child is an ordinary 16 KiB process.
    let result = try run(
      "/usr/bin/true", [], in: fixture.root, fourKilobyte: true, support: support,
      root: fixture.root)
    #expect(result.status == 0)
    #expect(requests.applied == 1)
  }

  @Test
  func `an unsupported system reports unsupported and starts nothing`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let requests = Requests()
    let marker = fixture.root.appendingPathComponent("started")
    let support = FourKilobytePageSupport(isAvailable: false) { _ in
      requests.record()
      return 0
    }
    do {
      _ = try run(
        "/usr/bin/touch", [marker.path], in: fixture.root, fourKilobyte: true, support: support,
        root: fixture.root)
      Issue.record("A 4 KiB request on an unsupported system must fail")
    } catch {
      #expect((error as? LauncherError)?.errorDescription?.contains("unsupported") == true)
    }
    #expect(requests.applied == 0)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test
  func `a failing attribute call is reported with its reason`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let support = FourKilobytePageSupport(isAvailable: true) { _ in EPERM }
    do {
      _ = try run(
        "/usr/bin/true", [], in: fixture.root, fourKilobyte: true, support: support,
        root: fixture.root)
      Issue.record("A rejected attribute must fail the launch")
    } catch {
      #expect((error as? LauncherError)?.errorDescription?.contains("4 KiB") == true)
    }
  }

  @Test
  func `the system implementation is available exactly on macOS 26 and later`() {
    let expected = ProcessInfo.processInfo.isOperatingSystemAtLeast(
      OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    #expect(FourKilobytePageSupport.system.isAvailable == expected)
  }

  @Test
  func `the system implementation sets the attribute without spawning`() throws {
    guard FourKilobytePageSupport.system.isAvailable else { return }
    var attributes: posix_spawnattr_t? = nil
    #expect(posix_spawnattr_init(&attributes) == 0)
    defer { posix_spawnattr_destroy(&attributes) }
    #expect(FourKilobytePageSupport.system.apply(to: &attributes) == 0)
  }

  @Test
  func `an unavailable implementation refuses to apply`() {
    var attributes: posix_spawnattr_t? = nil
    #expect(posix_spawnattr_init(&attributes) == 0)
    defer { posix_spawnattr_destroy(&attributes) }
    let support = FourKilobytePageSupport(isAvailable: false) { _ in 0 }
    #expect(support.apply(to: &attributes) == ENOTSUP)
  }
}

struct SpawnProfileTests {
  private func resources(marker: String?) throws -> (URL, InstallerFixture) {
    let fixture = try InstallerFixture()
    if let marker {
      try Data(marker.utf8).write(
        to: fixture.root.appendingPathComponent("runtime-profile.json"))
    }
    return (fixture.root, fixture)
  }

  @Test
  func `a bundle without a marker keeps the Rosetta launch path`() throws {
    let (root, fixture) = try resources(marker: nil)
    defer { fixture.remove() }
    let profile = try SpawnProfile.load(from: root)
    #expect(profile == .foundation)
    #expect(profile.needsRosetta)
    #expect(!profile.requestsFourKilobytePages)
  }

  @Test
  func `the arm64 marker selects posix_spawn with 4 KiB pages by default`() throws {
    let (root, fixture) = try resources(marker: #"{"profile":"arm64-wow64"}"#)
    defer { fixture.remove() }
    let profile = try SpawnProfile.load(from: root)
    #expect(profile == .arm64Wow64(fourKilobytePages: true))
    #expect(!profile.needsRosetta)
  }

  @Test
  func `the marker can decline 4 KiB pages`() throws {
    let (root, fixture) = try resources(
      marker: #"{"profile":"arm64-wow64","fourKilobytePages":false}"#)
    defer { fixture.remove() }
    #expect(try SpawnProfile.load(from: root) == .arm64Wow64(fourKilobytePages: false))
  }

  @Test
  func `an unknown or malformed marker is rejected`() throws {
    for marker in [#"{"profile":"other"}"#, "not json", #"{"fourKilobytePages":true}"#] {
      let (root, fixture) = try resources(marker: marker)
      defer { fixture.remove() }
      #expect(throws: LauncherError.self) { try SpawnProfile.load(from: root) }
    }
  }

  @Test
  func `the arm64 profile routes ProcessCommand run through posix_spawn`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let log = fixture.root.appendingPathComponent("output")
    try Data().write(to: log)
    let handle = try FileHandle(forWritingTo: log)
    // 4 KiB pages are declined so that this test does not depend on the macOS version.
    let status = try ProcessCommand(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo $0 $1", "a b"],
      directory: fixture.root, environment: [:], profile: .arm64Wow64(fourKilobytePages: false)
    ).run(output: handle)
    try handle.close()
    #expect(status == 0)
    #expect(try String(contentsOf: log, encoding: .utf8) == "a b\n")
  }

  @Test
  func `a Process cannot be started under the arm64 profile`() {
    #expect(throws: LauncherError.self) {
      try ProcessCommand(
        executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
        directory: FileManager.default.temporaryDirectory, environment: [:],
        profile: .arm64Wow64(fourKilobytePages: false)
      ).start(output: .nullDevice)
    }
  }
}
