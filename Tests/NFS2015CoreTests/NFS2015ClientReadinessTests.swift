import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

/// A synthetic EA client log in the shape the real client writes: a start line, then telemetry
/// events. No account name, token or identifier is in it.
struct SyntheticClientLog {
  let url: URL

  init(in prefix: SyntheticPrefix) throws {
    url = prefix.driveC.appendingPathComponent("ProgramData/EA Desktop/Logs/EADesktop.log")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  }

  private static func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  /// One line with the leading line number and tab the real log carries.
  static func line(_ date: Date, _ text: String) -> String {
    "     1\t[\(stamp(date))]\tPID:    32\tTID:    36\tINFO    \t(eax::services::x)\t\(text)\n"
  }

  func append(_ lines: String) throws {
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(lines.utf8))
    } else {
      try Data(lines.utf8).write(to: url)
    }
  }

  func start(at date: Date) throws {
    try append(Self.line(date, "(eax::apps::utils::logAppInfo)\t[STARTUP] app[EADesktop]"))
  }

  /// An event whose `authenticated` flag is whatever is given, as EA stamps it on every event.
  func event(_ name: String, at date: Date, authenticated: Bool = false) throws {
    try append(
      Self.line(
        date,
        "Telemetry Event [\(name)]: [{\"appUptime\":4.5,\"authenticated\":\(authenticated)}]"))
  }

  func signIn(from date: Date) throws {
    try event("user.lgin.ckld", at: date, authenticated: true)
    try event("login", at: date.addingTimeInterval(1), authenticated: true)
    try event("client.boot.ready", at: date.addingTimeInterval(5))
  }
}

struct NFS2015ClientReadinessTests {
  private func probe(_ log: SyntheticClientLog) -> ClientLogProbe {
    ClientLogProbe(
      log: log.url, startMarker: "[STARTUP]", readyEvents: ["login", "client.boot.ready"])
  }

