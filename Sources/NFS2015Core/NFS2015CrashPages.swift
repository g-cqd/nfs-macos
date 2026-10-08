import Foundation

/// The lines patch 0006 adds to the `wine-crash:` block: what the memory manager says about the
/// pages around the instruction pointer, a checksum of that page, the thread count, return
/// address candidates, windows of code bytes and the registers that point near the instruction
/// pointer. Numbers and the base names of loaded modules only.
///
/// Reading is lenient like `NFS2015CrashBlock`: a line that does not parse is ignored, every
/// part is optional, and every list is bounded.
package struct NFS2015CrashPages: Equatable, Sendable {
  /// `NtQueryVirtualMemory` for one page, or the fact that Wine could not query it.
  package struct Query: Equatable, Sendable {
    package let page: UInt64
    /// nil when Wine printed `not queryable`.
    package let info: Info?

    package struct Info: Equatable, Sendable {
      package let allocationBase: UInt64
      package let allocationProtect: UInt32
      package let base: UInt64
      package let size: UInt64
      package let state: UInt32
      package let protect: UInt32
      package let type: UInt32
    }
  }

  /// FNV-1a over the 4 KiB page of the instruction pointer and how many of its 256 groups of
  /// 16 bytes are all zero.
  package struct Checksum: Equatable, Sendable {
    package let page: UInt64
    /// nil when the page could not be read.
    package let fnv1a64: UInt64?
    package let zeroGroups: Int?
  }

  package struct ReturnCandidate: Equatable, Sendable {
    package let slot: Int
    package let address: UInt64
    package let module: String
    package let offset: UInt64
  }

  package struct CodeRow: Equatable, Sendable {
    package let address: UInt64
    package let bytes: [UInt8]
  }

  package struct UnreadableRange: Equatable, Sendable {
    package let start: UInt64
    package let end: UInt64
  }

  /// A span of code bytes around the instruction pointer or around a register's value.
  package struct CodeWindow: Equatable, Sendable {
    /// `pc` or a register name.
    package let label: String
    package let center: UInt64
    package let before: UInt64
    package let after: UInt64
    package fileprivate(set) var rows: [CodeRow] = []
    package fileprivate(set) var unreadable: [UnreadableRange] = []
  }

  package struct NearRegister: Equatable, Sendable {
    package let register: String
    /// Positive when the register is above the instruction pointer.
    package let delta: Int64
  }

  package private(set) var queries: [Query] = []
  package private(set) var checksum: Checksum?
  /// nil when the count was `?`.
  package private(set) var threads: Int?
  package private(set) var hasThreadLine = false
  package private(set) var teb: UInt64?
  package private(set) var returns: [ReturnCandidate] = []
  package private(set) var windows: [CodeWindow] = []
  package private(set) var near: [NearRegister] = []

  static let queryLimit = 6
  static let returnLimit = 8
  static let windowLimit = 4
  static let rowLimit = 24
  static let unreadableLimit = 8
  static let nearLimit = 16
  static let moduleLimit = 64

  package var isEmpty: Bool {
    queries.isEmpty && checksum == nil && !hasThreadLine && returns.isEmpty && windows.isEmpty
      && near.isEmpty
  }

  package init() {}

  /// Takes the body of one `wine-crash:` line if it is one of these lines.
  /// - Returns: Whether the line belonged here.
  mutating func read(_ body: Substring) -> Bool {
    if body.hasPrefix("vq[") {
      readQuery(body.dropFirst(3))
    } else if body.hasPrefix("pagesum ") {
      readChecksum(body.dropFirst(8))
    } else if body.hasPrefix("threads=") {
      readThreads(body.dropFirst(8))
    } else if body.hasPrefix("ret[") {
      readReturn(body.dropFirst(4))
    } else if body.hasPrefix("window ") {
      readWindow(body.dropFirst(7))
    } else if body.hasPrefix("code[") {
      readCode(body.dropFirst(5))
    } else if body.hasPrefix("near-pc:") {
      readNear(body.dropFirst(8))
    } else {
      return false
    }
    return true
  }

  // MARK: Lines

  private mutating func readQuery(_ text: Substring) {
    guard queries.count < Self.queryLimit, let close = text.firstIndex(of: "]"),
      let page = NFS2015CrashBlock.hex(String(text[..<close]))
    else { return }
    let rest = text[text.index(after: close)...].drop { $0 == " " }
    if rest.hasPrefix("not queryable") {
      queries.append(Query(page: page, info: nil))
      return
    }
    let fields = Self.pairs(rest)
    guard let alloc = fields["alloc"].flatMap(NFS2015CrashBlock.hex),
      let allocProtect = fields["aprot"].flatMap({ UInt32($0, radix: 16) }),
      let base = fields["base"].flatMap(NFS2015CrashBlock.hex),
      let size = fields["size"].flatMap(NFS2015CrashBlock.hex),
      let state = fields["state"].flatMap({ UInt32($0, radix: 16) }),
      let protect = fields["prot"].flatMap({ UInt32($0, radix: 16) }),
      let type = fields["type"].flatMap({ UInt32($0, radix: 16) })
    else { return }
    queries.append(
      Query(
        page: page,
        info: .init(
          allocationBase: alloc, allocationProtect: allocProtect, base: base, size: size,
          state: state, protect: protect, type: type)))
  }

  private mutating func readChecksum(_ text: Substring) {
    let words = text.split(separator: " ").map(String.init)
    guard checksum == nil, let first = words.first, let page = NFS2015CrashBlock.hex(first)
    else { return }
    if words.dropFirst().first == "unreadable" {
      checksum = Checksum(page: page, fnv1a64: nil, zeroGroups: nil)
      return
    }
    let fields = Self.pairs(text)
    guard let fnv = fields["fnv1a64"].flatMap(NFS2015CrashBlock.hex),
      let zero = fields["zero16"]?.split(separator: "/").first.flatMap({ Int($0) }),
      (0...256).contains(zero)
    else { return }
    checksum = Checksum(page: page, fnv1a64: fnv, zeroGroups: zero)
  }

  private mutating func readThreads(_ text: Substring) {
    guard !hasThreadLine else { return }
    let fields = Self.pairs("threads=" + text)
    guard let count = fields["threads"] else { return }
    if count == "?" {
      threads = nil
    } else if let value = Int(count), (0...1_000_000).contains(value) {
      threads = value
    } else {
      return
    }
    hasThreadLine = true
    teb = fields["teb"].flatMap(NFS2015CrashBlock.hex)
  }

  private mutating func readReturn(_ text: Substring) {
    guard returns.count < Self.returnLimit, let close = text.firstIndex(of: "]"),
      let slot = Int(text[..<close]), (0...1_000_000).contains(slot)
    else { return }
    let rest = text[text.index(after: close)...].drop { $0 == "=" }
    let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
    guard words.count == 2, let address = NFS2015CrashBlock.hex(words[0]),
      let plus = words[1].lastIndex(of: "+")
    else { return }
    let module = String(words[1][..<plus].filter { $0.isASCII && !$0.isWhitespace }.prefix(64))
    var offsetText = words[1][words[1].index(after: plus)...]
    if offsetText.hasPrefix("0x") { offsetText = offsetText.dropFirst(2) }
    guard !module.isEmpty, let offset = NFS2015CrashBlock.hex(String(offsetText)) else { return }
    returns.append(
      ReturnCandidate(slot: slot, address: address, module: module, offset: offset))
  }

  private mutating func readWindow(_ text: Substring) {
    guard windows.count < Self.windowLimit else {
      // Rows after a window that was not kept must not attach to the one before it.
      current = nil
      return
    }
    let words = text.split(separator: " ")
    guard words.count >= 2, let equals = words[0].firstIndex(of: "="),
      let center = NFS2015CrashBlock.hex(String(words[0][words[0].index(after: equals)...])),
      NFS2015CrashBlock.registerNames.contains(String(words[0][..<equals]))
        || words[0][..<equals] == "pc",
      words[1].hasPrefix("span=-")
    else {
      current = nil
      return
    }
    let span = words[1].dropFirst(6).components(separatedBy: "..+")
    guard span.count == 2, let before = NFS2015CrashBlock.hex(span[0]),
      let after = NFS2015CrashBlock.hex(span[1])
    else {
      current = nil
      return
    }
    windows.append(
      CodeWindow(
        label: String(words[0][..<equals]), center: center, before: before, after: after))
    current = windows.count - 1
  }

  private var current: Int?

  private mutating func readCode(_ text: Substring) {
    guard let index = current, let close = text.firstIndex(of: "]") else { return }
    let head = String(text[..<close])
    let rest = text[text.index(after: close)...].drop { $0 == ":" || $0 == " " }
    if head.contains("..") {
      let ends = head.components(separatedBy: "..")
      guard rest.hasPrefix("unreadable"), ends.count == 2,
        let start = NFS2015CrashBlock.hex(ends[0]), let end = NFS2015CrashBlock.hex(ends[1]),
        windows[index].unreadable.count < Self.unreadableLimit
      else { return }
      windows[index].unreadable.append(UnreadableRange(start: start, end: end))
      return
    }
    guard let address = NFS2015CrashBlock.hex(head), windows[index].rows.count < Self.rowLimit
    else { return }
    let bytes = rest.split(separator: " ").compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
    guard !bytes.isEmpty, bytes.count <= 32 else { return }
    windows[index].rows.append(CodeRow(address: address, bytes: bytes))
  }

  private mutating func readNear(_ text: Substring) {
    for token in text.split(separator: " ") where near.count < Self.nearLimit {
      guard let equals = token.firstIndex(of: "=") else { continue }
      let name = String(token[..<equals])
      var value = token[token.index(after: equals)...]
      guard NFS2015CrashBlock.registerNames.contains(name), value.hasPrefix("pc"),
        let sign = value.dropFirst(2).first, sign == "+" || sign == "-"
      else { continue }
      value = value.dropFirst(3)
      if value.hasPrefix("0x") { value = value.dropFirst(2) }
      guard let magnitude = NFS2015CrashBlock.hex(String(value)), magnitude < 0x1000 else {
        continue
      }
      near.append(
        NearRegister(register: name, delta: sign == "-" ? -Int64(magnitude) : Int64(magnitude)))
    }
  }

  private static func pairs(_ text: Substring) -> [String: String] {
    var result: [String: String] = [:]
    for token in text.split(separator: " ") {
      guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { continue }
      let key = String(token[..<equals])
      if result[key] == nil { result[key] = String(token[token.index(after: equals)...]) }
    }
    return result
  }
}
