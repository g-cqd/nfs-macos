import Foundation

/// One regular game file and its expected size and SHA-256 digest.
package struct ManifestFile: Codable {
  let path: String
  let size: Int
  let sha256: String

  static func validate(path: String) throws(LauncherError) {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, path.utf8.count <= 512, !path.contains("\\"),
      !path.unicodeScalars.contains(where: { $0.value < 32 }),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw .operation("The game manifest contains an unsafe file path.")
    }
  }
  private static let accountFolders: Set<String> = [
    "electronic arts", "ea desktop", "origin", "appdata", "programdata", "users", "documents",
    "saves", "savegames", "logs", "cache", "crashdumps",
  ]
  private static let accountNames: Set<String> = [
    "machine.ini", "user.reg", "system.reg", "userdef.reg", "cookies", "cookies.sqlite",
    "local state", "login data", "web data", "session.json", "credentials.json", "tokens.json",
    ".env", "auth.json",
  ]
  private static let accountSuffixes = [
    ".zip", ".7z", ".rar", ".sha256", ".log", ".dxvk-cache", ".sqlite", ".db", ".reg", ".tmp",
    ".bak", ".pem", ".p12", ".pfx", ".keychain",
  ]

  /// Whether a path names account, session, machine or user-profile state, or an archive.
  ///
  /// A store-client game stays activated by the player's own account, so an app that ships the
  /// game's files must never ship any of this. The packager and the audit refuse the same names;
  /// checking again here keeps a hand-edited manifest from seeding them into a player's prefix.
  static func isAccountState(path: String) -> Bool {
    let parts = path.lowercased().split(separator: "/").map(String.init)
    guard let name = parts.last else { return false }
    return parts.dropLast().contains(where: accountFolders.contains)
      || accountNames.contains(name) || name.hasPrefix("profileoptions")
      || accountSuffixes.contains(where: name.hasSuffix)
  }
}
