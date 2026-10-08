import Foundation
import LauncherCore
import NFS2015Core
import Testing

@testable import NFS2015Session

/// The session helper's wiring of the crash monitor and the diagnostic log, with no Wine and no
/// game: nothing here starts a process.
struct NFS2015SessionWatchTests {
  private struct Fixture {
    let root: URL
    let paths: AppPaths
    let log: FileHandle
    let store: NFS2015DiagnosticsStore

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let support = root.appendingPathComponent("Support")
      try FileManager.default.createDirectory(
        at: support.appendingPathComponent("Logs"), withIntermediateDirectories: true)
      paths = try AppPaths(
        bundle: root.appendingPathComponent("Synthetic.app"), support: support, game: .nfs2015)
      let logURL = support.appendingPathComponent("Logs/session-1.log")
      try Data().write(to: logURL)
      log = try FileHandle(forWritingTo: logURL)
      store = NFS2015DiagnosticsStore(support: support)
    }

    var session: NFS2015Session { NFS2015Session(paths: paths, output: log) }

    func remove() {
      try? log.close()
      chmod(paths.support.path, 0o755)
      try? FileManager.default.removeItem(at: root)
    }

    func runtime(_ channels: String) -> WineRuntime {
      WineRuntime(paths: paths, output: log, debugChannels: channels)
    }