  @Test
  func `a client that started, signed in and booted is ready`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let log = try SyntheticClientLog(in: prefix)
    let started = Date()
    try log.start(at: started.addingTimeInterval(7))
    try log.signIn(from: started.addingTimeInterval(9))
    #expect(probe(log).phase(since: started) == .ready)
    #expect(probe(log).phase(since: nil) == .ready)
  }

  @Test
  func `a client that started but is not signed in is signed out, not ready`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let log = try SyntheticClientLog(in: prefix)
    let started = Date()
    try log.start(at: started.addingTimeInterval(7))
    try log.event("app.strt.ready", at: started.addingTimeInterval(9))
    try log.event("client.boot.ready", at: started.addingTimeInterval(10))
    #expect(probe(log).phase(since: started) == .signedOut)
  }

  @Test
  func `the authenticated flag EA stamps on events is not the evidence`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let log = try SyntheticClientLog(in: prefix)
    let started = Date()
    try log.start(at: started.addingTimeInterval(7))
    for index in 0..<5 {
      try log.event(
        "boot_start", at: started.addingTimeInterval(8 + Double(index)), authenticated: true)
    }
    #expect(probe(log).phase(since: started) == .signedOut)
  }

  /// The earlier run in the same log was signed in; the run that was just started has not
  /// written anything yet, or has not signed in yet. Neither is ready.
  @Test
  func `an earlier signed in run does not make a client that has just started ready`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let log = try SyntheticClientLog(in: prefix)
    let earlier = Date().addingTimeInterval(-600)
    try log.start(at: earlier)
    try log.signIn(from: earlier.addingTimeInterval(2))
    let started = Date()
    #expect(probe(log).phase(since: started) == .notStarted)
    try log.start(at: started.addingTimeInterval(6))
    #expect(probe(log).phase(since: started) == .signedOut)
    try log.signIn(from: started.addingTimeInterval(8))
    #expect(probe(log).phase(since: started) == .ready)
  }

  /// The case that failed: the EA logs and `cef.log` exist and are stale or updating, and the
  /// client's helpers are not children of the client. Only the client's own events count.
  @Test
  func `stale helper logs and unrelated files do not decide readiness`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    try prefix.file("ProgramData/EA Desktop/Logs/cef.log", contents: "old browser log")
    try prefix.file("ProgramData/EA Desktop/Logs/EADesktopVerbose.log", contents: "[STARTUP]")
    try prefix.directory("users/crossover/AppData/Local/Electronic Arts/EA Desktop/Logs")
    let install = try #require(
      try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan).install)
    let plan = try NFS2015LaunchPlan.make(install: install, plan: SyntheticPrefix.plan)
    #expect(plan.readiness.log.lastPathComponent == "EADesktop.log")
    #expect(plan.readiness.phase(since: Date()) == .notStarted)
    let log = try SyntheticClientLog(in: prefix)
    try log.start(at: Date().addingTimeInterval(3))
    try log.signIn(from: Date().addingTimeInterval(4))
    #expect(plan.readiness.phase(since: Date().addingTimeInterval(-5)) == .ready)
  }

  /// The regression for the real failure: one probe polled again and again must see the file
  /// change. Reading the modification time through a reused URL returned its first value forever.
  @Test
  func `polling the same probe sees the log grow`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let log = try SyntheticClientLog(in: prefix)
    let started = Date()
    let sut = probe(log)
    #expect(sut.phase(since: started) == .notStarted)
    try log.start(at: started.addingTimeInterval(1))
    #expect(sut.phase(since: started) == .signedOut)
    try log.signIn(from: started.addingTimeInterval(2))
    #expect(sut.phase(since: started) == .ready)
  }

  @Test
  func `an absent or empty log is not started`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let log = try SyntheticClientLog(in: prefix)
    #expect(probe(log).phase(since: Date()) == .notStarted)
    try Data().write(to: log.url)
    #expect(probe(log).phase(since: nil) == .notStarted)
  }

  @Test
  func `a client that was already running is ready from its own latest run`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let log = try SyntheticClientLog(in: prefix)
    let first = Date().addingTimeInterval(-3_600)
    try log.start(at: first)
    try log.signIn(from: first.addingTimeInterval(2))
    // A later run that never signed in must not borrow the earlier run's events.
    try log.start(at: Date().addingTimeInterval(-60))
    #expect(probe(log).phase(since: nil) == .signedOut)
    try log.signIn(from: Date().addingTimeInterval(-50))
    #expect(probe(log).phase(since: nil) == .ready)
  }

  @Test
  func `a run longer than the read window is still recognised when reused`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let log = try SyntheticClientLog(in: prefix)
    let first = Date().addingTimeInterval(-36_000)
    try log.start(at: first)
    try log.signIn(from: first.addingTimeInterval(2))
    let filler = SyntheticClientLog.line(Date(), "(eax::x)\tfiller line of the client's log")
    let block = String(repeating: filler, count: 2_000)
    let rounds = (ClientLogProbe.window / block.utf8.count) + 2
    for _ in 0..<rounds { try log.append(block) }
    try log.event("login", at: Date(), authenticated: true)
    try log.event("client.boot.ready", at: Date())
    #expect(probe(log).phase(since: nil) == .ready)
    // A client just started must show its own start line, which has long since left the window.
    #expect(probe(log).phase(since: Date()) == .notStarted)
  }

  /// The real client log ends every line with CRLF, and begins with a blank line.
  @Test
  func `reads the latest start of a log with Windows line endings`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let log = try SyntheticClientLog(in: prefix)
    let earlier = Date().addingTimeInterval(-600)
    let started = Date()
    var text = "\r\n"
    for (date, line) in [
      (earlier, "(eax::x)\t[STARTUP] app[EADesktop]"),
      (earlier.addingTimeInterval(2), "Telemetry Event [login]: [{}]"),
      (earlier.addingTimeInterval(7), "Telemetry Event [client.boot.ready]: [{}]"),
      (started.addingTimeInterval(6), "(eax::x)\t[STARTUP] app[EADesktop]"),
    ] {
      text += SyntheticClientLog.line(date, line).replacingOccurrences(of: "\n", with: "\r\n")
    }
    try log.append(text)
    #expect(probe(log).phase(since: started) == .signedOut)
    #expect(probe(log).phase(since: nil) == .signedOut)
    try log.append(
      SyntheticClientLog.line(started.addingTimeInterval(8), "Telemetry Event [login]: [{}]")
        .replacingOccurrences(of: "\n", with: "\r\n")
        + SyntheticClientLog.line(
          started.addingTimeInterval(12), "Telemetry Event [client.boot.ready]: [{}]"
        ).replacingOccurrences(of: "\n", with: "\r\n"))
    #expect(probe(log).phase(since: started) == .ready)
  }

  @Test
  func `reads the start stamp whether or not it has fractional seconds`() throws {
    let text = "     1\t[2026-10-02T13:25:56Z]\tPID: 32\t[STARTUP]\n"
    let index = try #require(text.range(of: "[STARTUP]")).lowerBound
    let stamp = try #require(ClientLogProbe.timestamp(of: text, at: index))
    #expect(stamp == ISO8601DateFormatter().date(from: "2026-10-02T13:25:56Z"))
    let bare = "no stamp [STARTUP]"
    let bareIndex = try #require(bare.range(of: "[STARTUP]")).lowerBound
    #expect(ClientLogProbe.timestamp(of: bare, at: bareIndex) == nil)
  }
}

