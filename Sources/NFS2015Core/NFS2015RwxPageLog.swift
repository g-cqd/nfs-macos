import Foundation

/// The `wine-rwx: page …` lines of patch 0010, which the runtime prints for the pages of the
/// window named by `WINE_RWX_WX_LOG` (at most 200 lines per Wine process): when the emulation took
/// a page over and through which path, why a page was left alone, the first stores into it with the
/// instruction that made them, and why a page was released.
///
/// Every field is a number or one of a fixed set of words, so nothing a line carries can hold a
/// name or a path, and a line that does not parse is dropped. The lines carry no process id, so
/// the lines of several processes are merged; the summaries are bounded however long the log is.
package struct NFS2015RwxPageLog: Equatable, Sendable {
  package enum ProtectReason: String, CaseIterable, Sendable {
    case allocation = "alloc"
    case commit
    case protect
    case other
  }

  package enum SkipReason: String, CaseIterable, Sendable {
    case flags
    case noView = "noview"
    case notVirtualAlloc = "notvalloc"
    case system
    case released
  }

  package enum ReleaseReason: String, CaseIterable, Sendable {
    /// Written more often than the busy-page limit allows, by code elsewhere.
    case hot
    /// Written more often than the limit for a page that patches its own code.
    case hotSelfModifying = "hot-smc"
    /// A write from host code.
    case host
    /// A write the kernel makes for the program.
    case hostKernel = "host-kernel"
    /// A store that straddles into another page.
    case cross
    /// A fault under the trap-flag emulation (only with `WINE_RWX_WX_TF_RELEASE=1`).
    case trapFlag = "tf"
  }

  package enum Event: Equatable, Sendable {
    case protected(page: UInt64, reason: ProtectReason, protection: UInt32)
    case skipped(page: UInt64, reason: SkipReason, protection: UInt32, via: ProtectReason)
    case store(page: UInt64, number: UInt32, instruction: UInt64, thread: UInt64)
    case released(page: UInt64, reason: ReleaseReason, stores: UInt64)
    case stateDropped(page: UInt64)

    package var page: UInt64 {
      switch self {
      case .protected(let page, _, _), .skipped(let page, _, _, _), .store(let page, _, _, _),
        .released(let page, _, _), .stateDropped(let page):
        page
      }
    }
  }

  /// What happened to one page, over every line read.
  package struct PageSummary: Equatable, Sendable {
    package let page: UInt64
    package fileprivate(set) var protections: [ProtectReason: Int] = [:]
    package fileprivate(set) var skips: [SkipReason: Int] = [:]
    package fileprivate(set) var releases: [ReleaseReason: Int] = [:]
    package fileprivate(set) var droppedStates = 0
    /// The first stores printed (the runtime prints five per page).
    package fileprivate(set) var firstStores: [(number: UInt32, instruction: UInt64)] = []
    /// The highest store number printed; later stores are not printed.
    package fileprivate(set) var lastStoreNumber: UInt32 = 0
    /// The release counters' `stores=` of the latest release line.
    package fileprivate(set) var storesAtRelease: UInt64?

    package static func == (left: Self, right: Self) -> Bool {
      left.page == right.page && left.protections == right.protections
        && left.skips == right.skips && left.releases == right.releases
        && left.droppedStates == right.droppedStates
        && left.firstStores.map(\.number) == right.firstStores.map(\.number)
        && left.firstStores.map(\.instruction) == right.firstStores.map(\.instruction)
        && left.lastStoreNumber == right.lastStoreNumber
        && left.storesAtRelease == right.storesAtRelease
    }
  }

  static let prefix = "wine-rwx: page "
  static let pageLimit = 16
  static let headLimit = 24
  static let tailLimit = 24

  /// The first events in the order read.
  package private(set) var head: [Event] = []
  /// The newest events, once more than `headLimit` have been read.
  package private(set) var tail: [Event] = []
  /// Every well-formed page line read.
  package private(set) var total = 0
  package private(set) var pages: [PageSummary] = []

  package init() {}

  package var isEmpty: Bool { total == 0 }

  /// Events read but kept in neither list.
  package var dropped: Int { total - head.count - newest.count }

  /// Takes one log line if it is a `wine-rwx: page` line.
  /// - Returns: Whether the line was one, whole.
  @discardableResult
  mutating func read(_ line: String) -> Bool {
    guard line.hasPrefix(Self.prefix), let event = Self.parse(line.dropFirst(Self.prefix.count))
    else { return false }
    total += 1
    if head.count < Self.headLimit {
      head.append(event)
    } else {
      tail.append(event)
      if tail.count > 2 * Self.tailLimit { tail.removeFirst(tail.count - Self.tailLimit) }
    }
    summarize(event)
    return true
  }

  /// The newest `tailLimit` events, trimmed lazily while reading.
  package var newest: [Event] { Array(tail.suffix(Self.tailLimit)) }

  private mutating func summarize(_ event: Event) {
    let index: Int
    if let found = pages.firstIndex(where: { $0.page == event.page }) {
      index = found
    } else if pages.count < Self.pageLimit {
      pages.append(PageSummary(page: event.page))
      index = pages.count - 1
    } else {
      return
    }
    switch event {
    case .protected(_, let reason, _): pages[index].protections[reason, default: 0] += 1
    case .skipped(_, let reason, _, _): pages[index].skips[reason, default: 0] += 1
    case .released(_, let reason, let stores):
      pages[index].releases[reason, default: 0] += 1
      pages[index].storesAtRelease = stores
    case .stateDropped: pages[index].droppedStates += 1
    case .store(_, let number, let instruction, _):
      if pages[index].firstStores.count < 5,
        !pages[index].firstStores.contains(where: { $0.number == number })
      {
        pages[index].firstStores.append((number, instruction))
      }
      pages[index].lastStoreNumber = max(pages[index].lastStoreNumber, number)
    }
  }

  // MARK: Parsing

  private static func hex(_ text: Substring) -> UInt64? {
    var digits = text
    if digits.hasPrefix("0x") { digits = digits.dropFirst(2) }
    return NFS2015CrashBlock.hex(String(digits))
  }

  private static func decimal(_ text: Substring, digits: Int = 10) -> UInt64? {
    guard (1...digits).contains(text.count), text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber)
    else { return nil }
    return UInt64(text)
  }

  /// The word inside `name(reason=<word>)`, or nil.
  private static func reason(_ word: Substring, of name: String) -> String? {
    let head = name + "(reason="
    guard word.hasPrefix(head), word.hasSuffix(")") else { return nil }
    return String(word.dropFirst(head.count).dropLast())
  }

  private static func value(_ word: Substring, key: String) -> Substring? {
    word.hasPrefix(key + "=") ? word.dropFirst(key.count + 1) : nil
  }

  private static func parse(_ text: Substring) -> Event? {
    let words = text.split(separator: " ")
    guard words.count >= 2, let page = hex(words[0]) else { return nil }
    let kind = words[1]
    if kind.hasPrefix("protect("), words.count == 3,
      let word = reason(kind, of: "protect"), let why = ProtectReason(rawValue: word),
      let protection = value(words[2], key: "vprot").flatMap(hex)
    {
      return .protected(page: page, reason: why, protection: UInt32(truncatingIfNeeded: protection))
    }
    if kind.hasPrefix("skipped("), words.count == 4,
      let word = reason(kind, of: "skipped"), let why = SkipReason(rawValue: word),
      let protection = value(words[2], key: "vprot").flatMap(hex),
      let via = value(words[3], key: "via").flatMap({ ProtectReason(rawValue: String($0)) })
    {
      return .skipped(
        page: page, reason: why, protection: UInt32(truncatingIfNeeded: protection), via: via)
    }
    if kind == "store", words.count == 5, words[2].hasPrefix("#"),
      let number = decimal(words[2].dropFirst(), digits: 9),
      let instruction = value(words[3], key: "rip").flatMap(hex),
      let thread = value(words[4], key: "tid").flatMap(hex)
    {
      return .store(
        page: page, number: UInt32(number), instruction: instruction, thread: thread)
    }
    if kind.hasPrefix("release("), words.count == 3,
      let word = reason(kind, of: "release"), let why = ReleaseReason(rawValue: word),
      let stores = value(words[2], key: "stores").flatMap({ decimal($0) })
    {
      return .released(page: page, reason: why, stores: stores)
    }
    if words.count == 8,
      text.dropFirst(words[0].count + 1) == "released state dropped after a protection change"
    {
      return .stateDropped(page: page)
    }
    return nil
  }
}
