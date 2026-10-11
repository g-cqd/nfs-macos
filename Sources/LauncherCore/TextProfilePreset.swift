import CoreGraphics
import Foundation

/// A named set of values for a game's own plain-text settings profile (`Key value` lines).
///
/// Battlefield 3 keeps its settings in `PROF_SAVE_profile`, one `Key value` pair per line, and
/// rewrites the file when it exits; so a preset is applied only while the game is not running,
/// it replaces existing lines only (the game writes every key on its first exit), and the
/// previous file is kept beside it.
package struct TextProfilePreset: Codable, Equatable, Sendable {
  package struct Value: Codable, Equatable, Sendable {
    package let key: String
    /// The value, or `{display.width}`, `{display.height}`, `{display.refresh}` (whole hertz) or
    /// `{display.refresh.float}` (the same as `60.000000`).
    package let value: String

    package init(key: String, value: String) {
      self.key = key
      self.value = value
    }
  }

  /// The pixel size and refresh rate of the main display.
  package struct Display: Equatable, Sendable {
    package let width: Int
    package let height: Int
    package let refresh: Int

    package init(width: Int, height: Int, refresh: Int) {
      self.width = width
      self.height = height
      self.refresh = refresh
    }

    /// The main display's current mode in pixels, the desktop the game's full-screen mode
    /// matches, with a refresh rate that is never below 60.
    package static func main() -> Display {
      let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
      return Display(
        width: mode?.pixelWidth ?? 1920, height: mode?.pixelHeight ?? 1200,
        refresh: max(60, Int((mode?.refreshRate ?? 0).rounded())))
    }
  }

  package let name: String
  package let title: String
  package let values: [Value]
  /// What is known about it: measured, or untested and why it is offered.
  package let reason: String

  package init(name: String, title: String, values: [Value], reason: String) {
    self.name = name
    self.title = title
    self.values = values
    self.reason = reason
  }

  static let placeholders = [
    "{display.width}", "{display.height}", "{display.refresh}", "{display.refresh.float}",
  ]

  package func validate() throws(LauncherError) {
    guard (1...32).contains(name.utf8.count),
      name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
      (1...64).contains(title.utf8.count), (1...64).contains(values.count),
      (1...300).contains(reason.utf8.count),
      !reason.unicodeScalars.contains(where: { $0.value < 32 })
    else {
      throw .operation("A settings preset needs a plain name, a title, values and a reason.")
    }
    var keys = Set<String>()
    for value in values {
      guard (1...96).contains(value.key.utf8.count),
        value.key.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46
            || $0 == 95
        }),
        keys.insert(value.key).inserted,
        Self.placeholders.contains(value.value)
          || ((1...32).contains(value.value.utf8.count)
            && value.value.utf8.allSatisfy({
              (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 46 || $0 == 45
            }))
      else {
        throw .operation("Preset \(name) has an unusable value for \(value.key).")
      }
    }
  }

  /// The values with the display placeholders resolved.
  package func resolved(for display: Display) -> [Value] {
    values.map { item in
      let value =
        switch item.value {
        case "{display.width}": String(display.width)
        case "{display.height}": String(display.height)
        case "{display.refresh}": String(display.refresh)
        case "{display.refresh.float}": String(format: "%.6f", Double(display.refresh))
        default: item.value
        }
      return Value(key: item.key, value: value)
    }
  }

  /// The profile text with each listed key's line replaced, and the keys the text did not have.
  ///
  /// A line is the key, one space and the value, exactly as the game writes it; any other line,
  /// and the line endings, are kept byte for byte.
  package func apply(to text: String, display: Display) -> (text: String, missing: [String]) {
    let values = resolved(for: display)
    var pending = Dictionary(values.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
    var lines = text.components(separatedBy: "\n")
    for index in lines.indices {
      let line = lines[index]
      guard let space = line.firstIndex(of: " ") else { continue }
      let key = String(line[..<space])
      guard let value = pending[key] else { continue }
      let ending = line.hasSuffix("\r") ? "\r" : ""
      lines[index] = key + " " + value + ending
      pending[key] = nil
    }
    let missing = values.map(\.key).filter { pending[$0] != nil }
    return (lines.joined(separator: "\n"), missing)
  }

  /// The lines of the profile that name one of these keys, for showing the current state.
  package static func lines(in text: String, keys: [String]) -> [String] {
    let wanted = Set(keys)
    return text.components(separatedBy: "\n").compactMap { line in
      guard let space = line.firstIndex(of: " "), wanted.contains(String(line[..<space])) else {
        return nil
      }
      return line.trimmingCharacters(in: .newlines)
    }
  }
}
