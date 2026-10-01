import Foundation

/// Resolves Windows-style relative paths inside a prefix the way the guest sees them.
///
/// Windows installers record paths whose case does not always match the bytes on disk, so a
/// direct lookup can miss a folder that the guest finds. Each component is matched
/// case-insensitively against a bounded directory listing, links are refused, and the result
/// is proven to stay inside the prefix.
package enum GuestPath {
  /// The largest directory this resolver will scan; a Windows prefix folder never needs more.
  static let entryLimit = 4096

  /// - Parameter followingLinks: Accepts a linked component, as a Windows user profile that
  ///   points at the player's own folders legitimately does. The result is still proven to be
  ///   inside the root only when this is false, because a followed link may leave it.
  /// - Returns: The existing host location, or nil when any component is absent.
  /// - Throws: A failure when a component is a link, unreadable, or escapes the root.
  package static func resolve(_ relative: String, in root: URL, followingLinks: Bool = false)
    throws(LauncherError) -> URL?
  {
    let components = relative.split(separator: "/").map(String.init)
    guard !components.isEmpty, components.count <= 32,
      components.allSatisfy({ $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
    else {
      throw .operation("Invalid location inside the Windows folder: \(relative)")
    }
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    var current = root
    for component in components {
      guard let match = try entry(named: component, in: current, followingLinks: followingLinks)
      else { return nil }
      current = followingLinks ? match.resolvingSymlinksInPath() : match
    }
    guard followingLinks || current.path == root.path || current.path.hasPrefix(root.path + "/")
    else {
      throw .operation("A Windows folder entry leads outside the installation: \(relative)")
    }
    return current
  }

  /// Lists the version folders directly below a root, newest numbering first.
  ///
  /// EA installs its client into a versioned folder and the stable junction beside it does not
  /// exist in every prefix, so the current version is discovered rather than assumed.
  package static func versionFolders(in root: URL) throws(LauncherError) -> [URL] {
    let files = FileManager.default
    guard files.fileExists(atPath: root.path) else { return [] }
    do {
      let contents = try files.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard contents.count <= entryLimit else {
        throw LauncherError.operation("Too many entries in \(root.lastPathComponent).")
      }
      let versions = try contents.compactMap { url -> (parts: [Int], url: URL)? in
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        let parts = url.lastPathComponent.split(separator: ".").map(String.init)
        guard (2...6).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ (0...999_999).contains($0) })
        else { return nil }
        return (numbers, url)
      }
      return versions.sorted { left, right in
        for (first, second) in zip(left.parts, right.parts) where first != second {
          return first > second
        }
        return left.parts.count > right.parts.count
      }.map(\.url)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not read \(root.lastPathComponent): \(error.localizedDescription)")
    }
  }

  private static func entry(named name: String, in directory: URL, followingLinks: Bool)
    throws(LauncherError) -> URL?
  {
    let files = FileManager.default
    let direct = directory.appendingPathComponent(name)
    do {
      if files.fileExists(atPath: direct.path) {
        let linked = try direct.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        guard followingLinks || !linked else {
          throw LauncherError.operation("A Windows folder entry is a link: \(name)")
        }
        return direct
      }
      guard files.fileExists(atPath: directory.path) else { return nil }
      let contents = try files.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
      guard contents.count <= entryLimit else {
        throw LauncherError.operation("Too many entries in \(directory.lastPathComponent).")
      }
      let folded = name.lowercased()
      let matches = contents.filter { $0.lastPathComponent.lowercased() == folded }
      guard let match = matches.first else { return nil }
      guard matches.count == 1 else {
        throw LauncherError.operation("The Windows folder has more than one \(name).")
      }
      let linked = try match.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
      guard followingLinks || !linked else {
        throw LauncherError.operation("A Windows folder entry is a link: \(name)")
      }
      return match
    } catch let error as LauncherError { throw error } catch {
      throw .operation(
        "Could not read \(directory.lastPathComponent): \(error.localizedDescription)")
    }
  }
}
