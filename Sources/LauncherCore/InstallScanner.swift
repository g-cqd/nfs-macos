import Foundation

/// The result of recognising a player's installation: an exact, hash-pinned file inventory.
package struct InstallScan: Sendable {
  package let files: [ManifestFile]
  package let game: InstalledGame
}

/// Recognises an installed PC game from `ImportRules` and inventories exactly the files to copy.
///
/// The selected folder is untrusted. The scan never follows links, bounds entry counts and bytes,
/// compares names case-insensitively (installations copied between file systems differ in case) and
/// reports the on-disk spelling so later copies find the same files.
package enum InstallScanner {
  private struct Entry {
    enum Kind { case directory, file, link, other }
    let name: String
    let url: URL
    let kind: Kind
    let size: Int
  }

  private struct Found {
    let relative: String
    let url: URL
    let size: Int
  }

  private static let maximumDepth = 10

  /// - Complexity: O(files + bytes); every selected file is read once to compute its digest.
  /// - Throws: A message naming the first missing, linked, incomplete or oversized item.
  package static func scan(_ source: URL, rules: ImportRules) throws(LauncherError)
    -> InstallScan
  {
    try rules.validate()
    let root = source.standardizedFileURL
    let rootEntry = try describe(root)
    guard rootEntry.kind == .directory else {
      throw .operation("Select the game's installation folder, without symbolic links.")
    }
    for file in rules.required {
      let resolved = try resolve(file.path, in: root, wantsFile: true)
      guard try describe(resolved.url).size >= file.minimumSize else {
        throw .operation("\(file.path) is smaller than a complete installation provides.")
      }
    }
    var found: [Found] = []
    var totalBytes = 0
    for directory in rules.directories {
      let resolved = try resolve(directory.path, in: root, wantsFile: false)
      var directoryBytes = 0
      try walk(
        resolved.url, relative: resolved.relative, rule: directory, depth: 0, rules: rules,
        found: &found, directoryBytes: &directoryBytes)
      guard directoryBytes >= directory.minimumBytes else {
        throw .operation(
          "\(directory.path) is incomplete. Select a full installation, not a partial copy.")
      }
      totalBytes += directoryBytes
      guard totalBytes <= rules.maximumBytes else {
        throw .operation("The installation is larger than this app supports.")
      }
    }
    var seen = Set<String>()
    for item in found where !seen.insert(item.relative.lowercased()).inserted {
      throw .operation("Two files differ only by letter case: \(item.relative)")
    }
    for pairing in rules.pairings {
      let directory = pairing.directory.lowercased() + "/"
      for item in found {
        let path = item.relative.lowercased()
        guard path.hasPrefix(directory), path.hasSuffix(pairing.primarySuffix),
          !path.dropFirst(directory.count).contains("/")
        else { continue }
        let companion = String(path.dropLast(pairing.primarySuffix.count)) + pairing.companionSuffix
        guard seen.contains(companion) else {
          throw .operation(
            "\(item.relative) has no matching \(pairing.companionSuffix) archive. The installation is incomplete."
          )
        }
      }
    }
    let executableName = rules.executable.lowercased()
    guard let executable = found.first(where: { $0.relative.lowercased() == executableName })
    else { throw .operation("\(rules.executable) was not found in the selected folder.") }
    let image = try PortableExecutable.read(executable.url)
    guard image.machine == rules.expectedMachine, !image.isDynamicLibrary else {
      throw .operation("\(rules.executable) is not a 32-bit Windows game executable.")
    }
    var inventory: [ManifestFile] = []
    inventory.reserveCapacity(found.count)
    var executableDigest = ""
    for item in found.sorted(by: { $0.relative < $1.relative }) {
      let digest = try FileDigest.sha256(of: item.url, size: item.size)
      if item.relative == executable.relative { executableDigest = digest }
      inventory.append(ManifestFile(path: item.relative, size: item.size, sha256: digest))
    }
    let names = Set(found.map { ($0.relative as NSString).lastPathComponent.lowercased() })
      .union(try listing(root).map { $0.name.lowercased() })
    let markers = rules.markers.filter { marker in
      marker.patterns.contains { pattern in names.contains { matches(pattern.lowercased(), $0) } }
    }.map(\.name)
    let build = rules.knownBuilds.first { $0.executableSHA256 == executableDigest }?.name
    return InstallScan(
      files: inventory,
      game: InstalledGame(
        executableSHA256: executableDigest, build: build, fileVersion: image.fileVersion,
        versionStrings: image.strings, markers: markers, fileCount: inventory.count,
        totalBytes: totalBytes))
  }

  // MARK: - Traversal

  private static func walk(
    _ directory: URL, relative: String, rule: ImportRules.Directory, depth: Int,
    rules: ImportRules, found: inout [Found], directoryBytes: inout Int
  ) throws(LauncherError) {
    guard depth <= maximumDepth else { throw .operation("The installation is nested too deeply.") }
    let excludedNames = Set(rule.excludedNames.map { $0.lowercased() })
    let excludedDirectories = Set(rule.excludedDirectories.map { $0.lowercased() })
    for entry in try listing(directory).sorted(by: { $0.name < $1.name }) {
      let lower = entry.name.lowercased()
      if lower == ".ds_store" || entry.name.hasPrefix("._") { continue }
      let path = relative + "/" + entry.name
      switch entry.kind {
      case .link: throw .operation("Symbolic links are not supported in a game folder: \(path)")
      case .other: throw .operation("Unsupported item in the game folder: \(path)")
      case .directory:
        if excludedDirectories.contains(lower) { continue }
        try walk(
          entry.url, relative: path, rule: rule, depth: depth + 1, rules: rules, found: &found,
          directoryBytes: &directoryBytes)
      case .file:
        if excludedNames.contains(lower) || rule.excludedSuffixes.contains(where: lower.hasSuffix) {
          continue
        }
        found.append(Found(relative: path, url: entry.url, size: entry.size))
        directoryBytes += entry.size
        guard found.count <= rules.maximumFiles, directoryBytes <= rules.maximumBytes else {
          throw .operation("The installation contains more data than this app supports.")
        }
      }
    }
  }

  /// Resolves each component case-insensitively without crossing a link; returns the on-disk spelling.
  private static func resolve(_ path: String, in root: URL, wantsFile: Bool)
    throws(LauncherError) -> (url: URL, relative: String)
  {
    var current = root
    var spelled: [String] = []
    let components = path.split(separator: "/").map(String.init)
    for (index, component) in components.enumerated() {
      let matches = try listing(current).filter {
        $0.name.caseInsensitiveCompare(component) == .orderedSame
      }
      guard let entry = matches.first else {
        throw .operation(
          "\(path) was not found. Select the folder that contains \(components.first ?? path).")
      }
      guard matches.count == 1 else {
        throw .operation("Several items named \(component) differ only by letter case.")
      }
      let last = index == components.count - 1
      let expected: Entry.Kind = last && wantsFile ? .file : .directory
      guard entry.kind == expected else {
        throw .operation("\(path) is not a regular \(last && wantsFile ? "file" : "folder").")
      }
      current = entry.url
      spelled.append(entry.name)
    }
    return (current, spelled.joined(separator: "/"))
  }

  private static func listing(_ directory: URL) throws(LauncherError) -> [Entry] {
    do {
      let urls = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      guard urls.count <= 30_000 else {
        throw LauncherError.operation("A game folder contains too many items.")
      }
      return try urls.map { try describe($0) }
    } catch let error as LauncherError { throw error } catch {
      throw .operation(
        "Could not read \(directory.lastPathComponent): \(error.localizedDescription)")
    }
  }

  private static func describe(_ url: URL) throws(LauncherError) -> Entry {
    do {
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      let kind: Entry.Kind =
        values.isSymbolicLink == true
        ? .link
        : values.isDirectory == true ? .directory : values.isRegularFile == true ? .file : .other
      return Entry(name: url.lastPathComponent, url: url, kind: kind, size: values.fileSize ?? 0)
    } catch {
      throw .operation("Could not inspect \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }

  /// Supports `*` anywhere in a pattern; the comparison is case-folded by the caller.
  static func matches(_ pattern: String, _ name: String) -> Bool {
    let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
    guard parts.count > 1 else { return pattern == name }
    var remainder = Substring(name)
    guard let first = parts.first, remainder.hasPrefix(first) else { return false }
    remainder = remainder.dropFirst(first.count)
    for part in parts.dropFirst().dropLast() {
      guard let range = remainder.range(of: part) else { return false }
      remainder = remainder[range.upperBound...]
    }
    guard let last = parts.last else { return false }
    return remainder.hasSuffix(last) && remainder.count >= last.count
  }
}
