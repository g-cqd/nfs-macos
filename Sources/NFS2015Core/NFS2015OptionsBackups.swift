import Foundation
import LauncherCore

/// The saved copies of the game's options file, kept in this app's own folder.
///
/// `original` is the file exactly as it was before this app first changed it, saved once and never
/// replaced, so there is always a way back to what the game itself had written. `previous` is the
/// file as it was before the latest change, replaced each time, so the last change can be undone.
/// Both are copies of whole files whose layout was validated before the copy was taken.
package struct NFS2015OptionsBackups {
  static let originalName = "PROFILEOPTIONS_profile.original"
  static let previousName = "PROFILEOPTIONS_profile.previous"

  private let root: URL
  private let files = FileManager.default

  package init(support: URL) { root = support.appendingPathComponent("Backups") }

  private func url(_ kind: NFS2015BackupKind) -> URL {
    root.appendingPathComponent(kind == .original ? Self.originalName : Self.previousName)
  }

  package func state() -> NFS2015BackupState {
    NFS2015BackupState(original: exists(.original), previous: exists(.previous))
  }

  /// The saved bytes of a backup.
  /// - Throws: A failure when there is no such backup or it is not a plain file of a sane size.
  package func read(_ kind: NFS2015BackupKind) throws(LauncherError) -> Data {
    guard exists(kind) else {
      throw .operation(
        kind == .original
          ? "This app has not saved the game's original options file yet."
          : "This app has not changed the game's options file yet, so there is nothing to undo.")
    }
    return try BoundedFile.read(url(kind), limit: ProfileOptionsDocument.byteLimit)
  }

  /// Saves the file as it is now, once, unless the original copy already exists.
  package func keepOriginal(_ bytes: Data) throws(LauncherError) {
    guard !exists(.original) else { return }
    try write(bytes, to: url(.original), options: .withoutOverwriting)
  }

  /// Replaces the previous copy with the file as it is now.
  package func keepPrevious(_ bytes: Data) throws(LauncherError) {
    try write(bytes, to: url(.previous), options: .atomic)
  }

  private func exists(_ kind: NFS2015BackupKind) -> Bool {
    guard
      let values = try? url(kind).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  private func write(_ bytes: Data, to url: URL, options: Data.WritingOptions)
    throws(LauncherError)
  {
    do {
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      try bytes.write(to: url, options: options)
    } catch {
      throw .operation(
        "Could not keep a copy of the game's options file: \(error.localizedDescription)")
    }
  }
}
