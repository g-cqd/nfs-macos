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
