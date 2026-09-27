import Foundation
import LauncherCore

extension CoD4ProfileStore {
  private struct Publication: Codable {
    let name: String
    let stage: String
    let backup: String?
  }

  /// Resolves interrupted publication before any profile can be read or modified.
  package func recover() throws {
    let files = FileManager.default
    guard files.fileExists(atPath: journal.path) else { return }
    _ = try checked(journal)
    let transaction = try JSONDecoder().decode(
      Publication.self, from: BoundedFile.read(journal, limit: 4096))
    guard transaction.stage.hasPrefix(".profile-"),
      UUID(uuidString: String(transaction.stage.dropFirst(9))) != nil,
      transaction.backup == nil || UUID(uuidString: transaction.backup ?? "") != nil
    else { throw LauncherError.operation("Invalid profile transaction.") }
    let target = try profileURL(transaction.name)
    let stage = try checked(paths.support.appendingPathComponent(transaction.stage))
    if files.fileExists(atPath: stage.path) {
      if let backup = transaction.backup {
        let previous = try checked(
          backups.appendingPathComponent(transaction.name).appendingPathComponent(backup))
        if !files.fileExists(atPath: target.path), files.fileExists(atPath: previous.path) {
          try files.moveItem(at: previous, to: target)
        }
      }
      try discard(stage)
    }
    try files.removeItem(at: journal)
  }

  func publish(_ stage: URL, name: String) throws {
    let files = FileManager.default
    _ = try CoD4ProfileFiles.inventory(stage)
    let target = try profileURL(name)
    let previous = files.fileExists(atPath: target.path) ? try nextBackup(name) : nil
    let transaction = Publication(
      name: name, stage: stage.lastPathComponent, backup: previous?.lastPathComponent)
    try JSONEncoder().encode(transaction).write(to: journal, options: .withoutOverwriting)
    do {
      if let previous { try files.moveItem(at: target, to: previous) }
      try files.moveItem(at: stage, to: target)
      try files.removeItem(at: journal)
    } catch {
      try recover()
      throw error
    }
  }
}
