import Foundation

/// What a crash report needs from a session log, gathered as the log grows.
///
/// The log is Wine's standard error and the helper's own lines, written while the game runs. The
/// digest reads it in pieces (`feed`), keeps only counters and short bounded lists, and so costs
/// the same however long the session runs. It never keeps a line that is not one of the
/// diagnostic shapes of `NFS2015Redaction.isDiagnostic`.
package struct NFS2015LogDigest: Equatable, Sendable {
  static let faultLimit = 64
  static let modeLimit = 16
  static let contextLimit = 60
  static let traceLimit = 80

  /// Times the game was started: one `compatdb: NFS16.exe [` line each.
  package private(set) var launches = 0
  package private(set) var faults: [NFS2015FaultLine] = []
  /// Each `Setting display mode: WxH@R` seen, with its count, in order of first appearance.
  package private(set) var displayModes: [(mode: String, count: Int)] = []
  package private(set) var serverCrashes = 0
  /// The most recent diagnostic lines, scrubbed, oldest first.
  package private(set) var context: [String] = []
  /// The most recent `seh` trace lines, scrubbed, oldest first.
  package private(set) var trace: [String] = []
  private var blockReader = NFS2015CrashBlockReader()
  /// The `wine-trace:` lines of a session that set `WINE_TRACE_PAGE`.
  package private(set) var pageTrace = NFS2015PageTrace()
  /// The `wine-rwx:` lines of a session that set `WINE_RWX_WX_EMULATION`.
  package private(set) var rwx = NFS2015RwxLog()
  private var pending = ""

  package init() {}

  /// The `wine-crash:` blocks of a runtime that prints them, oldest first; empty for a runtime
  /// that does not.
  package var crashBlocks: [NFS2015CrashBlock] { blockReader.blocks }

  /// Whether a `wine-crash:` block has begun and its last line has not been read yet.
  package var hasOpenCrashBlock: Bool { blockReader.isOpen }

  package static func == (left: Self, right: Self) -> Bool {
    left.launches == right.launches && left.faults == right.faults
      && left.displayModes.map(\.mode) == right.displayModes.map(\.mode)
      && left.displayModes.map(\.count) == right.displayModes.map(\.count)
      && left.serverCrashes == right.serverCrashes && left.context == right.context
      && left.trace == right.trace && left.crashBlocks == right.crashBlocks
      && left.pageTrace == right.pageTrace && left.rwx == right.rwx
  }

  /// Reads the whole of a log at once.
  package init(log: String) {
    var digest = Self()
    digest.feed(log)
    digest.finish()
    self = digest
  }

  /// Reads more of the log. A line that is not finished yet waits for the next piece.
  /// - Complexity: O(size of the piece).
  package mutating func feed(_ text: String) {
    pending += text
    guard let last = pending.lastIndex(of: "\n") else {
      // A single enormous line must not grow without bound.
      if pending.count > 65_536 { pending = String(pending.suffix(4096)) }
      return
    }
    let complete = pending[..<last]
    let rest = String(pending[pending.index(after: last)...])
    for line in complete.split(separator: "\n", omittingEmptySubsequences: true) {
      read(String(line))
    }
    pending = rest
  }

  /// Reads a last line the log ended without a line feed.
  package mutating func finish() {
    if !pending.isEmpty {
      read(pending)
      pending = ""
    }
    blockReader.finish()
  }

  /// Takes the exception trace from the end of a diagnostic debug file instead of from the
  /// session log, because in that mode the `trace` lines never reach the session log.
  package mutating func setTrace(fromText text: String) {
    let lines = text.split(separator: "\n").map(String.init).filter { $0.contains(":trace:seh:") }
    trace = lines.suffix(Self.traceLimit).compactMap { NFS2015Redaction.scrub($0) }
  }

  private mutating func read(_ raw: String) {
    let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
    blockReader.read(line)
    pageTrace.read(line)
    rwx.read(line)
    if line.hasPrefix("compatdb: NFS16.exe [") { launches += 1 }
    if line.hasPrefix("wineserver crashed") { serverCrashes += 1 }
    if let mode = Self.displayMode(in: line) { note(mode) }
    if let fault = NFS2015FaultLine.parse(line), faults.count < Self.faultLimit {
      faults.append(fault)
      pageTrace.markFault()
    }
    guard NFS2015Redaction.isDiagnostic(line), let clean = NFS2015Redaction.scrub(line) else {
      return
    }
    if line.contains(":trace:seh:") {
      trace.append(clean)
      if trace.count > Self.traceLimit { trace.removeFirst(trace.count - Self.traceLimit) }
    } else {
      context.append(clean)
      if context.count > Self.contextLimit {
        context.removeFirst(context.count - Self.contextLimit)
      }
    }
  }

  private mutating func note(_ mode: String) {
    if let index = displayModes.firstIndex(where: { $0.mode == mode }) {
      displayModes[index].count += 1
    } else if displayModes.count < Self.modeLimit {
      displayModes.append((mode, 1))
    }
  }

  /// `1920x1200@60` from `info:  Setting display mode: 1920x1200@60`.
  static func displayMode(in line: String) -> String? {
    guard let range = line.range(of: "Setting display mode: ") else { return nil }
    let mode = line[range.upperBound...].prefix { $0.isNumber || $0 == "x" || $0 == "@" }
    return mode.contains("x") && mode.count <= 16 ? String(mode) : nil
  }
}
