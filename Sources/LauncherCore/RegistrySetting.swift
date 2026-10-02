import Foundation

/// One registry value a game needs in its Windows prefix, declared by the recipe.
///
/// A bundle that owns its prefix imports these once through `Defaults/settings.reg`. A bundle
/// that references the player's own prefix cannot: it never runs `wineboot`. These entries let
/// such a recipe name exactly the values it needs, so the app can check whether they are
/// already recorded and import only what is missing.
package struct RegistrySetting: Codable, Equatable, Sendable {
  package enum Hive: String, Codable, Sendable {
    case currentUser = "HKEY_CURRENT_USER"
    case localMachine = "HKEY_LOCAL_MACHINE"

    /// Wine keeps each hive in its own text file at the root of the prefix.
    package var file: String { self == .currentUser ? "user.reg" : "system.reg" }
  }

  /// `windowsPath` is a guest folder such as `C:\Program Files\Game\`: it keeps its single
  /// backslashes in the manifest and is written with doubled ones, as a `.reg` file requires.
  package enum Kind: String, Codable, Sendable { case string, dword, windowsPath }

  package let hive: Hive
  /// The key path below the hive, with single backslashes, as a `.reg` file writes it.
  package let path: String
  package let name: String
  package let value: String
  package let kind: Kind
  /// Why this value is needed, carried into the session log rather than lost in a commit.
  package let reason: String

  package init(
    hive: Hive, path: String, name: String, value: String, kind: Kind, reason: String = ""
  ) {
    self.hive = hive
    self.path = path
    self.name = name
    self.value = value
    self.kind = kind
    self.reason = reason
  }

  /// Rejects anything that could inject a second key, value or line into a `.reg` script.
  package func validate() throws(LauncherError) {
    func plain(_ text: String, limit: Int) -> Bool {
      !text.isEmpty && text.utf8.count <= limit
        && text.utf8.allSatisfy { (32...126).contains($0) && $0 != 34 && $0 != 91 && $0 != 93 }
    }
    guard plain(path, limit: 256), !path.hasPrefix("\\"), !path.hasSuffix("\\"),
      !path.contains("\\\\"), plain(name, limit: 128), !name.contains("\\")
    else {
      throw .operation("The bundle declares an unusable registry location.")
    }
    switch kind {
    case .string:
      guard plain(value, limit: 256), !value.contains("\\") else {
        throw .operation("The bundle declares an unusable registry value: \(name)")
      }
    case .windowsPath:
      guard Self.isWindowsPath(value) else {
        throw .operation("The bundle declares an unusable registry path: \(name)")
      }
    case .dword:
      guard (1...8).contains(value.utf8.count),
        value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else {
        throw .operation("A registry number must be lowercase hexadecimal: \(name)")
      }
    }
    guard reason.utf8.count <= 200, !reason.unicodeScalars.contains(where: { $0.value < 32 }) else {
      throw .operation("The bundle declares an overlong registry reason.")
    }
  }

  /// A drive-letter path of plain folder names, with no traversal and nothing a `.reg` line could misread.
  static func isWindowsPath(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard (4...256).contains(bytes.count), bytes[1] == 58, bytes[2] == 92,
      (65...90).contains(bytes[0]) || (97...122).contains(bytes[0])
    else { return false }
    let folders = value.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
    // One empty element is the trailing separator; any other empty element is a doubled one.
    let named = folders.last == "" ? folders.dropLast() : folders[...]
    return !named.isEmpty
      && named.allSatisfy { folder in
        !folder.isEmpty && folder != "." && folder != ".."
          && folder.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              || [32, 40, 41, 45, 46, 95].contains($0)
          }
      }
  }

  /// The entry as it appears inside a `.reg` script.
  var entry: String {
    switch kind {
    case .string: "\"\(name)\"=\"\(value)\""
    case .windowsPath: "\"\(name)\"=\"\(value.replacingOccurrences(of: "\\", with: "\\\\"))\""
    case .dword: "\"\(name)\"=dword:\(zeroPadded)"
    }
  }

  private var zeroPadded: String { String(repeating: "0", count: 8 - value.count) + value }

  /// The section header Wine writes in `user.reg` and `system.reg`, which doubles backslashes.
  var section: String { "[" + path.replacingOccurrences(of: "\\", with: "\\\\") + "]" }

  /// Whether this exact value is already recorded in a hive file's text.
  ///
  /// Reading the hive avoids starting Wine in a prefix the app does not own when there is
  /// nothing to change.
  package func isRecorded(in hive: String) -> Bool {
    var inSection = false
    for line in hive.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("[") {
        // Wine appends a modification time after the section header.
        inSection = text == section || text.hasPrefix(section + " ")
        continue
      }
      if inSection, text == entry { return true }
    }
    return false
  }

  /// A script importing exactly the given settings, or nil when there is nothing to import.
  package static func script(_ settings: [RegistrySetting]) throws(LauncherError) -> String? {
    guard !settings.isEmpty else { return nil }
    guard settings.count <= 64 else {
      throw .operation("The bundle declares too many registry values.")
    }
    for setting in settings { try setting.validate() }
    var text = "REGEDIT4\n"
    for group in Dictionary(grouping: settings, by: { "\($0.hive.rawValue)\\\($0.path)" }).keys
      .sorted()
    {
      text += "\n[\(group)]\n"
      for setting in settings
      where "\(setting.hive.rawValue)\\\(setting.path)" == group {
        text += setting.entry + "\n"
      }
    }
    return text
  }
}
