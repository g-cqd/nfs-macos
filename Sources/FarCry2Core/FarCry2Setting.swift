import Foundation

/// One option the starter can change. Value domains are the starter's limits, taken from public
/// reports of the game's own `GamerProfile.xml`; they are not claims about the engine's full range.
package struct FarCry2Setting: Identifiable, Sendable {
  package enum Kind: Sendable {
    case choices([Choice])
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

  /// Where an option lives. Game options are XML attributes; renderer options are `mtld3d.conf` keys.
  package enum Storage: Sendable {
    case profile([GamerProfileDocument.Target])
    case renderer
  }

  package let id: String
  package let title: String
  package let group: String
  package let defaultValue: String
  package let kind: Kind
  package let storage: Storage
  package let help: String
  package var isRenderer: Bool {
    if case .renderer = storage { return true }
    return false
  }

  package init(
    _ id: String, _ title: String, _ group: String, _ value: String, _ kind: Kind,
    storage: Storage, help: String = ""
  ) {
    self.id = id
    self.title = title
    self.group = group
    defaultValue = value
    self.kind = kind
    self.storage = storage
    self.help = help
  }

  package func accepts(_ value: String) -> Bool {
    guard value.utf8.count <= 32,
      !value.contains(where: { $0.isNewline || $0 == "\"" || $0 == ";" || $0 == "\0" })
    else { return false }
    switch kind {
    case .choices(let choices): return choices.contains { $0.id == value }
    case .resolution:
      let parts = value.split(separator: "x", omittingEmptySubsequences: false)
      guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
        value == "\(width)x\(height)"
      else { return false }
      return (640...7680).contains(width) && (480...4320).contains(height)
    }
  }
}