struct NFS2015ClientWaitTests {
  @Test
  func `returns the moment the client reports ready`() throws {
    var polls = 0
    let result = try ClientWait(deadline: 30).run(
      phase: {
        polls += 1
        return polls < 4 ? .signedOut : .ready
      }, isRunning: { true }, wait: { _ in })
    #expect(result == .ready(seconds: 3))
  }

  /// A healthy client the wait ran out on is reported, never an error and never stopped: the
  /// caller gets a result it can leave running, with what the player has to do.
  @Test
  func `running out of time with the client alive is a result, not a failure`() throws {
    var slept = 0
    let result = try ClientWait(deadline: 4).run(
      phase: { .signedOut }, isRunning: { true }, wait: { slept += $0 })
    #expect(result == .timedOut(.signedOut))
    #expect(slept == 5)
    let notice = try #require(result.notice)
    #expect(notice.contains("not signed in"))
    #expect(notice.contains("Play again"))
  }

  @Test
  func `tells a client that never reported its start from one that is signed out`() throws {
    let silent = try ClientWait(deadline: 1).run(
      phase: { .notStarted }, isRunning: { true }, wait: { _ in })
    #expect(silent == .timedOut(.notStarted))
    let signedOut = try ClientWait(deadline: 1).run(
      phase: { .signedOut }, isRunning: { true }, wait: { _ in })
    #expect(silent.notice != signedOut.notice)
    #expect(silent.notice?.contains("Leave it open") == true)
    #expect(ClientWaitResult.ready(seconds: 1).notice == nil)
  }

  @Test
  func `a client that exits before it is ready is the one failure`() throws {
    var alive = true
    let error = #expect(throws: LauncherError.self) {
      try ClientWait(deadline: 30).run(
        phase: { .signedOut }, isRunning: { alive }, wait: { _ in alive = false })
    }
    #expect(error?.localizedDescription.contains("stopped before it was ready") == true)
  }

  @Test
  func `a client that is ready on the last second still counts`() throws {
    var polls = 0
    let result = try ClientWait(deadline: 3).run(
      phase: {
        polls += 1
        return polls == 4 ? .ready : .notStarted
      }, isRunning: { true }, wait: { _ in })
    #expect(result == .ready(seconds: 3))
  }

  @Test
  func `an interrupted wait is reported`() throws {
    struct Interrupted: Error {}
    #expect(throws: LauncherError.self) {
      try ClientWait(deadline: 3).run(
        phase: { .signedOut }, isRunning: { true }, wait: { _ in throw Interrupted() })
    }
  }
}

struct NFS2015ReuseTests {
  @Test
  func `recognises the program a process is running by its command line`() {
    let me = ProcessInfo.processInfo.processIdentifier
    #expect(ProcessFamily.commandLine(of: me) != nil)
    #expect(ProcessFamily.runs(pid: me, program: ProcessInfo.processInfo.processName))
    #expect(!ProcessFamily.runs(pid: me, program: "EADesktop.exe"))
    #expect(ProcessFamily.commandLine(of: 2_147_000_000) == nil)
  }

  @Test
  func `the starter state carries the notice and still reads a state written without one`() throws {
    var snapshot = NFS2015Snapshot(clientVersion: "13.796.0.6309", ownsWindowsFolder: true)
    snapshot.notice = "The EA app is open but not signed in."
    let data = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(NFS2015Snapshot.self, from: data).notice == snapshot.notice)
    // The state file an earlier build wrote has no notice.
    let earlier = Data(
      #"{"clientVersion":"13.796.0.6309","hasOptionsFile":false,"ownsWindowsFolder":true,"installedAt":"/x","settings":{"values":{}}}"#
        .utf8)
    #expect(try JSONDecoder().decode(NFS2015Snapshot.self, from: earlier).notice == nil)
  }
}
