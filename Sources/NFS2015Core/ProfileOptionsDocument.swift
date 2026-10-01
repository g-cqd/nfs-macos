import Foundation
import LauncherCore

/// Edits the game's own options file in place, one line at a time.
///
/// The file this game writes beside its saves is a flat list of `Key Value` lines in ASCII,
/// terminated by line feeds. The document never re-serializes it: it replaces only the values
/// it is asked for, on the lines that already carry those keys, and leaves every other line,
/// its order and the file's terminator exactly as the game wrote them. A key the game has not
/// written is reported rather than invented, because an unknown key's domain is unknown.
package struct ProfileOptionsDocument {
  /// The options file this game writes is a few hundred short lines.
  package static let byteLimit = 262_144
  static let lineLimit = 4096

  private let lines: [String]
  private let terminated: Bool

  /// - Throws: A failure for input this editor cannot round-trip byte for byte.
  package init(text: String) throws(LauncherError) {
    guard text.utf8.count <= Self.byteLimit else {
      throw .operation("The game's options file is larger than this app supports.")
    }
    guard text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else {
      throw .operation("The game's options file contains bytes this app will not rewrite.")
    }
    terminated = text.hasSuffix("\n")
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if terminated, lines.last == "" { lines.removeLast() }
    guard lines.count <= Self.lineLimit else {
      throw .operation("The game's options file has more lines than this app supports.")
    }
    guard lines.allSatisfy({ $0.utf8.count <= 512 }) else {
      throw .operation("The game's options file has a line longer than this app supports.")
    }
    self.lines = lines
  }

  /// The value recorded for a key, or nil when the game has not written that key.
  package func value(_ key: String) -> String? {
    for line in lines {
      guard let separator = line.firstIndex(of: " "),
        String(line[line.startIndex..<separator]) == key
      else { continue }
      return String(line[line.index(after: separator)...])
    }
    return nil
  }

  /// Every key the game has written, in file order.
  package var keys: [String] {
    lines.compactMap { line in
      guard let separator = line.firstIndex(of: " ") else { return nil }
      let key = String(line[line.startIndex..<separator])
      return key.isEmpty ? nil : key
    }
  }

  /// Replaces the values for the given keys and returns the complete file text.
  /// - Throws: A failure when a key is absent, duplicated, or its value is not a plain number.
  /// - Complexity: O(file length + number of replacements).
  package func applying(_ replacements: [String: String]) throws(LauncherError) -> String {
    guard replacements.count <= 256 else {
      throw .operation("Too many option changes in one update.")
    }
    for (key, value) in replacements {
      guard !key.isEmpty, key.utf8.count <= 128,
        key.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || $0 == 46
            || (97...122).contains($0)
        })
      else {
        throw .operation("Unsupported option name: \(key)")
      }
      guard !value.isEmpty, value.utf8.count <= 32,
        value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 || $0 == 45 }),
        Double(value)?.isFinite == true
      else {
        throw .operation("Option \(key) must be set to a plain number.")
      }
    }
    var remaining = Set(replacements.keys)
    var output: [String] = []
    output.reserveCapacity(lines.count)
    for line in lines {
      guard let separator = line.firstIndex(of: " ") else {
        output.append(line)
        continue
      }
      let key = String(line[line.startIndex..<separator])
      guard let value = replacements[key] else {
        output.append(line)
        continue
      }
      guard remaining.remove(key) != nil else {
        throw .operation("The game's options file records \(key) more than once.")
      }
      output.append(key + " " + value)
    }
    guard remaining.isEmpty else {
      throw .operation(
        """
        The game has not written \(remaining.sorted().joined(separator: ", ")) yet. Start the \
        game once, change that option in its own menu, and quit; then this app can manage it.
        """)
    }
    return output.joined(separator: "\n") + (terminated ? "\n" : "")
  }
}
