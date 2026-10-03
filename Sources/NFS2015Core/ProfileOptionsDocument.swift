import Foundation
import LauncherCore

/// The game's own options file, parsed only as far as this app has validated its layout.
///
/// The text file the game writes beside its saves is a flat list of `Key Value` lines: ASCII,
/// one space, a numeric value, and either line feeds or carriage-return line feeds. Every line
/// of the file the game wrote had that shape, so that is the only shape accepted. A file that
/// differs in any way (an unknown byte, a blank line, a text value, a repeated key, a key outside
/// the game's `Gst` families) is refused whole rather than edited on a guess.
///
/// The document keeps each line's key, value and terminator, and nothing else. Writing it back
/// reproduces the input byte for byte; `applying` changes only the values it is asked for, so
/// every other line, the line order and each line's own terminator stay exactly as the game
/// wrote them. The binary `PROFILEOPTIONS` file beside this one is never read by this type.
package struct ProfileOptionsDocument: Equatable, Sendable {
  /// The options file this game writes is a few hundred short lines.
  package static let byteLimit = 262_144
  static let lineLimit = 4096
  static let lineByteLimit = 512
  static let valueByteLimit = 32
  static let replacementLimit = 256

  /// How a line ends. Only the last line of a file may have none.
  package enum Terminator: Equatable, Sendable {
    case none, lineFeed, carriageReturnLineFeed

    var bytes: [UInt8] {
      switch self {
      case .none: []
      case .lineFeed: [10]
      case .carriageReturnLineFeed: [13, 10]
      }
    }
  }

  package struct Entry: Equatable, Sendable {
    package let key: String
    package let value: String
    package let terminator: Terminator
  }

  package let entries: [Entry]
  private let positions: [String: Int]

  /// - Throws: A failure for a file whose layout this app has not validated.
  package init(data: Data) throws(LauncherError) {
    guard !data.isEmpty else { throw Self.refusal("it is empty") }
    guard data.count <= Self.byteLimit else { throw Self.refusal("it is larger than expected") }
    let bytes = [UInt8](data)
    var entries: [Entry] = []
    var positions: [String: Int] = [:]
    var start = 0
    while start < bytes.count {
      var end = start
      while end < bytes.count, bytes[end] != 10 { end += 1 }
      var terminator = Terminator.none
      var contentEnd = end
      if end < bytes.count {
        terminator = .lineFeed
        if end > start, bytes[end - 1] == 13 {
          terminator = .carriageReturnLineFeed
          contentEnd = end - 1
        }
      }
      let entry = try Self.entry(bytes[start..<contentEnd], terminator: terminator)
      guard positions.updateValue(entries.count, forKey: entry.key) == nil else {
        throw Self.refusal("it records \(entry.key) more than once")
      }
      entries.append(entry)
      guard entries.count <= Self.lineLimit else { throw Self.refusal("it has too many lines") }
      start = end < bytes.count ? end + 1 : end
    }
    guard entries.contains(where: { $0.key.hasPrefix("GstRender.") }) else {
      throw Self.refusal("it holds no GstRender options")
    }
    self.entries = entries
    self.positions = positions
  }

  package init(text: String) throws(LauncherError) { try self.init(data: Data(text.utf8)) }

  /// The file exactly as it was parsed, or as `applying` changed it.
  package var data: Data {
    var bytes: [UInt8] = []
    for entry in entries {
      bytes.append(contentsOf: Array(entry.key.utf8))
      bytes.append(32)
      bytes.append(contentsOf: Array(entry.value.utf8))
      bytes.append(contentsOf: entry.terminator.bytes)
    }
    return Data(bytes)
  }

  /// The value recorded for a key, or nil when the game has not written that key.
  package func value(_ key: String) -> String? {
    positions[key].map { entries[$0].value }
  }

  /// Every key the game has written, in file order.
  package var keys: [String] { entries.map(\.key) }

  /// A copy with the given keys set to the given values.
  /// - Throws: A failure when a key is absent from the file, or a name or value is not one the
  ///   game's own lines can hold.
  /// - Complexity: O(file length + number of replacements).
  package func applying(_ replacements: [String: String]) throws(LauncherError) -> Self {
    guard replacements.count <= Self.replacementLimit else {
      throw .operation("Too many option changes in one update.")
    }
    for (key, value) in replacements {
      guard Self.isKey(Array(key.utf8)) else { throw .operation("Unsupported option name: \(key)") }
      guard Self.isNumber(Array(value.utf8)) else {
        throw .operation("Option \(key) must be set to a plain number.")
      }
    }
    let missing = replacements.keys.filter { positions[$0] == nil }.sorted()
    guard missing.isEmpty else {
      throw .operation(
        """
        The game has not written \(missing.joined(separator: ", ")) yet. Start the game once, \
        change that option in its own menu, and quit; then this app can manage it.
        """)
    }
    return Self(
      entries: entries.map { entry in
        replacements[entry.key].map {
          Entry(key: entry.key, value: $0, terminator: entry.terminator)
        } ?? entry
      }, positions: positions)
  }

  /// Whether two recorded numbers are the same value whatever digits they were written with:
  /// `60` and `60.000000` are.
  package static func isSameNumber(_ left: String, _ right: String) -> Bool {
    if left == right { return true }
    guard let first = Double(left), let second = Double(right) else { return false }
    return first == second
  }

  /// The keys whose values differ from another document of the same layout.
  package func changedKeys(from other: Self) -> [String] {
    entries.compactMap { entry in other.value(entry.key) == entry.value ? nil : entry.key }
  }

  /// Whether every line except those named is identical to the other document's, in the same
  /// order, with the same terminators.
  package func isIdentical(to other: Self, except keys: Set<String>) -> Bool {
    guard entries.count == other.entries.count else { return false }
    return zip(entries, other.entries).allSatisfy { mine, theirs in
      mine.key == theirs.key && mine.terminator == theirs.terminator
        && (mine.value == theirs.value || keys.contains(mine.key))
    }
  }

  private init(entries: [Entry], positions: [String: Int]) {
    self.entries = entries
    self.positions = positions
  }

  private static func refusal(_ reason: String) -> LauncherError {
    .operation(
      """
      The game's options file has a layout this app has not validated (\(reason)). Nothing was \
      changed; use the game's own menus for these options.
      """)
  }

  private static func entry(_ line: ArraySlice<UInt8>, terminator: Terminator)
    throws(LauncherError) -> Entry
  {
    guard !line.isEmpty else { throw refusal("it has a blank line") }
    guard line.count <= lineByteLimit else { throw refusal("it has a very long line") }
    guard line.allSatisfy({ (32...126).contains($0) }) else {
      throw refusal("it holds a byte other than printable ASCII or a line ending")
    }
    let parts = line.split(separator: 32, omittingEmptySubsequences: false)
    guard parts.count == 2, isKey(Array(parts[0])), isNumber(Array(parts[1])) else {
      throw refusal("a line is not a name and a number")
    }
    let key = String(decoding: parts[0], as: UTF8.self)
    guard key.hasPrefix("Gst") else { throw refusal("it holds the option \(key)") }
    return Entry(key: key, value: String(decoding: parts[1], as: UTF8.self), terminator: terminator)
  }

  private static func isKey(_ bytes: [UInt8]) -> Bool {
    !bytes.isEmpty && bytes.count <= 128
      && bytes.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46
      }
  }

  /// An optional minus, digits, and optionally a point and more digits: the game's `%d` and `%f`.
  private static func isNumber(_ bytes: [UInt8]) -> Bool {
    guard !bytes.isEmpty, bytes.count <= valueByteLimit else { return false }
    let digits = bytes.first == 45 ? bytes.dropFirst() : bytes[...]
    let parts = digits.split(separator: 46, omittingEmptySubsequences: false)
    return (1...2).contains(parts.count)
      && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { (48...57).contains($0) } }
  }
}
