import Foundation
import LauncherCore

/// Reads and changes the game's own options file, which is the only record of these settings.
///
/// The options file lives beside the player's saves, below the Windows user profile. The
/// installed game wrote `Documents/Need For Speed/settings/PROFILEOPTIONS_profile` with one
/// `Key Value` line per option; `PROFILEOPTIONS` beside it is a packed binary blob this app
/// never reads or writes. A real Windows profile often links `Documents` at the player's own
/// folder, so that link is followed deliberately: these are the player's settings, in the
/// player's place, and the app changes nothing else there.
///
/// This app keeps no copy of its values. Every value is read from the game's file and written
/// straight to it, so a change the player makes in the game's own Video menu is what the app
/// shows, and a stale cache can never overwrite it. A change is made only when all of these hold:
/// the game is not running, the file has the layout this app validated, the file is the one the
/// player was looking at, and a copy of it is safely kept first. The result is read back.
package struct NFS2015SettingsStore {
  /// The options file, relative to the Windows user profile.
  package static let optionsPath = "Documents/Need For Speed/settings/PROFILEOPTIONS_profile"
  static let limit = ProfileOptionsDocument.byteLimit
  static let reportedLineLimit = 64

  private let support: URL
  private let install: NFS2015Install?
  private let activity: NFS2015GameActivity
  private let write: PlayerFileEdit.Writer

  package init(
    support: URL, install: NFS2015Install?, activity: NFS2015GameActivity = .system,
    write: @escaping PlayerFileEdit.Writer = PlayerFileEdit.atomicWrite
  ) {
    self.support = support
    self.install = install
    self.activity = activity
    self.write = write
  }

  /// The game's options file, or nil until the game has written one.
  package func optionsFile() throws(LauncherError) -> URL? {
    guard let install else { return nil }
    guard
      let url = try GuestPath.resolve(
        Self.optionsPath, in: install.userProfile, followingLinks: true)
    else { return nil }
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
    return values?.isRegularFile == true ? url : nil
  }

  /// What the game's file holds now. A file this app cannot edit is reported, not thrown: the
  /// starter still opens, and the settings are left to the game's own menus.
  package func inspect() throws(LauncherError) -> NFS2015OptionsState {
    let backups = NFS2015OptionsBackups(support: support).state()
    guard let url = try optionsFile() else { return NFS2015OptionsState(backups: backups) }
    let bytes: Data
    do { bytes = try BoundedFile.read(url, limit: Self.limit) } catch {
      return NFS2015OptionsState(problem: error.localizedDescription, backups: backups)
    }
    let digest = NFS2015OptionsState.digest(of: bytes)
    do {
      let document = try ProfileOptionsDocument(data: bytes)
      return NFS2015OptionsState(
        settings: NFS2015Settings(document: document), digest: digest, backups: backups)
    } catch {
      return NFS2015OptionsState(
        digest: digest, problem: error.localizedDescription, backups: backups)
    }
  }

  /// Makes one change to the game's file, or refuses and leaves it exactly as it was.
  /// - Returns: What the file holds afterwards, read back from disk.
  /// - Precondition: The caller holds the session lock.
  /// - Throws: A refusal worded for the player: the game is running, the file changed since the
  ///   player saw it, its layout is not validated, a value is outside its domain, or the write
  ///   did not produce what was intended (in which case the earlier bytes are put back).
  @discardableResult
  package func apply(_ request: NFS2015SettingsRequest) throws(LauncherError)
    -> NFS2015SettingsOutcome
  {
    try request.validate()
    let edit = PlayerFileEdit(support: support)
    try edit.recover()
    guard let url = try optionsFile() else {
      throw .operation(
        """
        Start Need for Speed once and quit it, so it writes its own options file. This app \
        changes only the values you choose in a file the game already owns.
        """)
    }
    let closed = requiresClosedGame(request)
    if closed { try requireGameClosed() }
    let current = try BoundedFile.read(url, limit: Self.limit)
    try requireUnchanged(current, since: request)
    let before = try ProfileOptionsDocument(data: current)
    let backups = NFS2015OptionsBackups(support: support)
    let change = try plan(request, current: current, document: before, backups: backups)
    guard let target = change.target else { return .unchanged }

    try backups.keepOriginal(current)
    try backups.keepPrevious(current)
    if closed { try requireGameClosed() }
    try requireUnchanged(try BoundedFile.read(url, limit: Self.limit), since: request)
    try edit.replace(url, with: target, write: write)

    let written = try BoundedFile.read(url, limit: Self.limit)
    guard written == target, let after = try? ProfileOptionsDocument(data: written),
      change.expectedKeys.allSatisfy({ key, expected in
        after.value(key).map { ProfileOptionsDocument.isSameNumber($0, expected) } ?? false
      })
    else {
      throw putBack(current, at: url, edit: edit, found: written)
    }
    let lines = Self.lines(from: before, to: after)
    switch request.action {
    case .save: return .saved(lines)
    case .restoreOriginal: return .restored(.original, lines)
    case .restorePrevious: return .restored(.previous, lines)
    }
  }

  // MARK: Planning

  private struct Plan {
    /// The bytes to write; nil when the file already holds what was asked for.
    var target: Data?
    /// Keys that must hold these values afterwards; empty for a restore, which is checked whole.
    var expectedKeys: [String: String] = [:]
  }

  private func plan(
    _ request: NFS2015SettingsRequest, current: Data, document: ProfileOptionsDocument,
    backups: NFS2015OptionsBackups
  ) throws(LauncherError) -> Plan {
    switch request.action {
    case .save:
      let replacements = try NFS2015Settings.replacements(for: request.changes)
      // Only a value that differs is written, so a line the player did not touch keeps the
      // exact digits the game wrote even where this app would format the number differently.
      let effective = replacements.filter { key, value in
        document.value(key).map { !ProfileOptionsDocument.isSameNumber($0, value) } ?? true
      }
      guard !effective.isEmpty else { return Plan() }
      let edited = try document.applying(effective)
      let target = edited.data
      guard let reparsed = try? ProfileOptionsDocument(data: target),
        reparsed.isIdentical(to: document, except: Set(effective.keys))
      else {
        throw .operation("The change could not be made without altering other lines.")
      }
      return Plan(target: target, expectedKeys: effective)
    case .restoreOriginal, .restorePrevious:
      let saved = try backups.read(request.action == .restoreOriginal ? .original : .previous)
      _ = try ProfileOptionsDocument(data: saved)
      return Plan(target: saved == current ? nil : saved)
    }
  }

  // MARK: Guards

  private func requiresClosedGame(_ request: NFS2015SettingsRequest) -> Bool {
    guard request.action == .save else { return true }
    return request.changes.keys.contains { NFS2015Catalog.setting($0)?.needsGameClosed ?? true }
  }

  private func requireGameClosed() throws(LauncherError) {
    switch activity.isRunning() {
    case .some(true):
      throw .operation(
        """
        Need for Speed is running. Quit it first: it rewrites its options file when it exits, \
        which would undo a change made now. Nothing was changed.
        """)
    case .none:
      throw .operation(
        "Could not tell whether Need for Speed is running, so nothing was changed.")
    case .some(false):
      return
    }
  }

  private func requireUnchanged(_ bytes: Data, since request: NFS2015SettingsRequest)
    throws(LauncherError)
  {
    guard NFS2015OptionsState.digest(of: bytes) == request.expectedDigest else {
      throw .operation(
        """
        The game's options file changed after this page loaded it, so nothing was written. \
        Reload to see its current values, then choose again.
        """)
    }
  }

  /// Puts the earlier bytes back after a write that did not leave what was intended.
  private func putBack(_ earlier: Data, at url: URL, edit: PlayerFileEdit, found: Data)
    -> LauncherError
  {
    let held = found.isEmpty ? "nothing" : "\(found.count) bytes that differ from the plan"
    do {
      try edit.replace(url, with: earlier)
      return .operation(
        """
        After the write the options file held \(held), not what was written. It was put back \
        as it was before, and nothing else changed.
        """)
    } catch {
      return .operation(
        """
        After the write the options file held \(held), and it could not be put back: \
        \(error.localizedDescription) The copy kept in the Backups folder beside this app's \
        data holds the file as it was.
        """)
    }
  }

  // MARK: Reporting

  static func lines(from before: ProfileOptionsDocument, to after: ProfileOptionsDocument)
    -> [NFS2015OptionLine]
  {
    var seen = Set<String>()
    let keys = (before.keys + after.keys).filter { seen.insert($0).inserted }
    return keys.compactMap { key in
      let old = before.value(key)
      let new = after.value(key)
      guard old != new else { return nil }
      return NFS2015OptionLine(key: key, before: old ?? "absent", now: new ?? "absent")
    }.prefix(reportedLineLimit).map { $0 }
  }
}