    func context() throws -> NFS2015CrashContext {
      try session.crashContext(
        manifest: nil, facts: nil,
        plan: NFS2015DisplaySafety.plan(facts: nil, hasOptionsFile: nil, preference: .standard),
        seeded: nil, metalFX: NFS2015MetalFXState(), diagnostics: .standard,
        tuning: RuntimeTuning(), experiment: NFS2015ExperimentOverrides(),
        sidecar: NFS2015SidecarChoice(
          preference: .standard, experiment: NFS2015ExperimentOverrides()),
        settings: NFS2015Settings())
    }
  }

  private let armed = NFS2015DiagnosticsPreference(diagnosticLoggingNextLaunch: true)

  private func state(_ preference: NFS2015DiagnosticsPreference) -> NFS2015DiagnosticsState {
    NFS2015DiagnosticsState(preference: preference)
  }

  private func channels(of watch: NFS2015PlayWatch, _ fixture: Fixture) throws -> String? {
    try watch.runtime.environment(prefix: fixture.paths.prefix)["WINEDEBUG"]
  }

  @Test
  func `a normal Play is silent, has a monitor, and writes no debug file`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let watch = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: false, diagnostics: state(.standard), store: fixture.store,
      context: try fixture.context())
    #expect(try channels(of: watch, fixture) == "-all")
    #expect(watch.capture == nil && watch.monitor != nil)
    #expect(watch.finish() == nil)
  }

  @Test
  func `an armed diagnostic log is used once: the channels are set and the switch is cleared`()
    throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.store.save(armed)
    let watch = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: false, diagnostics: state(armed), store: fixture.store,
      context: try fixture.context())
    #expect(try channels(of: watch, fixture) == NFS2015DiagnosticLog.channels)
    #expect(watch.capture != nil)
    #expect(!fixture.store.load().preference.diagnosticLoggingNextLaunch)
    _ = watch.finish()
    // The next Play, with the switch cleared, is silent again.
    let next = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: false, diagnostics: state(fixture.store.load().preference),
      store: fixture.store, context: try fixture.context())
    #expect(try channels(of: next, fixture) == "-all" && next.capture == nil)
    _ = next.finish()
  }

  @Test
  func `a running EA app is adopted: the log cannot apply to it, and stays armed`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.store.save(armed)
    let watch = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: true, diagnostics: state(armed), store: fixture.store,
      context: try fixture.context())
    #expect(try channels(of: watch, fixture) == "-all" && watch.capture == nil)
    #expect(fixture.store.load().preference.diagnosticLoggingNextLaunch)
    _ = watch.finish()
  }

  @Test
  func `if the switch cannot be cleared the log does not run`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.store.save(armed)
    chmod(fixture.paths.support.path, 0o500)
    let watch = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: false, diagnostics: state(armed), store: fixture.store,
      context: try fixture.context())
    #expect(try channels(of: watch, fixture) == "-all" && watch.capture == nil)
    _ = watch.finish()
  }

  @Test
  func `without a log file as standard output there is no monitor and Play still starts`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let session = NFS2015Session(paths: fixture.paths, output: pipe.fileHandleForWriting)
    let watch = session.startWatch(
      runtime: fixture.runtime, adopted: false, diagnostics: state(.standard), store: fixture.store,
      context: try fixture.context())
    #expect(watch.monitor == nil && watch.finish() == nil)
  }

  @Test
  func `the monitor of a Play finds a fault in the log the helper writes to`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let watch = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: false, diagnostics: state(.standard), store: fixture.store,
      context: try fixture.context())
    try fixture.log.write(contentsOf: Data(NFS2015CrashMonitorTests.fault.utf8))
    let notice = try #require(watch.finish())
    #expect(notice.path.contains("/Support/Logs/crash-report-"))
    #expect(FileManager.default.fileExists(atPath: notice.path))
  }

  // MARK: A reused EA app

  @Test
  func
    `a diagnostic Play leaves no record, because the EA app writes to a pipe and not to the log`()
    throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    NFS2015ClientOutputLog.record(
      fixture.paths.support.appendingPathComponent("Logs/session-1.log"), in: fixture.paths.support)
    _ = try fixture.store.save(armed)
    let watch = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: false, diagnostics: state(armed), store: fixture.store,
      context: try fixture.context())
    #expect(watch.capture != nil)
    #expect(NFS2015ClientOutputLog.recorded(in: fixture.paths.support) == nil)
    _ = watch.finish()
  }

  @Test
  func `the helper that starts the EA app records its log for a later Play`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let watch = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: false, diagnostics: state(.standard), store: fixture.store,
      context: try fixture.context())
    _ = watch.finish()
    let recorded = try #require(NFS2015ClientOutputLog.recorded(in: fixture.paths.support))
    #expect(recorded.lastPathComponent == "session-1.log")
  }

  @Test
  func `a Play that reuses the EA app watches the log that app writes to, from where it ends now`()
    throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    // The earlier Play's log already holds a fault that was reported then.
    let earlier = fixture.paths.support.appendingPathComponent("Logs/session-0.log")
    try Data(NFS2015CrashMonitorTests.fault.utf8).write(to: earlier)
    NFS2015ClientOutputLog.record(earlier, in: fixture.paths.support)
    let watch = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: true, diagnostics: state(.standard), store: fixture.store,
      context: try fixture.context())
    // The new session's own log is not the one watched, and the old fault is not repeated.
    try fixture.log.write(contentsOf: Data(NFS2015CrashMonitorTests.fault.utf8))
    #expect(watch.finish() == nil)
    // A fault the game has since written to the reused app's log is found.
    let again = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: true, diagnostics: state(.standard), store: fixture.store,
      context: try fixture.context())
    let handle = try FileHandle(forWritingTo: earlier)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(NFS2015CrashMonitorTests.fault.utf8))
    try handle.close()
    #expect(try #require(again.finish()).headline.hasPrefix("1 fault"))
  }

  @Test
  func `a Play that reuses an EA app with no recorded log watches its own log`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let watch = fixture.session.startWatch(
      runtime: fixture.runtime, adopted: true, diagnostics: state(.standard), store: fixture.store,
      context: try fixture.context())
    try fixture.log.write(contentsOf: Data(NFS2015CrashMonitorTests.fault.utf8))
    #expect(watch.finish() != nil)
  }

  // MARK: Requests

  private func options(_ request: String) throws -> (SessionOptions, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(request.utf8).write(to: url)
    return (
      try SessionOptions(arguments: [
        "/A.app", "--support", "/tmp/p", "--configure-diagnostics", "--request", url.path,
      ]), url
    )
  }

  @Test
  func `carries out a diagnostics request and answers with the outcome and the saved choice`()
    throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let body = String(
      decoding: try JSONEncoder().encode(
        NFS2015DiagnosticsRequest(
          action: .save, preference: NFS2015DiagnosticsPreference(limitRetinaDesktop: false))),
      as: UTF8.self)
    let (request, url) = try options(body)
    defer { try? FileManager.default.removeItem(at: url) }
    let answer = fixture.session.diagnosticsState(for: request, store: fixture.store)
    #expect(answer.outcome == .saved && answer.preference.limitRetinaDesktop == false)
    #expect(fixture.store.load().preference.limitRetinaDesktop == false)
  }

  @Test
  func `carries out a sidecar request and reads the choice the next Play will use`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sidecarOptions = { (request: String) throws -> (SessionOptions, URL) in
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try Data(request.utf8).write(to: url)
      return (
        try SessionOptions(arguments: [
          "/A.app", "--support", "/tmp/p", "--configure-sidecar", "--request", url.path,
        ]), url
      )
    }
    let plain = try SessionOptions(arguments: ["/A.app", "--support", "/tmp/p", "--play"])
    #expect(fixture.session.readSidecarState(for: plain) == NFS2015SidecarState())
    let body = String(
      decoding: try JSONEncoder().encode(
        NFS2015SidecarRequest(action: .save, preference: NFS2015SidecarPreference(enabled: true))),
      as: UTF8.self)
    let (save, url) = try sidecarOptions(body)
    defer { try? FileManager.default.removeItem(at: url) }
    let saved = fixture.session.readSidecarState(for: save)
    #expect(saved.outcome == .saved && saved.preference.enabled)
    // A later Play reads the saved choice and reports no outcome of its own.
    let later = fixture.session.readSidecarState(for: plain)
    #expect(later.preference.enabled && later.outcome == nil && later.notice == nil)
    let (broken, brokenURL) = try sidecarOptions("not json")
    defer { try? FileManager.default.removeItem(at: brokenURL) }
    #expect(fixture.session.readSidecarState(for: broken).outcome?.refusal != nil)
  }

  @Test
  func `carries out a Wine experiment request and reads the choice the next Play will use`() throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    func options(_ request: String) throws -> (SessionOptions, URL) {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try Data(request.utf8).write(to: url)
      return (
        try SessionOptions(arguments: [
          "/A.app", "--support", "/tmp/p", "--configure-experiments", "--request", url.path,
        ]), url
      )
    }
    let plain = try SessionOptions(arguments: ["/A.app", "--support", "/tmp/p", "--play"])
    #expect(fixture.session.readExperimentsState(for: plain) == NFS2015WineExperimentsState())
    // A fresh support folder starts with the workaround on and no notice.
    #expect(fixture.session.readExperimentsState(for: plain).preference.rwxWxEmulation)
    #expect(fixture.session.readExperimentsState(for: plain).notice == nil)
    let body = String(
      decoding: try JSONEncoder().encode(
        NFS2015WineExperimentsRequest(
          action: .save,
          preference: NFS2015WineExperimentsPreference(flushToggle: true, tracePage: true))),
      as: UTF8.self)
    let (save, url) = try options(body)
    defer { try? FileManager.default.removeItem(at: url) }
    let saved = fixture.session.readExperimentsState(for: save)
    #expect(saved.outcome == .saved && saved.preference.flushToggle && saved.preference.tracePage)
    let later = fixture.session.readExperimentsState(for: plain)
    #expect(later.preference.flushToggle && later.outcome == nil && later.notice == nil)
    let (broken, brokenURL) = try options("not json")
    defer { try? FileManager.default.removeItem(at: brokenURL) }
    #expect(fixture.session.readExperimentsState(for: broken).outcome?.refusal != nil)
    // A saved off is respected by a later Play.
    let offBody = String(
      decoding: try JSONEncoder().encode(
        NFS2015WineExperimentsRequest(
          action: .save, preference: NFS2015WineExperimentsPreference(rwxWxEmulation: false))),
      as: UTF8.self)
    let (off, offURL) = try options(offBody)
    defer { try? FileManager.default.removeItem(at: offURL) }
    #expect(fixture.session.readExperimentsState(for: off).outcome == .saved)
    #expect(!fixture.session.readExperimentsState(for: plain).preference.rwxWxEmulation)
  }

  @Test
  func `a request that cannot be read is refused, not a failure`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (request, url) = try options("not json")
    defer { try? FileManager.default.removeItem(at: url) }
    let answer = fixture.session.diagnosticsState(for: request, store: fixture.store)
    #expect(
      answer.outcome?.refusal != nil && answer.preference == NFS2015DiagnosticsPreference.standard)
  }

  @Test
  func `any other action only reads the saved choice`() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.store.save(armed)
    let play = try SessionOptions(arguments: ["/A.app", "--support", "/tmp/p", "--play"])
    let answer = fixture.session.diagnosticsState(for: play, store: fixture.store)
    #expect(answer.outcome == nil && answer.preference == armed)
  }
}
