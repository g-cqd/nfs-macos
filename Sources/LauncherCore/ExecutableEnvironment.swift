import Foundation

/// Environment variables that reach one Windows program and no other.
///
/// The runtime's per-process compatibility rules can carry `env=NAME=value` entries, and the
/// runtime applies them to a process only when its image name matches the rule. That is how a
/// game gets a setting its store client, and the client's browser helpers, never see: putting
/// the same variable in the launch environment would reach every Windows process of the prefix.
///
/// Values are restricted to plain printable text without the two characters the rule format
/// escapes, so a value can never end its own rule or start another one.
package struct ExecutableEnvironment: Equatable, Sendable {
  package struct Entry: Equatable, Sendable {
    package let name: String
    package let value: String

    package init(name: String, value: String) {
      self.name = name
      self.value = value
    }
  }

  /// Variables that decide how Wine itself loads or finds things, which no per-program rule may set.
  static let reservedPrefixes = ["WINE", "DYLD_", "LD_", "ROSETTA", "MTL_"]
  static let reservedNames = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]

  package let executable: String
  package let entries: [Entry]

  package init(executable: String, entries: [Entry]) {
    self.executable = executable
    self.entries = entries
  }

  package func validate() throws(LauncherError) {
    guard RendererSelection.isExecutableName(executable) else {
      throw .operation("An environment rule applies to one Windows executable: \(executable)")
    }
    guard (1...8).contains(entries.count) else {
      throw .operation("An environment rule needs between one and eight variables.")
    }
    var seen: Set<String> = []
    for entry in entries {
      guard Self.isPlainName(entry.name), !Self.isReserved(entry.name) else {
        throw .operation("A per-program environment variable cannot be named \(entry.name).")
      }
      guard seen.insert(entry.name).inserted else {
        throw .operation("The environment variable \(entry.name) is set twice.")
      }
      guard (1...200).contains(entry.value.utf8.count),
        entry.value.utf8.allSatisfy({ (32...126).contains($0) && $0 != 59 && $0 != 37 })
      else {
        throw .operation("The environment variable \(entry.name) has an unusable value.")
      }
    }
  }

  /// The `;env=NAME=value` fields of one rule record, in entry order.
  var fields: String {
    entries.map { ";env=\($0.name)=\($0.value)" }.joined()
  }

  /// A rule record that holds only this environment, for an executable with no other rule.
  func record(name: String) -> String {
    "name=\(name);exe=\(executable)\(fields)"
  }

  /// Adds each environment to the rule lines, validated, at most one environment per program.
  ///
  /// `lines[0]` is the table header, and line `index + 1` belongs to `selections[index]`.
  static func attach(
    _ environments: [Self], to lines: inout [String], selections: [RendererSelection],
    kind: GameKind
  ) throws(LauncherError) {
    var programs: Set<String> = []
    for environment in environments {
      try environment.validate()
      guard programs.insert(environment.executable.lowercased()).inserted else {
        throw .operation("\(environment.executable) has two environment rules.")
      }
      let own = selections.firstIndex {
        $0.executable?.lowercased() == environment.executable.lowercased()
      }
      if let own {
        lines[own + 1] += environment.fields
      } else {
        lines.append(environment.record(name: "\(kind.rawValue)-environment-\(programs.count)"))
      }
    }
  }

  private static func isPlainName(_ name: String) -> Bool {
    guard (1...64).contains(name.utf8.count), let first = name.utf8.first,
      (65...90).contains(first)
    else { return false }
    return name.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }
  }

  private static func isReserved(_ name: String) -> Bool {
    reservedNames.contains(name) || reservedPrefixes.contains { name.hasPrefix($0) }
  }
}
