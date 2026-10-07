import Foundation
import LauncherCore
import NFS2015Core
import Synchronization

/// Watches the session log while the game runs and writes a crash report when it shows a fault.
///
/// The game is started by the EA app, which keeps running after the game dies, so the helper
/// does not see the game's exit. What it can see is the log: Wine prints an `Unhandled page
/// fault` line when the game dies of one. The monitor reads the log as it grows, once every
/// `interval` seconds, and writes a report each time faults appear that an earlier report did not
/// hold, at most `reportLimit` times in a session. A report problem is printed to the log and
/// never stops the game.
final class NFS2015CrashMonitor: Sendable {
  static let reportLimit = 5
  static let interval: TimeInterval = 2

  private struct State {
    var digest = NFS2015LogDigest()
    var offset: UInt64 = 0
    var reportedFaults = 0
    var reports = 0
    var notice: NFS2015CrashNotice?
    var started = false
    var stopped = false
    var finished = false
  }

  private let log: URL
  private let store: NFS2015CrashReportStore
  private let context: NFS2015CrashContext
  private let host: any NFS2015HostQuerying
  private let debugFiles: @Sendable () -> [URL]
  private let now: @Sendable () -> Date
  private let state = Mutex(State())
  private let condition = NSCondition()

  init(
    log: URL, store: NFS2015CrashReportStore, context: NFS2015CrashContext,
    host: any NFS2015HostQuerying, debugFiles: @escaping @Sendable () -> [URL] = { [] },
    now: @escaping @Sendable () -> Date = { Date() }, startAtEnd: Bool = false
  ) {
    self.log = log
    self.store = store
    self.context = context
    self.host = host
    self.debugFiles = debugFiles
    self.now = now
    // A log that already holds an earlier session's history is watched from where it ends now,
    // so a fault that was reported before is not reported again.
    if startAtEnd,
      let size = try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64
    {
      state.withLock { $0.offset = size }
    }
  }

  /// The newest report this monitor wrote.
  var notice: NFS2015CrashNotice? { state.withLock { $0.notice } }

  /// Reads what the log gained since the last scan and writes a report if it holds new faults.
  /// - Returns: The report written, if any.
  @discardableResult
  func scan() -> NFS2015CrashNotice? {
    let written: NFS2015CrashNotice? = state.withLock { state in
      guard let piece = NFS2015LogFile.read(log, from: state.offset) else { return nil }
      if piece.next < state.offset { state.digest = NFS2015LogDigest() }
      state.offset = piece.next
      state.digest.feed(piece.text)
      let faults = state.digest.faults.count
      guard faults > state.reportedFaults, state.reports < Self.reportLimit else { return nil }
      var digest = state.digest
      if let newest = debugFiles().last, let tail = NFS2015LogFile.tail(newest, bytes: 262_144) {
        digest.setTrace(fromText: tail)
      }
      guard
        let report = NFS2015CrashReport(
          digest: digest, context: context, load: host.load(), now: now())
      else { return nil }
      do {
        let url = try store.write(report, stamp: NFS2015DiagnosticLog.stamp(now()))
        state.reportedFaults = faults
        state.reports += 1
        let notice = NFS2015CrashNotice(path: url.path, headline: report.headline)
        state.notice = notice
        return notice
      } catch {
        // Counted, so a folder that cannot be written does not make every scan try again.
        state.reportedFaults = faults
        state.reports += 1
        print("Crash report not written: \(error.localizedDescription)")
        return nil
      }
    }
    if let written { print(written.sentence) }
    return written
  }

  /// Starts scanning in the background until `stop()`.
  func start() {
    state.withLock { $0.started = true }
    let thread = Thread { [self] in
      while true {
        scan()
        condition.lock()
        let stopping = state.withLock { $0.stopped }
        if !stopping { _ = condition.wait(until: Date(timeIntervalSinceNow: Self.interval)) }
        let done = state.withLock { $0.stopped }
        condition.unlock()
        if done { break }
      }
      state.withLock { $0.finished = true }
      condition.lock()
      condition.broadcast()
      condition.unlock()
    }
    thread.name = "NFS2015 crash monitor"
    thread.start()
  }

  /// Stops the background scan, makes a last scan and returns the newest report's notice.
  @discardableResult
  func stop() -> NFS2015CrashNotice? {
    condition.lock()
    state.withLock { $0.stopped = true }
    condition.broadcast()
    condition.unlock()
    let deadline = Date(timeIntervalSinceNow: 5)
    condition.lock()
    while state.withLock({ $0.started && !$0.finished }), condition.wait(until: deadline) {}
    condition.unlock()
    scan()
    return notice
  }
}
