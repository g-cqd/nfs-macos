import Foundation
import LauncherCore
import NFS2015Core
import Testing

@testable import NFS2015Session

struct NFS2015CrashMonitorTests {
  static let fault =
    "wine: Unhandled page fault on read access to 0000000000000000 at address 0000000000000000 (thread 057c), starting debugger...\n"
  static let secret = "info:  authCode=A1b2C3d4E5f6G7h8I9j0K1l2M3n4 sessionId=77\n"

  private struct Fixture {
    let root: URL
    let log: URL
    let reports: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      reports = root.appendingPathComponent("Logs")
      try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
      log = root.appendingPathComponent("session-1.log")
      try Data().write(to: log)
    }

    func append(_ text: String) throws {
      let handle = try FileHandle(forWritingTo: log)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
      try handle.close()
    }

    func reportFiles() -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: reports.path)) ?? [])
        .filter { $0.hasPrefix("crash-report-") }.sorted()
    }

    func remove() {
      chmod(reports.path, 0o755)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private struct FixedHost: NFS2015HostQuerying {
    func host() -> NFS2015HostFacts {
      NFS2015HostFacts(
        model: "Mac0,0", chip: "Apple M0", memoryBytes: 8_589_934_592, osVersion: "27.0",
        cpuCount: 4)
    }
    func load() -> NFS2015LoadSample {
      NFS2015LoadSample(loadAverages: [1, 1, 1], swapUsed: nil, swapTotal: nil)
    }
  }

  private func context() -> NFS2015CrashContext {
    NFS2015CrashContext(
      pins: NFS2015BuildPins(), host: FixedHost().host(), display: nil,
      displayPlan: NFS2015DisplaySafety.plan(
        facts: nil, hasOptionsFile: nil, preference: .standard),
      seed: nil, metalFX: .off, diagnostics: .standard, diagnosticLog: false,
      settings: NFS2015Settings(), tuning: [:], experiment: NFS2015ExperimentOverrides())
  }

  private func monitor(_ fixture: Fixture, debugFiles: @escaping @Sendable () -> [URL] = { [] })
    -> NFS2015CrashMonitor
  {
    NFS2015CrashMonitor(
      log: fixture.log, store: NFS2015CrashReportStore(folder: fixture.reports), context: context(),
      host: FixedHost(), debugFiles: debugFiles, now: { Date(timeIntervalSince1970: 1_791_000_000) }
    )
  }

  @Test
  func `writes nothing while the log shows no fault`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sut = monitor(fixture)
    try fixture.append("compatdb: NFS16.exe [x86_64]\ninfo:  Setting display mode: 1920x1200@60\n")
    #expect(sut.scan() == nil && sut.notice == nil)
    #expect(fixture.reportFiles().isEmpty)
  }

  @Test
  func `writes a report when a fault appears, and tells the starter where it is`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sut = monitor(fixture)
    try fixture.append("compatdb: NFS16.exe [x86_64]\n" + Self.fault)
    let notice = try #require(sut.scan())
    #expect(fixture.reportFiles() == ["crash-report-20261003T040000Z.txt"])
    #expect(notice.path.hasSuffix("/Logs/crash-report-20261003T040000Z.txt"))
    #expect(
      notice.headline
        == "1 fault in 1 game launch; first at 0x0, outside nfs16 (0x140000000-0x1488F2000)")
    #expect(sut.notice == notice)
    let text = try String(contentsOfFile: notice.path, encoding: .utf8)
    #expect(text.contains("call or jump through a null function pointer"))
  }

  @Test
  func `reports each fault once, and again only when new ones appear`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sut = monitor(fixture)
    try fixture.append(Self.fault)
    #expect(sut.scan() != nil)
    #expect(sut.scan() == nil)
    try fixture.append("info:  more output\n")
    #expect(sut.scan() == nil)
    try fixture.append(Self.fault)
    let second = try #require(sut.scan())
    #expect(fixture.reportFiles().count == 2)
    #expect(second.headline.hasPrefix("2 faults"))
  }

  @Test
  func `writes at most five reports in a session`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sut = monitor(fixture)
    for _ in 0..<(NFS2015CrashMonitor.reportLimit + 3) {
      try fixture.append(Self.fault)
      sut.scan()
    }
    #expect(fixture.reportFiles().count == NFS2015CrashMonitor.reportLimit)
  }

  @Test
  func `reads a fault line that arrives in two pieces`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sut = monitor(fixture)
    let cut = Self.fault.index(Self.fault.startIndex, offsetBy: 40)
    try fixture.append(String(Self.fault[..<cut]))
    #expect(sut.scan() == nil)
    try fixture.append(String(Self.fault[cut...]))
    #expect(sut.scan() != nil)
  }

  @Test
  func `keeps credentials out of the report`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sut = monitor(fixture)
    try fixture.append(Self.secret + Self.fault)
    let notice = try #require(sut.scan())
    let text = try String(contentsOfFile: notice.path, encoding: .utf8)
    for secret in ["A1b2C3d4E5f6G7h8I9j0K1l2M3n4", "sessionId", "authCode"] {
      #expect(!text.contains(secret), "\(secret)")
    }
  }

  @Test
  func `adds the exception trace of a diagnostic launch from its debug file`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let debug = fixture.root.appendingPathComponent("wine-debug-X-001.log")
    try Data("0001:trace:seh:dispatch_exception code=c0000005\n".utf8).write(to: debug)
    let sut = monitor(fixture, debugFiles: { [debug] })
    try fixture.append(Self.fault)
    let notice = try #require(sut.scan())
    #expect(
      try String(contentsOfFile: notice.path, encoding: .utf8).contains(
        "dispatch_exception code=c0000005"))
  }

  @Test
  func `survives a folder it cannot write, and does not try the same faults again`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sut = monitor(fixture)
    chmod(fixture.reports.path, 0o500)
    try fixture.append(Self.fault)
    #expect(sut.scan() == nil && sut.notice == nil)
    chmod(fixture.reports.path, 0o755)
    // The fault was counted as reported, so the folder being fixed does not write it late.
    #expect(sut.scan() == nil)
    #expect(fixture.reportFiles().isEmpty)
    try fixture.append(Self.fault)
    #expect(sut.scan() != nil)
    #expect(fixture.reportFiles().count == 1)
  }

  @Test
  func `stopping without starting returns at once, and stopping makes a last scan`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sut = monitor(fixture)
    try fixture.append(Self.fault)
    let notice = sut.stop()
    #expect(notice != nil && fixture.reportFiles().count == 1)
  }

  @Test
  func `the background scan catches a fault without being asked`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sut = monitor(fixture)
    sut.start()
    try fixture.append(Self.fault)
    // stop() ends the thread and makes the last scan itself, so the report is there either way.
    let notice = sut.stop()
    #expect(notice != nil && fixture.reportFiles().count == 1)
  }
}
