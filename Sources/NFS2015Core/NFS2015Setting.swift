import Foundation

/// Where a page of settings sits. The experimental group is shown collapsed and labelled.
package enum NFS2015SettingGroup: String, CaseIterable, Codable, Sendable {
  case display, quality, controls, audio, experimental

  package var title: String {
    switch self {
    case .display: "Display"
    case .quality: "Quality"
    case .controls: "Controls"
    case .audio: "Audio"
    case .experimental: "Experimental"
    }
  }
}

/// How well an option is known. Every key listed was seen in the options file the installed
/// game wrote; this says what is known about the values that key may take.
package enum NFS2015SettingSource: String, Codable, Sendable {
  /// The key, its value format and the offered values were all seen in that file.
  case verified
  /// The key was seen in that file; the offered domain comes from reports or inference.
  case reported

  package var title: String {
    switch self {
    case .verified: "Verified in the game's file"
    case .reported: "Value range reported, not verified"
    }
  }
}

/// One option the app can change in the game's own options file.
///
/// A setting names the file keys it writes and the values it accepts. Nothing outside this
/// catalog is ever written, and a value outside its domain is refused rather than adjusted.
package struct NFS2015Setting: Identifiable, Sendable {
  package enum Kind: Sendable {
    case choices([Choice])
    case number(ClosedRange<Double>, decimals: Int)
    case resolution
    /// Shown as the file holds it and never written: the meaning of its values is not recorded.
    case observed
  }

  package struct Choice: Identifiable, Sendable {
    package let id: String
    package let title: String
    package init(_ id: String, _ title: String) {
      self.id = id
      self.title = title
    }
  }

  static let resolutionWidths = 640...7680
  static let resolutionHeights = 480...4320

  /// The option file keys this setting writes. A resolution writes width then height.
  package let keys: [String]
  package let id: String
  package let title: String
  package let group: NFS2015SettingGroup
  package let defaultValue: String
  package let kind: Kind
  package let help: String
  package let source: NFS2015SettingSource
  /// Whether the game must be closed to change it: the game reads the file at start and rewrites
  /// it at exit, so a change made while it runs is lost.
  package let needsGameClosed: Bool

  package init(
    _ id: String, _ title: String, _ group: NFS2015SettingGroup, _ value: String, _ kind: Kind,
    keys: [String], source: NFS2015SettingSource = .verified, needsGameClosed: Bool = true,
    help: String = ""
  ) {
    self.id = id
    self.title = title
    self.group = group
    defaultValue = value
    self.kind = kind
    self.keys = keys
    self.source = source
    self.needsGameClosed = needsGameClosed
    self.help = help
  }

  package var isExperimental: Bool { group == .experimental }

  package var isEditable: Bool {
    if case .observed = kind { return false }
    return true
  }

  /// The accepted range of a number, for display next to the control.
  package var range: ClosedRange<Double>? {
    if case .number(let range, _) = kind { return range }
    return nil
  }

  package func accepts(_ value: String) -> Bool {
    guard value.utf8.count <= 32,
      !value.contains(where: { $0.isNewline || $0 == "\"" || $0 == "\0" })
    else { return false }
    switch kind {
    case .observed: return false
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
      return Self.resolutionWidths.contains(width) && Self.resolutionHeights.contains(height)
    }
  }

  /// Whether a slider suits this setting: a number whose whole range spans at most one unit.
  package var prefersSlider: Bool {
    guard let range else { return false }
    return range.upperBound - range.lowerBound <= 1
  }

  /// The accepted range in words, for display beside the control.
  package var rangeDescription: String? {
    switch kind {
    case .number(let range, _):
      return "\(Self.plain(range.lowerBound)) to \(Self.plain(range.upperBound))"
    case .resolution:
      let widths = Self.resolutionWidths
      let heights = Self.resolutionHeights
      return
        "\(widths.lowerBound)x\(heights.lowerBound) to \(widths.upperBound)x\(heights.upperBound)"
    case .choices, .observed:
      return nil
    }
  }

  /// A value as a person reads it: `60.000000` is `60` and `0.500000` is `0.5`.
  package func displayText(_ value: String) -> String {
    guard case .number = kind, let number = Double(value), number.isFinite else { return value }
    return Self.plain(number)
  }

  private static func plain(_ number: Double) -> String {
    var text = String(format: "%.3f", number)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
  }

  /// Whether two accepted values of this setting are the same choice, however they are written.
  package func isEquivalent(_ left: String, _ right: String) -> Bool {
    ProfileOptionsDocument.isSameNumber(left, right)
  }

  /// The nearest accepted value to something a person typed or dragged, or nil when there is
  /// none: a number is held inside its range, a resolution inside the supported sizes, and a
  /// choice must already be one of the offered ones. A setting whose value is not known is
  /// never given one here.
  package func clamped(_ text: String) -> String? {
    switch kind {
    case .observed: return nil
    case .choices: return accepts(text) ? text : nil
    case .number(let range, let decimals):
      guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite
      else { return nil }
      return String(
        format: "%.\(decimals)f", min(max(number, range.lowerBound), range.upperBound))
    case .resolution:
      let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
        return nil
      }
      let fitted = (
        min(max(width, Self.resolutionWidths.lowerBound), Self.resolutionWidths.upperBound),
        min(max(height, Self.resolutionHeights.lowerBound), Self.resolutionHeights.upperBound)
      )
      return "\(fitted.0)x\(fitted.1)"
    }
  }

  /// The option file values this setting writes, in the same order as `keys`.
  package func fileValues(for value: String) -> [String]? {
    guard accepts(value) else { return nil }
    switch kind {
    case .observed: return nil
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
    case .observed:
      return nil
    case .choices:
      return accepts(present[0]) ? present[0] : nil
    case .number(_, let decimals):
      guard let number = Double(present[0]), number.isFinite else { return nil }
      let normalized = String(format: "%.\(decimals)f", number)
      return accepts(normalized) ? normalized : nil
    case .resolution:
      guard let width = Int(present[0]), let height = Int(present[1]) else { return nil }
      let combined = "\(width)x\(height)"
      return accepts(combined) ? combined : nil
    }
  }

  /// What the game wrote, as plain text, for a value this app does not offer to change.
  package func recordedText(from fileValues: [String?]) -> String? {
    let present = fileValues.compactMap { $0 }
    guard present.count == keys.count, !present.isEmpty else { return nil }
    if case .resolution = kind, present.count == 2 { return present.joined(separator: "x") }
    return present.joined(separator: " ")
  }
}
