import Foundation

/// Removes host aliases from Wine's guest namespace. This is not an OS sandbox.
package enum GuestIsolation {
  /// Recovers an interrupted prefix replacement before Wine is started.
  package static func recover(prefix: URL) throws(LauncherError) {
    let files = FileManager.default
    let next = prefix.appendingPathExtension("isolation-next")
    let previous = prefix.appendingPathExtension("isolation-previous")
    do {
      if files.fileExists(atPath: previous.path) {
        if files.fileExists(atPath: prefix.path) {
          try files.removeItem(at: previous)
        } else {
          try files.moveItem(at: previous, to: prefix)
        }
      }
      if files.fileExists(atPath: next.path) { try files.removeItem(at: next) }
    } catch { throw .operation("Could not recover guest isolation: \(error.localizedDescription)") }
  }

  /// Publishes a restricted prefix only after all changes succeed on a copy.
  /// - Precondition: Wine is stopped and the caller holds the session lock.
  /// - Complexity: O(prefix bytes) when aliases change; O(user aliases) otherwise.
  package static func restrict(prefix: URL, root: URL) throws(LauncherError) {
    let files = FileManager.default
    let prefix = prefix.standardizedFileURL
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    guard prefix.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
      throw .operation("Wine's prefix is outside the player folder.")
    }
    do {
      let removals = try aliases(prefix: prefix, root: root)
      guard !removals.isEmpty else { return }
      let next = prefix.appendingPathExtension("isolation-next")
      let previous = prefix.appendingPathExtension("isolation-previous")
      guard !files.fileExists(atPath: next.path), !files.fileExists(atPath: previous.path) else {
        throw LauncherError.operation("Recover the interrupted prefix change before continuing.")
      }
      try files.copyItem(at: prefix, to: next)
      do {
        for relative in removals {
          let alias = next.appendingPathComponent(relative)
          try files.removeItem(at: alias)
          if !relative.hasPrefix("dosdevices/") {
            try files.createDirectory(at: alias, withIntermediateDirectories: false)
          }
        }
        try files.moveItem(at: prefix, to: previous)
        do { try files.moveItem(at: next, to: prefix) } catch {
          try files.moveItem(at: previous, to: prefix)
          throw error
        }
        try files.removeItem(at: previous)
      } catch {
        if files.fileExists(atPath: next.path) { try files.removeItem(at: next) }
        throw error
      }
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not isolate Wine's folders: \(error.localizedDescription)")
    }
  }

  private static func aliases(prefix: URL, root: URL) throws -> [String] {
    let files = FileManager.default
    let drives = prefix.appendingPathComponent("dosdevices")
    let entries = try files.contentsOfDirectory(
      at: drives, includingPropertiesForKeys: [.isSymbolicLinkKey])
    guard entries.count <= 64 else {
      throw LauncherError.operation("Too many Wine drive mappings.")
    }
    var removals: [String] = []
    var hasC = false
    for entry in entries {
      guard try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else {
        throw LauncherError.operation("Unexpected real file in Wine's drive mappings.")
      }
      if entry.lastPathComponent == "c:" {
        guard entry.resolvingSymlinksInPath() == prefix.appendingPathComponent("drive_c") else {
          throw LauncherError.operation("Wine's C drive does not refer to its private folder.")
        }
        hasC = true
      } else {
        removals.append("dosdevices/" + entry.lastPathComponent)
      }
    }
    guard hasC else { throw LauncherError.operation("Wine's private C drive is missing.") }
    let users = prefix.appendingPathComponent("drive_c/users")
    guard files.fileExists(atPath: users.path) else { return removals }
    let profiles = try files.contentsOfDirectory(
      at: users, includingPropertiesForKeys: [.isSymbolicLinkKey])
    guard profiles.count <= 100 else {
      throw LauncherError.operation("Too many Wine user folders.")
    }
    for profile in profiles {
      let relative = "drive_c/users/" + profile.lastPathComponent
      if try profile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        if !profile.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") {
          removals.append(relative)
        }
        continue
      }
      guard try profile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        continue
      }
      let aliases = try files.contentsOfDirectory(
        at: profile, includingPropertiesForKeys: [.isSymbolicLinkKey])
      guard aliases.count <= 100 else {
        throw LauncherError.operation("Too many Wine user aliases.")
      }
      for alias in aliases
      where try alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        if !alias.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") {
          removals.append(relative + "/" + alias.lastPathComponent)
        }
      }
    }
    return removals
  }
}
