import Foundation

/// One `wine-trace:` line of patch 0007: a call that touched the traced address window.
///
/// The line is printed only when `WINE_TRACE_PAGE=<start>-<end>` is set for the Wine session. Every
/// field is a number or one of a fixed set of operation names, so nothing a line carries can hold
/// a name or a path, and a line that does not parse is dropped rather than kept as text.
package struct NFS2015PageTraceEvent: Equatable, Sendable {
  package enum Operation: String, CaseIterable, Sendable {
    case allocate = "alloc"
    case free
    case protect
    case write
    case flush
    case map
    case unmap
    case toggle
  }

  package let operation: Operation
  package let thread: UInt64
  package let address: UInt64
  package let size: UInt64
  package let protect: UInt32
  package let oldProtect: UInt32
  package let status: UInt32
  /// The caller's return address, as the runtime found it.
  package let caller: UInt64
  /// FNV-1a over the first 64 bytes, printed after a write or a flush.
  package let checksum: UInt32?

  static let prefix = "wine-trace: "

  /// Reads one log line.
  /// - Returns: nil for any other line, and for a trace line with a missing or malformed field.
  package static func parse(_ line: String) -> Self? {
    guard line.hasPrefix(prefix + "op=") else { return nil }
    var fields: [String: String] = [:]
    for token in line.dropFirst(prefix.count).split(separator: " ") {
      guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { continue }
      let key = String(token[..<equals])
      if fields[key] == nil { fields[key] = String(token[token.index(after: equals)...]) }
    }
    func number(_ key: String, digits: Int = 16) -> UInt64? {
      guard let text = fields[key], (1...digits).contains(text.count),
        text.allSatisfy(\.isHexDigit)
      else { return nil }
      return UInt64(text, radix: 16)
    }
    guard let name = fields["op"], let operation = Operation(rawValue: name),
      let thread = number("tid", digits: 8), let address = number("addr"),
      let size = number("size"), let protect = number("prot", digits: 8),
      let old = number("old", digits: 8), let status = number("status", digits: 8),
      let caller = number("ret")
    else { return nil }
    return Self(
      operation: operation, thread: thread, address: address, size: size,
      protect: UInt32(truncatingIfNeeded: protect), oldProtect: UInt32(truncatingIfNeeded: old),
      status: UInt32(truncatingIfNeeded: status), caller: caller,
      checksum: number("fnv", digits: 8).map { UInt32(truncatingIfNeeded: $0) })
  }

  /// The event as a report line: numbers only.
  package var reportLine: String {
    func hex(_ value: some BinaryInteger) -> String { "0x" + String(value, radix: 16) }
    var text =
      "\(operation.rawValue) tid=\(String(thread, radix: 16)) addr=\(hex(address)) "
      + "size=\(hex(size)) prot=\(hex(protect)) old=\(hex(oldProtect)) status=\(hex(status)) "
      + "ret=\(hex(caller))"
    if let checksum { text += " fnv=\(String(checksum, radix: 16))" }
    return text
  }
}

/// The window one Wine process announced with its first traced call.
package struct NFS2015PageTraceWindow: Equatable, Sendable {
  package let start: UInt64
  package let end: UInt64
  package let process: String

  /// Reads `wine-trace: window=<start>-<end> pid=<hex>`.
  package static func parse(_ line: String) -> Self? {
    guard line.hasPrefix(NFS2015PageTraceEvent.prefix + "window=") else { return nil }
    let tokens = line.dropFirst(NFS2015PageTraceEvent.prefix.count).split(separator: " ")
    guard tokens.count >= 2, tokens[1].hasPrefix("pid=") else { return nil }
    let range = tokens[0].dropFirst(7).split(separator: "-")
    let process = String(tokens[1].dropFirst(4))
    guard range.count == 2, let start = NFS2015CrashBlock.hex(String(range[0])),
      let end = NFS2015CrashBlock.hex(String(range[1])), (1...8).contains(process.count),
      process.allSatisfy(\.isHexDigit)
    else { return nil }
    return Self(start: start, end: end, process: process)
  }
}

/// What the log held of the page trace, kept bounded however long the session runs.
///
/// Only the newest `keepLimit` events are kept. When a fault line is read, the events so far are
/// frozen for that fault, so a report shows what happened before the fault and not the output of
/// whatever ran after it.
package struct NFS2015PageTrace: Equatable, Sendable {
  package static let keepLimit = 200
  static let windowLimit = 8

  /// The events before the most recent fault, oldest first, at most `keepLimit`.
  package private(set) var beforeLastFault: [NFS2015PageTraceEvent] = []
  /// Every event read before the most recent fault.
  package private(set) var totalBeforeLastFault = 0
  /// Every event read in all.
  package private(set) var total = 0
  package private(set) var windows: [NFS2015PageTraceWindow] = []
  /// Whether a fault line has been read since the first event.
  package private(set) var hasFault = false
  private var live: [NFS2015PageTraceEvent] = []

  package init() {}

  package var isEmpty: Bool { total == 0 && windows.isEmpty }

  /// How many events are held for the next fault: never more than twice `keepLimit`.
  package var retainedCount: Int { live.count }

  /// Events dropped before the last fault because only the newest are kept.
  package var droppedBeforeLastFault: Int { totalBeforeLastFault - beforeLastFault.count }
  /// Events read after the most recent fault; they are counted and not shown.
  package var afterLastFault: Int { total - totalBeforeLastFault }

  /// Takes one log line if it is a trace line.
  mutating func read(_ line: String) {
    guard line.hasPrefix(NFS2015PageTraceEvent.prefix) else { return }
    if let event = NFS2015PageTraceEvent.parse(line) {
      total += 1
      live.append(event)
      // Trimmed in bulk so a busy window costs O(1) per event.
      if live.count > 2 * Self.keepLimit { live.removeFirst(live.count - Self.keepLimit) }
    } else if let window = NFS2015PageTraceWindow.parse(line), !windows.contains(window),
      windows.count < Self.windowLimit
    {
      windows.append(window)
    }
  }

  /// Freezes what has been read so far as the events before a fault.
  mutating func markFault() {
    hasFault = true
    beforeLastFault = Array(live.suffix(Self.keepLimit))
    totalBeforeLastFault = total
  }
}
