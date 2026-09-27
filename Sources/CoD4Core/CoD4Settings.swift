import Foundation
import LauncherCore

/// Validated, portable settings. Unknown engine lines and campaign data remain in the original config.
package struct CoD4Settings: Codable, Equatable, Sendable {
  package var values: [String: String]
  /// Explicit key overrides; keys absent from this dictionary retain their original game binding.
  package var bindings: [String: String]

  package init() {
    values = [:]
    bindings = [:]
  }

  /// Reads only supported fields; authentication, progress, and arbitrary console commands are excluded.
  /// - Throws: `LauncherError` for oversized input or invalid managed settings.
  package init(config: String) throws(LauncherError) {
    self.init()
    try Self.checkText(config)
    let definitions = Dictionary(
      uniqueKeysWithValues: CoD4Catalog.settings.map { ($0.id.lowercased(), $0) })
    for line in config.components(separatedBy: .newlines) {
      guard let entry = Self.entry(line) else { continue }
      if ["set", "seta"].contains(entry.command),
        let definition = definitions[entry.key.lowercased()], !definition.isRenderer
      {
        // An engine can serialize values outside the starter's offered choices. Preserve those lines
        // until the user explicitly selects a replacement rather than importing an invalid setup.
        if definition.accepts(entry.value) { values[definition.id] = entry.value }
      } else if entry.command == "bind",
        CoD4Bindings.accepts(key: entry.key.uppercased(), command: entry.value)
      {
        bindings[entry.key.uppercased()] = entry.value
      }
    }
    try validate()
  }

  package func value(_ id: String) -> String {
    values[id] ?? CoD4Catalog.setting(id)?.defaultValue ?? ""
  }

  /// Rejects unknown fields, injected commands, unsupported options, and inconsistent filter limits.
  package func validate() throws(LauncherError) {
    guard values.count <= CoD4Catalog.settings.count, bindings.count <= CoD4Bindings.keys.count
    else {
      throw .operation("The setup contains too many settings or bindings.")
    }
    for (id, value) in values {
      guard let definition = CoD4Catalog.setting(id), definition.accepts(value) else {
        throw .operation("The setup contains an unsupported setting value.")
      }
    }
    for (key, command) in bindings where !CoD4Bindings.accepts(key: key, command: command) {
      throw .operation("The setup contains an unsupported keyboard binding.")
    }
    guard let minimum = Int(value("r_texFilterAnisoMin")),
      let maximum = Int(value("r_texFilterAnisoMax")), minimum <= maximum
    else {
      throw .operation("Minimum anisotropy must not exceed maximum anisotropy.")
    }
  }

  /// Replaces managed assignments and explicit bindings once, preserving unrelated lines and progress.
  /// - Complexity: O(input length + number of settings and bindings).
  package func applying(to original: String, mode: CoD4Mode) throws(LauncherError) -> String {
    try validate()
    try Self.checkText(original)
    let fields = CoD4Catalog.settings.filter {
      !$0.isRenderer && (mode == .singlePlayer || !$0.campaignOnly)
    }
    let definitions = Dictionary(uniqueKeysWithValues: fields.map { ($0.id.lowercased(), $0) })
    var remaining = Set(fields.map(\.id))
    var remainingBindings = Set(bindings.keys)
    var output: [String] = []
    let lines = original.replacingOccurrences(of: "\r\n", with: "\n").split(
      separator: "\n", omittingEmptySubsequences: false)
    output.reserveCapacity(lines.count + fields.count + bindings.count)
    for (index, raw) in lines.enumerated() {
      let line = String(raw)
      if index == lines.count - 1 && line.isEmpty { continue }
      if let entry = Self.entry(line), ["set", "seta"].contains(entry.command),
        let definition = definitions[entry.key.lowercased()]
      {
        if remaining.remove(definition.id) != nil {
          output.append("seta \(definition.id) \"\(value(definition.id))\"")
        }
      } else if let entry = Self.entry(line), entry.command == "bind",
        let binding = bindings[entry.key.uppercased()]
      {
        if remainingBindings.remove(entry.key.uppercased()) != nil {
          output.append("bind \(entry.key.uppercased()) \"\(binding)\"")
        }
      } else {
        output.append(line)
      }
    }
    for definition in fields where remaining.contains(definition.id) {
      output.append("seta \(definition.id) \"\(value(definition.id))\"")
    }
    for key in remainingBindings.sorted() {
      output.append("bind \(key) \"\(bindings[key] ?? "")\"")
    }
    return output.joined(separator: "\n") + "\n"
  }

  /// Updates only renderer-owned settings while retaining other mtld3d configuration.
  package func rendererConfig(original: String) throws(LauncherError) -> String {
    try validate()
    var config = try ConfigText(original)
    for definition in CoD4Catalog.settings where definition.isRenderer {
      config.set(section: "", key: definition.id, value: value(definition.id))
    }
    return config.text
  }

  /// Applies the retained maximum-quality graphics preset. Sound, gameplay preferences and bindings remain unchanged.
  /// - Note: `validate()` rejects dimensions outside the starter's supported range before writing.
  package mutating func maximumQuality(width: Int, height: Int) {
    for definition in CoD4Catalog.settings
    where CoD4Catalog.graphicsGroups.contains(definition.group) {
      values[definition.id] = definition.defaultValue
    }
    values["r_mode"] = "\(width)x\(height)"
  }

  private static func checkText(_ text: String) throws(LauncherError) {
    guard text.utf8.count <= 1_048_576, !text.contains("\0") else {
      throw .operation("The game configuration is invalid or larger than 1 MiB.")
    }
  }

  private static func entry(_ line: String) -> (command: String, key: String, value: String)? {
    let parts = line.trimmingCharacters(in: .whitespaces).split(
      maxSplits: 2, whereSeparator: \.isWhitespace)
    guard parts.count == 3 else { return nil }
    let command = parts[0].lowercased()
    guard ["set", "seta", "bind"].contains(command) else { return nil }
    var key = String(parts[1])
    if key.hasPrefix("\""), key.hasSuffix("\"") {
      key.removeFirst()
      key.removeLast()
    }
    let raw = parts[2].trimmingCharacters(in: .whitespaces)
    if raw.hasPrefix("\"") {
      let contents = raw.dropFirst()
      guard let end = contents.firstIndex(of: "\"") else { return nil }
      let trailing = contents[contents.index(after: end)...].trimmingCharacters(in: .whitespaces)
      guard trailing.isEmpty || trailing.hasPrefix("//") else { return nil }
      return (command, key, String(contents[..<end]))
    }
    guard !raw.contains(";") else { return nil }
    return (command, key, raw)
  }
}
