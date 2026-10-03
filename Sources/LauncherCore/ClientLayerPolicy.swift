import Foundation

/// What a client layer may write into a prefix, and what it must never carry.
///
/// A layer holds the client's program files and the publisher's installer database. Account,
/// session and machine state is created by the client itself on the player's Mac, so every path
/// that could hold it is refused here whatever a manifest says. These rules mirror
/// `FILE_RULES` in `Packaging/client_layer.py`.
enum ClientLayerPolicy {
  /// Where a layer may write, relative to `drive_c`. Nothing else, including the game folder.
  static let roots = [
    "Program Files/Electronic Arts", "Program Files/Common Files/EAInstaller",
    "ProgramData/Package Cache", "windows/Installer",
  ]
  /// Files that only ever hold session, account or machine state, wherever they sit.
  static let forbiddenNames: Set<String> = [
    "machine.ini", "backgroundservice.ini", "cookies", "cookies.sqlite", "local state",
    "login data", "web data", "session.json", "credentials.json", "tokens.json", ".env",
    "auth.json", "state.rsm",
  ]
  static let forbiddenSuffixes = [
    ".log", ".sqlite", ".db", ".tmp", ".bak", ".pem", ".p12", ".pfx", ".reg", ".keychain", ".lnk",
    ".zip", ".7z", ".rar", ".sha256",
  ]
  /// The one configuration file the client ships: a static table that is identical in every install.
  static let allowedConfiguration = "/legacypm/eacore_app.ini"

  /// - Throws: A failure when the path is unsafe, outside every root, or names state or an archive.
  static func validate(path: String) throws(LauncherError) {
    try ManifestFile.validate(path: path)
    let lowered = path.lowercased()
    guard
      roots.contains(where: {
        lowered == $0.lowercased() || lowered.hasPrefix($0.lowercased() + "/")
      })
    else {
      throw .operation("The EA app's files name a location outside its own folders: \(path)")
    }
    let name = lowered.split(separator: "/").last.map(String.init) ?? lowered
    let isConfiguration = name.hasSuffix(".ini")
    guard !forbiddenNames.contains(name), !name.hasPrefix("user_"),
      !forbiddenSuffixes.contains(where: name.hasSuffix),
      !isConfiguration || lowered.hasSuffix(allowedConfiguration)
    else {
      throw .operation("The EA app's files name account or machine state: \(path)")
    }
  }

  private static let guid = #"\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}"#

  /// The registry keys a layer may add, per hive file, as regular expressions over the key path with
  /// single backslashes. These mirror the `keep` rules of `KEY_RULES` in `Packaging/client_layer.py`.
  private static var keyPatterns: [String: [String]] {
    let protocols = "eaconnect\\.microsoft|ealink|epic2ea|link2ea|luna2ea|origin|origin2|steam2ea"
    return [
      "system.reg": [
        #"Software\\Classes\\(?:Installer\\.*|AppID\\"# + guid + #"|CLSID\\"# + guid
          + #"(?:\\.*)?|(?:"#
          + protocols + #")(?:\\.*)?)"#,
        #"Software\\(?:Wow6432Node\\)?Electronic Arts(\\.*)?"#,
        #"Software\\Wow6432Node\\Origin"#,
        #"Software\\(?:Wow6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Uninstall\\"# + guid,
        #"Software\\Microsoft\\Windows\\CurrentVersion\\Installer\\UpgradeCodes\\[0-9A-F]{32}"#,
        #"Software\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\S-1-5-18\\"#
          + #"(?:Components|Products)\\[0-9A-F]{32}(?:\\.*)?"#,
        #"Software\\Microsoft\\Xbox\\GamingApp\\Extensions\\.*"#,
        #"System\\ControlSet001\\Services\\EABackgroundService"#,
      ],
      "user.reg": [#"Software\\Microsoft\\Xbox\\GamingApp\\Extensions\\Data\\[^\\]+"#],
    ]
  }

  /// - Throws: A failure when the hive is unknown or the key is not one a client layer may add.
  static func validate(registryKey key: String, hive: String) throws(LauncherError) {
    let allowed = (keyPatterns[hive] ?? []).contains { pattern in
      guard let expression = try? Regex(pattern) else { return false }
      return key.wholeMatch(of: expression) != nil
    }
    guard allowed else {
      throw .operation("The EA app's registry entries name a key outside its own: \(key)")
    }
  }
}
