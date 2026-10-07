import Foundation

/// One fault line Wine printed for a Windows process that died of an unhandled exception.
package struct NFS2015FaultLine: Equatable, Sendable {
  package enum Kind: Equatable, Sendable {
    /// `wine: Unhandled page fault on read|write|execute access to <value> at address <rip>`.
    case pageFault(access: String, value: UInt64)
    /// `wine: Unhandled exception 0x<code> at address <rip>`.
    case exception(code: UInt32)
  }

  package let kind: Kind
  /// The instruction pointer Wine printed.
  package let address: UInt64
  package let thread: String
  /// The line as printed, bounded.
  package let text: String

  /// Reads the fault lines out of a session log; every other line is ignored.
  /// - Complexity: O(log size).
  package static func lines(in log: String) -> [NFS2015FaultLine] {
    log.split(separator: "\n").compactMap { parse(String($0)) }
  }

  static func parse(_ raw: String) -> NFS2015FaultLine? {
    guard raw.hasPrefix("wine: Unhandled ") else { return nil }
    let words = raw.split(separator: " ").map(String.init)
    guard let at = words.firstIndex(of: "address"), at + 1 < words.count,
      let address = hex(words[at + 1]), let thread = words.firstIndex(of: "(thread"),
      thread + 1 < words.count
    else { return nil }
    let id = words[thread + 1].filter(\.isHexDigit)
    guard !id.isEmpty, id.count <= 8 else { return nil }
    let text = String(raw.prefix(240))
    if words.count > 6, words[2] == "page", words[3] == "fault", words[4] == "on",
      ["read", "write", "execute"].contains(words[5]), let to = words.firstIndex(of: "to"),
      to + 1 < words.count, let value = hex(words[to + 1])
    {
      return Self(
        kind: .pageFault(access: words[5], value: value), address: address, thread: id, text: text)
    }
    if words.count > 3, words[2] == "exception", words[3].hasPrefix("0x"),
      let code = UInt32(words[3].dropFirst(2), radix: 16)
    {
      return Self(kind: .exception(code: code), address: address, thread: id, text: text)
    }
    return nil
  }

  private static func hex(_ word: String) -> UInt64? {
    (1...16).contains(word.count) ? UInt64(word, radix: 16) : nil
  }
}

/// What a fault line says about the failure, read from the numbers alone.
///
/// Nothing here knows why the game faulted. These are observations that narrow it: where the
/// instruction was, what kind of value the pointer was, and whether the same place faulted
/// before. The module is `NFS16.exe`, which the Wine module dumps put at 0x140000000 up to
/// 0x1488F2000 (backtrace files of 2026-10-07); a different build of the game would have another
/// size, so the size is a parameter.
package struct NFS2015FaultFinding: Equatable, Sendable {
  package static let imageBase: UInt64 = 0x1_4000_0000
  package static let imageSize: UInt64 = 0x88F_2000

  package let line: NFS2015FaultLine
  /// Where the instruction pointer is, as module and offset or as an address outside the image.
  package let location: String
  /// The offset in the image when the instruction pointer is inside it.
  package let rva: UInt64?
  /// Short observations, most telling first; empty when the numbers show nothing notable.
  package let patterns: [String]

  package init(line: NFS2015FaultLine, imageSize: UInt64 = Self.imageSize) {
    self.line = line
    let base = Self.imageBase
    let inImage = line.address >= base && line.address < base + imageSize
    rva = inImage ? line.address - base : nil
    location =
      inImage
      ? "nfs16+0x\(String(line.address - base, radix: 16, uppercase: true))"
      : "0x\(String(line.address, radix: 16, uppercase: true)), outside nfs16 "
        + "(0x\(String(base, radix: 16, uppercase: true))-"
        + "0x\(String(base + imageSize, radix: 16, uppercase: true)))"
    patterns = Self.patterns(for: line, inImage: inImage, imageSize: imageSize)
  }

  private static func patterns(for line: NFS2015FaultLine, inImage: Bool, imageSize: UInt64)
    -> [String]
  {
    switch line.kind {
    case .exception(let code):
      return ["unhandled exception 0x\(String(code, radix: 16, uppercase: true))"]
    case .pageFault(let access, let value):
      var found: [String] = []
      // Wine prints the faulting address, which for a fetch is the instruction pointer itself.
      let fetch = access == "execute" || value == line.address
      if fetch {
        found.append(fetchPattern(address: line.address, inImage: inImage))
      } else {
        found.append(contentsOf: dataPatterns(value: value, access: access, imageSize: imageSize))
      }
      if !fetch, !inImage {
        found.append("the instruction is outside nfs16, in another module or in data")
      }
      return found
    }
  }

  private static func fetchPattern(address: UInt64, inImage: Bool) -> String {
    if address == 0 { return "call or jump through a null function pointer" }
    if address < 0x10000 { return "jump to a small number, as if a function pointer were an index" }
    if inImage { return "instruction fetch inside the image, which is not executable there" }
    return address > 0x7FFF_FFFF_FFFF
      ? "jump to a non-canonical address: the pointer was overwritten with a non-address"
      : "execute fault outside the image: the target is heap or data, not game code"
  }

  private static func dataPatterns(value: UInt64, access: String, imageSize: UInt64) -> [String] {
    var found: [String] = []
    if value == 0 {
      found.append("null pointer \(access)")
    } else if value < 0x10000 {
      found.append(
        "near-null \(access) at 0x\(String(value, radix: 16, uppercase: true)): a field of a null object"
      )
    }
    if let text = asciiText(value) {
      found.append(
        "the pointer's bytes spell the ASCII text \"\(text)\": a string was used as a pointer")
    } else if looksLikeUTF16(value) {
      found.append("the pointer may hold UTF-16 text: a wide string used as a pointer")
    }
    if value > 0x7FFF_FFFF_FFFF {
      found.append("non-canonical pointer: the value is not an address")
    } else if value >= imageBase, value < imageBase + imageSize {
      found.append("the pointer points into the game image")
    }
    return found
  }

  /// The eight bytes as text, when all eight are printable ASCII (little endian, as in memory).
  static func asciiText(_ value: UInt64) -> String? {
    let bytes = (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// At least two 16-bit lanes are printable ASCII and every other lane is a byte-sized number.
  static func looksLikeUTF16(_ value: UInt64) -> Bool {
    let lanes = (0..<4).map { UInt16(truncatingIfNeeded: value >> (16 * UInt64($0))) }
    return lanes.filter { (0x20...0x7E).contains($0) }.count >= 2 && lanes.allSatisfy { $0 < 0x100 }
  }
}
