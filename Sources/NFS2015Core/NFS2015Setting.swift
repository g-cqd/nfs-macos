import Foundation

/// One option the starter can change in the game's own options file.
///
/// Value domains are this app's limits. Each one is taken from the keys and values the
/// installed game actually wrote; a key whose domain is not established is left to the game's
/// own menu rather than guessed at here.
package struct NFS2015Setting: Identifiable, Sendable {
  package enum Kind: Sendable {
    case choices([Choice])
    case number(ClosedRange<Double>, decimals: Int)
    case resolution
  }

  package struct Choice: Identifiable, Sendable {
    package let id: String
    package let title: String
    package init(_ id: String, _ title: String) {
      self.id = id
      self.title = title
    }
  }

  /// The option file keys this setting writes. A resolution writes width then height.
  package let keys: [String]
  package let id: String
  package let title: String
  package let group: String
  package let defaultValue: String
  package let kind: Kind
  package let help: String

  package init(
    _ id: String, _ title: String, _ group: String, _ value: String, _ kind: Kind,
    keys: [String], help: String = ""
  ) {
    self.id = id
    self.title = title
    self.group = group
    defaultValue = value
    self.kind = kind
    self.keys = keys
    self.help = help
  }

  package func accepts(_ value: String) -> Bool {
    guard value.utf8.count <= 32,
      !value.contains(where: { $0.isNewline || $0 == "\"" || $0 == "\0" })
    else { return false }
    switch kind {
    case .choices(let choices): return choices.contains { $0.id == value }
    case .number(let range, _):
      guard !value.isEmpty,
        value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 || $0 == 45 }),
        let number = Double(value), number.isFinite
      else { return false }
      return range.contains(number)
    case .resolution:
      let parts = value.split(separator: "x", omittingEmptySubsequences: false)
      guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
        value == "\(width)x\(height)"
      else { return false }
      return (640...7680).contains(width) && (480...4320).contains(height)
    }
  }

  /// The option file values this setting writes, in the same order as `keys`.
  package func fileValues(for value: String) -> [String]? {
    guard accepts(value) else { return nil }
    switch kind {
    case .choices: return [value]
    case .number(_, let decimals):
      guard let number = Double(value) else { return nil }
      return [String(format: "%.\(decimals)f", number)]
    case .resolution:
      let parts = value.split(separator: "x").map(String.init)
      guard parts.count == 2 else { return nil }
      return parts
    }
  }

  /// Reads this setting back from the values the game wrote, or nil when they are unusable.
  package func value(from fileValues: [String?]) -> String? {
    guard fileValues.count == keys.count else { return nil }
    let present = fileValues.compactMap { $0 }
    guard present.count == keys.count else { return nil }
    switch kind {
    case .choices:
      return accepts(present[0]) ? present[0] : nil
    case .number(_, let decimals):
      guard let number = Double(present[0]) else { return nil }
      let normalized =
        decimals == 0 ? String(Int(number.rounded())) : String(format: "%.\(decimals)f", number)
      return accepts(normalized) ? normalized : nil
    case .resolution:
      guard let width = Int(present[0]), let height = Int(present[1]) else { return nil }
      let combined = "\(width)x\(height)"
      return accepts(combined) ? combined : nil
    }
  }
}
