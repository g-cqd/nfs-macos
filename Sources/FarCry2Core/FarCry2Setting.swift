import Foundation

/// One option the starter can change. Profile attribute names and value domains come from the
/// `GamerProfile.xml` the game itself wrote on first launch and from strings in `Dunia.dll`.
package struct FarCry2Setting: Identifiable, Sendable {
  package enum Kind: Sendable {
    case choices([Choice])
    case resolution
    case integer(ClosedRange<Int>)
    case decimal(ClosedRange<Double>)
  }

  package struct Choice: Identifiable, Sendable {
    package let id: String
    package let title: String
    package init(_ id: String, _ title: String) {
      self.id = id
      self.title = title
    }
  }

  /// Where an option lives. Game options are XML attributes, renderer options are `mtld3d.conf` keys,
  /// Wine options are values of the prefix's `Mac Driver` registry key, and launcher options are
  /// kept by the starter and turned into environment, arguments or a console script at launch.
  package enum Storage: Sendable {
    case profile([GamerProfileDocument.Target])
    case renderer
    case registry(String)
    case launcher
  }

  /// How a launcher option reaches the game.
  package enum Launch: Sendable, Equatable {
    case none
    /// Sets an environment variable to the option's value.
    case environment(String)
    /// Adds a command-line switch when the option is `1`.
    case argument(String)
    /// Adds one console line when the option differs from its default; `{value}` is replaced.
    case console(String)
  }

  package let id: String
  package let title: String
  package let group: String
  package let defaultValue: String
  package let kind: Kind
  package let storage: Storage
  package let launch: Launch
  package let help: String
  package var isRenderer: Bool {
    if case .renderer = storage { return true }
    return false
  }
  package var isLauncher: Bool {
    if case .launcher = storage { return true }
    return false
  }
  package var registryName: String? {
    if case .registry(let name) = storage { return name }
    return nil
  }

  package init(
    _ id: String, _ title: String, _ group: String, _ value: String, _ kind: Kind,
    storage: Storage, launch: Launch = .none, help: String = ""
  ) {
    self.id = id
    self.title = title
    self.group = group
    defaultValue = value
    self.kind = kind
    self.storage = storage
    self.launch = launch
    self.help = help
  }

  /// A number in the form `accepts` and the defaults use: no trailing zeros, `-1` rather than `-1.00`.
  package static func canonical(_ number: Double) -> String {
    var text = String(format: "%.2f", number)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
  }

  /// Whether `chosen` is the option's default, comparing numbers by value.
  package func isDefault(_ chosen: String) -> Bool {
    switch kind {
    case .integer, .decimal:
      if let left = Double(chosen), let right = Double(defaultValue) { return left == right }
      return chosen == defaultValue
    default: return chosen == defaultValue
    }
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
    case .integer(let range):
      guard let number = Int(value), value == String(number) else { return false }
      return range.contains(number)
    case .decimal(let range):
      guard value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 45 }),
        let number = Double(value), number.isFinite
      else { return false }
      return range.contains(number)
    }
  }
}
