import Foundation
import LauncherCore

/// A restorable copy of the player's settings and saves.
package struct FarCry2Backup: Codable, Equatable, Identifiable, Sendable {
  package let id: String
  package let created: Date
  package let label: String
  package let files: Int
  package let bytes: Int
  package init(id: String, created: Date, label: String, files: Int, bytes: Int) {
    self.id = id
    self.created = created
    self.label = label
    self.files = files
    self.bytes = bytes
  }
}

/// What a backup operation should do.
package struct FarCry2BackupRequest: Codable, Equatable, Sendable {
  package enum Action: String, Codable, Sendable { case create, restore, remove }
  package let action: Action
  package let id: String?
  package init(action: Action, id: String? = nil) {
    self.action = action
    self.id = id
  }
}

/// Bounded, recoverable backups of the folders `FarCry2UserData` links into Wine.
/// - Note: The synchronous session helper holds its lock and excludes a running game.
package struct FarCry2Backups {
  package static let limit = 20
  private let paths: AppPaths
  private let data: FarCry2UserData
  private let files = FileManager.default
  private let parts: [(name: String, live: URL)]

  package init(paths: AppPaths) {
    self.paths = paths
    data = FarCry2UserData(paths: paths)
    parts = [("Documents", data.documents), ("LocalAppData", data.localData)]
  }

  package var root: URL { paths.data.appendingPathComponent("Backups/FarCry2") }
  /// The game's own first profile, kept once before the starter edits it for the first time.
  package var originalProfile: URL { root.appendingPathComponent("GamerProfile.original.xml") }

  /// Newest first. Entries with unreadable metadata are skipped rather than trusted.
  package func list() throws(LauncherError) -> [FarCry2Backup] {
    guard files.fileExists(atPath: root.path) else { return [] }
    do {
      let entries = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { UUID(uuidString: $0.lastPathComponent) != nil }
      guard entries.count <= Self.limit + 4 else {
        throw LauncherError.operation("Too many backups; remove older ones.")
      }
      let decoder = JSONDecoder()
      return entries.compactMap { entry in
        guard
          let data = try? BoundedFile.read(
            entry.appendingPathComponent("backup.json"), limit: 4096),
          let backup = try? decoder.decode(FarCry2Backup.self, from: data),
          backup.id == entry.lastPathComponent
        else { return nil }
        return backup
      }.sorted { $0.created > $1.created }
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not list backups: \(error.localizedDescription)")
    }
  }

  /// Finishes or rolls back an interrupted restore and removes unfinished staging folders.
  package func recover() throws(LauncherError) {
    do {
      for part in parts {
        let parent = part.live.deletingLastPathComponent()
        guard files.fileExists(atPath: parent.path) else { continue }
        for entry in try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
          let name = entry.lastPathComponent
          if name.hasPrefix(part.live.lastPathComponent + ".replaced-") {
            if files.fileExists(atPath: part.live.path) {
              try files.removeItem(at: entry)
            } else {
              try files.moveItem(at: entry, to: part.live)
            }
          } else if name.hasPrefix(part.live.lastPathComponent + ".restoring-") {
            try files.removeItem(at: entry)
          }
        }
      }
      if files.fileExists(atPath: root.path) {
        for entry in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.hasPrefix(".staging-") {
          try files.removeItem(at: entry)
        }
      }
    } catch {
      throw .operation("Could not recover the player data backups: \(error.localizedDescription)")
    }
  }

  @discardableResult
  package func perform(_ request: FarCry2BackupRequest) throws(LauncherError) -> [FarCry2Backup] {
    try recover()
    switch request.action {
    case .create: _ = try create(label: "Manual backup")
    case .restore: try restore(try validated(request.id))
    case .remove: try remove(try validated(request.id))
    }
    return try list()
  }

  package func create(label: String) throws(LauncherError) -> FarCry2Backup {
    try create(label: label, allowance: 0)
  }

  /// `allowance` lets the safety copy taken by a restore exceed the limit it is protecting; without it a
  /// player holding the maximum number of backups could never restore one.
  private func create(label: String, allowance: Int) throws(LauncherError) -> FarCry2Backup {
    let existing = try list()
    guard existing.count < Self.limit + allowance else {
      throw .operation("Remove an older backup before creating another (limit \(Self.limit)).")
    }
    let id = UUID().uuidString
    let stage = root.appendingPathComponent(".staging-" + id)
    do {
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      try files.createDirectory(at: stage, withIntermediateDirectories: false)
      var count = 0
      var bytes = 0
      for part in parts {
        let summary = try BoundedTree.copy(part.live, to: stage.appendingPathComponent(part.name))
        count += summary.files.count
        bytes += summary.bytes
      }
      let backup = FarCry2Backup(
        id: id, created: Date(), label: label, files: count, bytes: bytes)
      // Full-precision dates keep backups made in the same second in creation order.
      try JSONEncoder().encode(backup).write(to: stage.appendingPathComponent("backup.json"))
      try files.moveItem(at: stage, to: root.appendingPathComponent(id))
      return backup
    } catch {
      if files.fileExists(atPath: stage.path) {
        do { try files.removeItem(at: stage) } catch { print("Could not remove staging: \(error)") }
      }
      if let error = error as? LauncherError { throw error }
      throw .operation("Could not create the backup: \(error.localizedDescription)")
    }
  }

  /// Saves the current data as a backup, then replaces it; each folder swap is a pair of renames
  /// that `recover()` completes or reverses after an interruption.
  private func restore(_ id: String) throws(LauncherError) {
    let source = root.appendingPathComponent(id)
    guard try list().contains(where: { $0.id == id }) else {
      throw .operation("That backup no longer exists or its record is damaged.")
    }
    _ = try create(label: "Before restoring a backup", allowance: 1)
    let token = UUID().uuidString
    do {
      var staged: [(live: URL, restoring: URL)] = []
      for part in parts {
        let restoring = part.live.deletingLastPathComponent().appendingPathComponent(
          part.live.lastPathComponent + ".restoring-" + token)
        try BoundedTree.copy(source.appendingPathComponent(part.name), to: restoring)
        staged.append((part.live, restoring))
      }
      for (live, restoring) in staged {
        let replaced = live.deletingLastPathComponent().appendingPathComponent(
          live.lastPathComponent + ".replaced-" + token)
        if files.fileExists(atPath: live.path) { try files.moveItem(at: live, to: replaced) }
        try files.moveItem(at: restoring, to: live)
        if files.fileExists(atPath: replaced.path) { try files.removeItem(at: replaced) }
      }
    } catch {
      try recover()
      if let error = error as? LauncherError { throw error }
      throw .operation("Could not restore the backup: \(error.localizedDescription)")
    }
  }

  private func remove(_ id: String) throws(LauncherError) {
    do { try files.removeItem(at: root.appendingPathComponent(id)) } catch {
      throw .operation("Could not remove the backup: \(error.localizedDescription)")
    }
  }

  private func validated(_ id: String?) throws(LauncherError) -> String {
    guard let id, UUID(uuidString: id) != nil else { throw .operation("Choose a valid backup.") }
    return id
  }
}
