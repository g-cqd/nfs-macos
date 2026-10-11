import Foundation

/// Scans for platform and launcher markers in a game folder.
package enum FolderMarkers {
  /// Known markers (exact strings, never modified) with their canonical hints.
  package static let known: [(marker: String, hint: String)] = [
    ("__Installer/installerdata.xml", "ea"),
    ("steam_api.dll", "steam"),
    ("steam_api64.dll", "steam"),
    ("steam_appid.txt", "steam"),
    ("EOSSDK-Win64-Shipping.dll", "epic"),
    ("EOSSDK-Win32-Shipping.dll", "epic"),
    (".egstore", "epic"),
    ("uplay_r1_loader.dll", "ubisoft"),
    ("uplay_r1_loader64.dll", "ubisoft"),
    ("upc_r2_loader64.dll", "ubisoft"),
    ("uplay_r2_loader64.dll", "ubisoft"),
    ("PnkBstrA.exe", "punkbuster"),
    ("EasyAntiCheat", "anticheat"),
    ("BattlEye", "anticheat"),
  ]

  private struct DirIndex { let entries: [String: URL] }

  private static func index(_ dir: URL, budget: inout Int) -> DirIndex? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
    var map: [String: URL] = [:]
    for name in names.prefix(4096) { guard budget > 0 else { break }; budget -= 1
      let key = name.lowercased(); if map[key] == nil { map[key] = dir.appendingPathComponent(name) } }
    return DirIndex(entries: map)
  }

  private static func isReal(_ url: URL, directory: Bool?) -> Bool {
    var st = stat(); guard lstat(url.path, &st) == 0 else { return false }
    let type = st.st_mode & S_IFMT; if type == S_IFLNK { return false }
    if let d = directory { return d ? type == S_IFDIR : type != S_IFDIR }; return true
  }

  private static func matches(_ marker: String, in idx: DirIndex, budget: inout Int) -> Bool {
    let parts = marker.split(separator: "/").map { $0.lowercased() }
    guard let first = idx.entries[parts[0]] else { return false }
    if parts.count == 1 { return isReal(first, directory: nil) }
    guard isReal(first, directory: true), let sub = index(first, budget: &budget), let leaf = sub.entries[parts[1]] else { return false }
    return isReal(leaf, directory: nil)
  }

  /// Scans a folder for known markers.
  ///
  /// Returns the canonical marker strings found directly under `root` or under
  /// any immediate subdirectory of `root` (at most 256 examined). Does not follow symlinks.
  ///
  /// - Parameter root: The root folder to scan.
  /// - Returns: A set of canonical marker strings found.
  package static func scan(root: URL) -> Set<String> {
    var budget = 4096 * 257; var found = Set<String>()
    guard let rootIdx = index(root, budget: &budget) else { return found }
    for m in known where matches(m.marker, in: rootIdx, budget: &budget) { found.insert(m.marker) }
    var dirs = 0
    for url in rootIdx.entries.values.sorted(by: { $0.path < $1.path }) {
      guard dirs < 256, budget > 0 else { break }
      guard isReal(url, directory: true) else { continue }; dirs += 1
      guard let sub = index(url, budget: &budget) else { continue }
      for m in known where !found.contains(m.marker) && matches(m.marker, in: sub, budget: &budget) { found.insert(m.marker) }
    }
    return found
  }
}
