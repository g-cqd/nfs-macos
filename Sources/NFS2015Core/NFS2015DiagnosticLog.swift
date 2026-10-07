import Foundation
import LauncherCore

/// The opt-in Wine debug log: which channels, where the lines go, and how much is kept.
///
/// **Channels.** `WINEDEBUG` takes `[class]+channel` or `[class]-channel` items, and an omitted
/// class means all four (`trace`, `warn`, `fixme`, `err`) (Wine's `wine(1)` manual page). The app
/// normally sets `-all`, which also silences `err`. The diagnostic set is `err+all,fixme-all,+seh`:
/// errors from every channel, no fixmes, and the `seh` channel, which in Wine's `signal_x86_64.c`
/// prints each dispatched exception's code, flags, address and exception parameters followed by
/// the full register set (`rax`..`r15`, `rsp`). That is the exception record and the registers of
/// the fault, which `winedbg` could not give (`Couldn't get first exception ... No backtrace
/// available`). It is not a stack walk, and it is the lightest set found that names the fault; it
/// has not been run on this runtime **(not verified)**. `+relay` was rejected: it logs every
/// call of every Windows function, which would drown the one line wanted and slow the game.
///
/// **Bounds.** Wine has no size limit for its debug output, so in this mode the Wine processes
/// write to a pipe the session helper drains: lines of the `trace` class go to rotating files of
/// `segmentBytes` each, of which the newest `segmentCount` are kept, and every other line goes
/// to the session log as before. Files of earlier launches are deleted oldest first so all of them
/// together stay within `totalBytes`.
package enum NFS2015DiagnosticLog {
  package static let channels = "err+all,fixme-all,+seh"
  package static let segmentBytes = 8 * 1_048_576
  package static let segmentCount = 4
  package static let totalBytes = 96 * 1_048_576
  static let lineLimit = 16_384
  static let prefix = "wine-debug-"

  /// A sortable UTC time for file names, such as `20261007T204512Z`.
  package static func stamp(_ date: Date) -> String {
    let parts = Calendar(identifier: .gregorian).dateComponents(
      in: TimeZone(identifier: "UTC") ?? .gmt, from: date)
    return String(
      format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
  }

  /// Where one line goes.
  package enum Route: Equatable, Sendable {
    case debug
    case session
  }

  /// Splits a byte stream into lines and says where each belongs. Partial lines wait for their
  /// end; a line longer than `lineLimit` is cut and marked, and the rest of it dropped.
  package struct Router: Sendable {
    private var pending: [UInt8] = []
    private var dropping = false

    package init() {}

    /// - Returns: The complete lines this chunk finished, each without its line feed.
    package mutating func feed(_ chunk: Data) -> [(route: Route, line: [UInt8])] {
      var lines: [(route: Route, line: [UInt8])] = []
      for byte in chunk {
        if byte == 10 {
          lines.append((Self.route(pending), pending))
          pending.removeAll(keepingCapacity: true)
          dropping = false
        } else if pending.count < NFS2015DiagnosticLog.lineLimit {
          pending.append(byte)
        } else if !dropping {
          dropping = true
          pending.append(contentsOf: Array(" [line cut]".utf8))
        }
      }
      return lines
    }

    /// What is left when the stream ends without a final line feed.
    package mutating func finish() -> [(route: Route, line: [UInt8])] {
      guard !pending.isEmpty else { return [] }
      defer { pending.removeAll() }
      return [(Self.route(pending), pending)]
    }

    private static let marker = Array(":trace:".utf8)

    static func route(_ line: [UInt8]) -> Route {
      // Wine puts the class right after the process and thread ids, so look near the start.
      let head = line.prefix(48)
      guard head.count >= marker.count else { return .session }
      for start in head.indices where start + marker.count <= head.endIndex {
        if head[start..<start + marker.count].elementsEqual(marker) { return .debug }
      }
      return .session
    }
  }

  /// Writes debug lines into numbered files of at most `segmentBytes`, keeping the newest
  /// `segmentCount`.
  package struct Segments {
    private let folder: URL
    private let stamp: String
    private let segmentBytes: Int
    private let segmentCount: Int
    private var index = 0
    private var written = 0
    private var handle: FileHandle?
    private var kept: [URL] = []
    package private(set) var failure: String?

    package init(
      folder: URL, stamp: String, segmentBytes: Int = NFS2015DiagnosticLog.segmentBytes,
      segmentCount: Int = NFS2015DiagnosticLog.segmentCount
    ) {
      self.folder = folder
      self.stamp = stamp
      self.segmentBytes = segmentBytes
      self.segmentCount = segmentCount
    }

    package var files: [URL] { kept }

    package mutating func append(_ line: [UInt8]) {
      guard failure == nil else { return }
      do {
        if handle == nil || (written > 0 && written + line.count + 1 > segmentBytes) {
          try rotate()
        }
        try handle?.write(contentsOf: Data(line + [10]))
        written += line.count + 1
      } catch { failure = error.localizedDescription }
    }

    package mutating func close() {
      do { try handle?.close() } catch { failure = failure ?? error.localizedDescription }
      handle = nil
    }

    private mutating func rotate() throws {
      do { try handle?.close() } catch { failure = failure ?? error.localizedDescription }
      index += 1
      let url = folder.appendingPathComponent(
        String(format: "%@%@-%03d.log", NFS2015DiagnosticLog.prefix, stamp, index))
      try Data().write(to: url, options: .withoutOverwriting)
      handle = try FileHandle(forWritingTo: url)
      written = 0
      kept.append(url)
      while kept.count > segmentCount {
        let oldest = kept.removeFirst()
        try FileManager.default.removeItem(at: oldest)
      }
    }
  }

  /// Deletes the oldest debug files of earlier launches until the rest fit in `totalBytes`.
  /// - Returns: How many files were deleted.
  @discardableResult
  package static func prune(in folder: URL, limit: Int = totalBytes) -> Int {
    let files = FileManager.default
    guard
      let names = try? files.contentsOfDirectory(atPath: folder.path)
        .filter({ $0.hasPrefix(prefix) && $0.hasSuffix(".log") }).sorted()
    else { return 0 }
    var sizes: [(url: URL, size: Int)] = names.map { name in
      let url = folder.appendingPathComponent(name)
      let attributes = try? files.attributesOfItem(atPath: url.path)
      return (url, (attributes?[.size] as? Int) ?? 0)
    }
    var total = sizes.reduce(0) { $0 + $1.size }
    var removed = 0
    while total > limit, !sizes.isEmpty {
      let oldest = sizes.removeFirst()
      do {
        try files.removeItem(at: oldest.url)
        total -= oldest.size
        removed += 1
      } catch { total -= oldest.size }
    }
    return removed
  }
}
