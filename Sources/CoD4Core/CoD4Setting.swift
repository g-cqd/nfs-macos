import Foundation

/// One supported configuration field. Numeric ranges are launcher limits, not claims about engine domains.
package struct CoD4Setting: Identifiable, Sendable {
  package enum Kind: Sendable {
    case choices([Choice])
    case number(ClosedRange<Double>)
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
  package let id: String
  package let title: String
  package let group: String
  package let defaultValue: String
  package let kind: Kind
  package let help: String
  package let campaignOnly: Bool
  package var isRenderer: Bool { id == "render.scale" || id == "shader.asyncCompile" }

  package init(
    _ id: String, _ title: String, _ group: String, _ value: String,
    _ kind: Kind, help: String = "", campaignOnly: Bool = false
  ) {
    self.id = id
    self.title = title
    self.group = group
    defaultValue = value
    self.kind = kind
    self.help = help
    self.campaignOnly = campaignOnly
  }

  package func accepts(_ value: String) -> Bool {
    guard value.utf8.count <= 64,
      !value.contains(where: { $0.isNewline || $0 == "\"" || $0 == ";" || $0 == "\0" })
    else { return false }
    switch kind {
    case .choices(let choices): return choices.contains { $0.id == value }
    case .number(let range):
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
}
