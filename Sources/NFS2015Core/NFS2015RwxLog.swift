import Foundation

/// The `wine-rwx:` lines of patch 0008, which the runtime prints when `WINE_RWX_WX_EMULATION=1`
/// is set: one line when a process first has a page under the emulation, and one at the process's
/// exit with its counters.
///
/// Every field is a number, so nothing a line carries can hold a name or a path, and a line that
/// does not parse is dropped. Both lists are bounded, and the totals keep counting past them.
package struct NFS2015RwxLog: Equatable, Sendable {
  /// `wine-rwx: active pid=<n> first page <address>`.
  package struct Activation: Equatable, Sendable {
    package let process: UInt32
    package let firstPage: UInt64
  }

  /// `wine-rwx: pid=<n> stores=<n> released(host=<n> carrier=<n> hot=<n>)`.
  package struct Counters: Equatable, Sendable {
    package let process: UInt32
    /// Stores the emulation let through, one instruction at a time.
    package let stores: UInt64
    /// Faults from host code, whose page the runtime opened and left open.
    package let releasedHost: UInt64
    /// Pages opened for a write the kernel makes for the program (a read into the page).
    package let releasedCarrier: UInt64
    /// Pages released because they were written more often than the hot limit allows.
    package let releasedHot: UInt64
  }

  static let prefix = "wine-rwx: "
  static let listLimit = 16

  package private(set) var activations: [Activation] = []
  package private(set) var counters: [Counters] = []
  /// The per-page lines of patch 0010, when the runtime printed any.
  package private(set) var pageLog = NFS2015RwxPageLog()
  /// Every well-formed line read, past the lists' limits too.
  package private(set) var lines = 0
  package private(set) var totalStores: UInt64 = 0
  package private(set) var totalReleased: UInt64 = 0
  package private(set) var hotReleasedProcesses = 0
  /// Processes whose exit line was counted, so a line read twice is counted once.
  private var counted: Set<UInt32> = []
  static let countedLimit = 4096

  package init() {}

  package var isEmpty: Bool { lines == 0 }

  /// Takes one log line if it is a `wine-rwx:` line.
  mutating func read(_ line: String) {
    guard line.hasPrefix(Self.prefix) else { return }
    let body = line.dropFirst(Self.prefix.count)
    if body.hasPrefix("page ") {
      if pageLog.read(line) { lines += 1 }
    } else if body.hasPrefix("active "), let value = Self.activation(body.dropFirst(7)) {
      lines += 1
      if !activations.contains(value), activations.count < Self.listLimit {
        activations.append(value)
      }
    } else if body.hasPrefix("pid="), let value = Self.counters(body) {
      lines += 1
      if counted.count < Self.countedLimit, counted.insert(value.process).inserted {
        totalStores &+= value.stores
        totalReleased &+= value.releasedHost &+ value.releasedCarrier &+ value.releasedHot
        if value.releasedHot > 0 { hotReleasedProcesses += 1 }
      }
      if !counters.contains(value), counters.count < Self.listLimit { counters.append(value) }
    }
  }

  private static func number(_ text: Substring, digits: Int = 10) -> UInt64? {
    guard (1...digits).contains(text.count), text.allSatisfy(\.isNumber), text.allSatisfy(\.isASCII)
    else { return nil }
    return UInt64(text)
  }

  /// `pid=80026 first page 0x50000000` (the runtime prints the address with `%p`, so `0x` is
  /// accepted and optional).
  private static func activation(_ text: Substring) -> Activation? {
    let words = text.split(separator: " ")
    guard words.count == 4, words[0].hasPrefix("pid="), words[1] == "first", words[2] == "page",
      let process = number(words[0].dropFirst(4)), process <= UInt64(UInt32.max)
    else { return nil }
    var address = words[3]
    if address.hasPrefix("0x") { address = address.dropFirst(2) }
    guard let page = NFS2015CrashBlock.hex(String(address)) else { return nil }
    return Activation(process: UInt32(process), firstPage: page)
  }

  /// `pid=80026 stores=750 released(host=0 carrier=0 hot=0)`.
  private static func counters(_ text: Substring) -> Counters? {
    let words = text.split(separator: " ")
    guard words.count == 5, words[0].hasPrefix("pid="), words[1].hasPrefix("stores="),
      words[2].hasPrefix("released(host="), words[3].hasPrefix("carrier="),
      words[4].hasPrefix("hot="), words[4].hasSuffix(")"),
      let process = number(words[0].dropFirst(4)), process <= UInt64(UInt32.max),
      let stores = number(words[1].dropFirst(7)),
      let host = number(words[2].dropFirst("released(host=".count)),
      let carrier = number(words[3].dropFirst(8)),
      let hot = number(words[4].dropFirst(4).dropLast())
    else { return nil }
    return Counters(
      process: UInt32(process), stores: stores, releasedHost: host, releasedCarrier: carrier,
      releasedHot: hot)
  }

  /// One short line for the session log: numbers only. Nil when the log held no `wine-rwx:` line.
  package var summary: String? {
    guard !isEmpty else { return nil }
    var text =
      "RWX W^X emulation: \(activations.count) process\(activations.count == 1 ? "" : "es") "
      + "reported active, \(counters.count) reported counters"
    if !counters.isEmpty {
      text += ": \(totalStores) stores through, \(totalReleased) pages released"
      if hotReleasedProcesses > 0 {
        text += " (\(hotReleasedProcesses) because they were written too often)"
      }
    }
    text += "."
    if !pageLog.isEmpty {
      let released = pageLog.pages.reduce(0) { $0 + $1.releases.values.reduce(0, +) }
      let protected = pageLog.pages.reduce(0) { $0 + $1.protections.values.reduce(0, +) }
      let lines = pageLog.total
      let pages = pageLog.pages.count
      text +=
        " Page log: \(lines) line\(lines == 1 ? "" : "s") about \(pages) "
        + "page\(pages == 1 ? "" : "s"), \(protected) protected, \(released) released."
    }
    return text
  }
}
