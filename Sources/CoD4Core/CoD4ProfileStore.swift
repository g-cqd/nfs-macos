import Foundation
import LauncherCore

/// Manages complete profile folders with bounded copies and recoverable publication.
/// - Note: The synchronous session helper holds its lock and excludes a running game.
package struct CoD4ProfileStore {
  let paths: AppPaths
  private let files = FileManager.default
  var profiles: URL { paths.saves.appendingPathComponent("profiles") }
  var backups: URL { paths.support.appendingPathComponent("ProfileBackups") }
  var journal: URL { paths.support.appendingPathComponent("profile-transaction.json") }

  package init(paths: AppPaths) { self.paths = paths }

  /// Profile names are also passed to the engine; command separators and path syntax are rejected.
  package static func validName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 16 && name == name.trimmingCharacters(in: .whitespaces)
      && name.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || [32, 45, 95].contains($0)
      }
  }

  package func profileURL(_ name: String) throws -> URL {
    guard Self.validName(name) else {
      throw LauncherError.operation(
        "Use 1–16 letters, digits, spaces, hyphens or underscores for a profile name.")
    }
    return try checked(profiles.appendingPathComponent(name))
  }

  /// Includes archived profiles so removal never makes their backups inaccessible.
  package func list() throws -> [CoD4Profile] {
    let installed = try names(in: profiles)
    let archived = try names(in: backups)
    let names = Set(installed + archived).sorted()
    guard names.count <= 100 else {
      throw LauncherError.operation("The player folder contains more than 100 profiles.")
    }
    return try names.map { name in
      let backupRoot = try checked(backups.appendingPathComponent(name))
      let backupNames = try directories(in: backupRoot, limit: 100).map(\.lastPathComponent)
        .sorted().reversed()
      guard backupNames.allSatisfy({ UUID(uuidString: $0) != nil }) else {
        throw LauncherError.operation("Invalid profile backup name.")
      }
      let url = try profileURL(name)
      let isInstalled = installed.contains(name)
      let save =
        isInstalled
        ? try CoD4ProfileFiles.inventory(url).contains { $0.pathExtension.lowercased() == "svg" }
        : false
      return CoD4Profile(
        name: name, hasCampaignSave: save, backupNames: Array(backupNames), isInstalled: isInstalled
      )
    }
  }

  /// Performs one operation, preserving the prior profile in a backup before replacement or removal.
  package func perform(_ request: CoD4ProfileRequest) throws {
    try recover()
    let target = try profileURL(request.name)
    try files.createDirectory(at: profiles, withIntermediateDirectories: true)
    switch request.action {
    case .create:
      try ensureNew(request.name)
      let stage = try stagingURL()
      try files.createDirectory(at: stage, withIntermediateDirectories: false)
      do {
        for mode in CoD4Mode.allCases {
          var config = try BoundedFile.text(
            paths.resources.appendingPathComponent("Defaults/" + mode.configuration))
          for key in CoD4Bindings.defaults.keys.sorted() {
            guard let command = CoD4Bindings.defaults[key],
              CoD4Bindings.accepts(key: key, command: command)
            else {
              throw LauncherError.operation("Invalid default keyboard binding.")
            }
            config += "\nbind \(key) \"\(command)\""
          }
          try Data((config + "\n").utf8).write(
            to: stage.appendingPathComponent(mode.configuration), options: .withoutOverwriting)
        }
        try publish(stage, name: request.name)
      } catch {
        try discard(stage)
        throw error
      }
    case .importProfile:
      try ensureNew(request.name)
      guard let sourcePath = request.sourcePath else {
        throw LauncherError.operation("Choose a profile to import.")
      }
      let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
      let config = source.appendingPathComponent("config.cfg")
      _ = try CoD4Settings(config: BoundedFile.text(config))
      let stage = try stagingURL()
      try CoD4ProfileFiles.copy(source, to: stage)
      do { try publish(stage, name: request.name) } catch {
        try discard(stage)
        throw error
      }
    case .exportProfile:
      guard let destinationPath = request.destinationPath else {
        throw LauncherError.operation("Choose an export destination.")
      }
      let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL
      guard destination == destination.resolvingSymlinksInPath(),
        !destination.path.hasPrefix(paths.support.path + "/"),
        !destination.path.hasPrefix(paths.bundle.path + "/")
      else { throw LauncherError.operation("Export outside the app and player folder.") }
      let stage = destination.deletingLastPathComponent().appendingPathComponent(
        ".cod4-export-" + UUID().uuidString)
      try CoD4ProfileFiles.copy(target, to: stage)
      do { try files.moveItem(at: stage, to: destination) } catch {
        try discard(stage)
        throw error
      }
    case .backup:
      let backup = try nextBackup(request.name)
      let stage = backup.deletingLastPathComponent().appendingPathComponent(
        ".backup-" + UUID().uuidString)
      try CoD4ProfileFiles.copy(target, to: stage)
      do { try files.moveItem(at: stage, to: backup) } catch {
        try discard(stage)
        throw error
      }
    case .remove:
      _ = try CoD4ProfileFiles.inventory(target)
      try files.moveItem(at: target, to: nextBackup(request.name))
    case .restore:
      guard let backup = request.backup, UUID(uuidString: backup) != nil else {
        throw LauncherError.operation("Choose a valid backup.")
      }
      let source = try checked(
        backups.appendingPathComponent(request.name).appendingPathComponent(backup))
      let stage = try stagingURL()
      try CoD4ProfileFiles.copy(source, to: stage)
      do { try publish(stage, name: request.name) } catch {
        try discard(stage)
        throw error
      }
    }
  }

  func checked(_ url: URL) throws -> URL {
    let standard = url.standardizedFileURL
    guard standard == standard.resolvingSymlinksInPath(),
      standard.path.hasPrefix(paths.support.path + "/")
    else {
      throw LauncherError.operation(
        "A profile path leaves the player folder or contains a symbolic link.")
    }
    return standard
  }

  func directories(in directory: URL, limit: Int) throws -> [URL] {
    _ = try checked(directory)
    guard files.fileExists(atPath: directory.path) else { return [] }
    let entries = try files.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    ).filter {
      directory != profiles || $0.lastPathComponent != "active.txt"
    }
    guard entries.count <= limit else {
      throw LauncherError.operation(
        "Too many profiles or backups; export older backups before adding more.")
    }
    for entry in entries {
      let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw LauncherError.operation("Unexpected item in the profile collection.")
      }
    }
    return entries
  }

  private func names(in directory: URL) throws -> [String] {
    let result = try directories(in: directory, limit: 100).map(\.lastPathComponent)
    guard result.allSatisfy(Self.validName) else {
      throw LauncherError.operation("The profile collection has an unsupported name.")
    }
    return result
  }

  private func ensureNew(_ name: String) throws {
    let existing = try names(in: profiles)
    guard existing.count < 100, !existing.contains(where: { $0.lowercased() == name.lowercased() })
    else {
      throw LauncherError.operation(
        "That profile already exists, or the 100-profile limit was reached.")
    }
  }

  func nextBackup(_ name: String) throws -> URL {
    let directory = try checked(backups.appendingPathComponent(name))
    guard try directories(in: directory, limit: 100).count < 100 else {
      throw LauncherError.operation("Export older backups before creating another backup.")
    }
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(UUID().uuidString)
  }

  private func stagingURL() throws -> URL {
    try checked(paths.support.appendingPathComponent(".profile-" + UUID().uuidString))
  }

  func discard(_ stage: URL) throws {
    if files.fileExists(atPath: stage.path) { try files.removeItem(at: stage) }
  }
}
