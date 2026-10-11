import Foundation

/// Finds executable files in a folder tree.
package enum ExecutableFinder {
  /// Finds `.exe` files up to 3 directories below the root (root/1/2/3/x.exe is included, root/1/2/3/4/x.exe is not), filtering out known installer and tools.
  ///
  /// Returns regular files with extension `.exe` (case-insensitive), excluding:
  /// - Names (case-insensitive) matching prefix `unins`, containing `setup`, `vcredist`, `dxsetup`,
  ///   `crashreport`, `easyanticheat`, `battleye`, `activation`, `touchup`.
  /// - Directories that are symlinks (not descended).
  ///
  /// Results are sorted by file size (descending) then by path.
  ///
  /// - Parameters:
  ///   - root: The root folder to search.
  ///   - limit: Maximum number of results (default 64).
  /// - Returns: An array of URLs to executable files, sorted by size descending then path.
  package static func candidates(root: URL, limit: Int = 64) -> [URL] {
    var results: [(url: URL, size: Int64)] = []
    var visited = 0

    enumerateExecutables(root, depth: 0, results: &results, visited: &visited, limit: limit)

    // Sort by size descending, then by path
    results.sort { a, b in
      if a.size != b.size {
        return a.size > b.size
      }
      return a.url.path < b.url.path
    }

    return results.prefix(max(0, limit)).map { $0.url }
  }

  // MARK: - Helper

  private static func enumerateExecutables(
    _ root: URL, depth: Int, results: inout [(url: URL, size: Int64)], visited: inout Int, limit: Int
  ) {
    // depth 0 is the root directory; files in root/1/2/3 (depth 3) are included.
    guard depth <= 3 else { return }
    guard visited < 50_000 else { return }

    do {
      let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [])

      for url in contents {
        guard visited < 50_000 else { return }

        visited += 1

        let name = url.lastPathComponent.lowercased()

        // Skip package extensions
        let packageExtensions = ["app", "bundle", "framework", "plugin", "kext"]
        let fileExtension = (name as NSString).pathExtension.lowercased()
        if packageExtensions.contains(fileExtension) { continue }

        // If .exe extension, run the name/exclusion filter first
        if fileExtension == "exe" && !isExecutableName(name) { continue }

        // Single call to resourceValues with all needed keys
        guard let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]),
              v.isSymbolicLink == false else { continue }

        // Handle directories
        if v.isDirectory == true {
          enumerateExecutables(url, depth: depth + 1, results: &results, visited: &visited, limit: limit)
        } else if fileExtension == "exe" && v.isRegularFile == true, let size = v.fileSize {
          // Candidate .exe file: require isRegularFile == true
          results.append((url: url, size: Int64(size)))
        }
      }
    } catch {
      // Silently ignore errors reading directory
    }
  }

  private static func isExecutableName(_ name: String) -> Bool {
    let lowerName = name.lowercased()

    // Must end with .exe
    guard lowerName.hasSuffix(".exe") else { return false }

    // Exclude by prefix
    if lowerName.hasPrefix("unins") { return false }

    // Exclude by containing substring (case-insensitive)
    let excludeSubstrings = ["setup", "vcredist", "dxsetup", "crashreport", "easyanticheat", "battleye", "activation", "touchup"]
    for substring in excludeSubstrings {
      if lowerName.contains(substring) { return false }
    }

    return true
  }
}
