import Foundation

/// What refreshing a preset against the live display did.
package enum TextProfileRefresh: Equatable, Sendable {
  /// The game has no settings file yet (it writes one when it first exits).
  case noProfile
  /// The game is running and rewrites its settings when it exits, so nothing was touched.
  case gameRunning
  /// The file already held the values; nothing was written.
  case unchanged(missing: [String])
  /// The file was rewritten; `backup` is the copy of the previous file.
  case applied(backup: String, lines: [String], missing: [String])
}

extension PreparedPrefixGame {
  /// Writes the named preset into the game's settings file with the display placeholders
  /// resolved against `display`, so the game's resolution follows the display it will start on.
  /// See ``TextProfilePreset/refresh(profile:display:gameIsRunning:stamp:)``.
  package func refreshPreset(
    named name: String, prefix: URL, display: TextProfilePreset.Display, gameIsRunning: Bool,
    stamp: String
  ) throws -> TextProfileRefresh {
    guard let preset = presets.first(where: { $0.name == name }) else {
      throw LauncherError.operation("There is no preset named \(name).")
    }
    return try preset.refresh(
      profile: prefix.appendingPathComponent(settingsProfile), display: display,
      gameIsRunning: gameIsRunning, stamp: stamp)
  }
}

extension TextProfilePreset {
  /// How many `.bak-*` copies of the settings file are kept beside it.
  package static let retainedBackups = 5

  /// Applies the preset to the settings file for `display`.
  ///
  /// The file is touched only when a value differs, the previous file is kept as
  /// `<name>.bak-<stamp>`, and only the newest ``retainedBackups`` backups remain.
  package func refresh(
    profile: URL, display: Display, gameIsRunning: Bool, stamp: String
  ) throws -> TextProfileRefresh {
    guard FileManager.default.fileExists(atPath: profile.path) else { return .noProfile }
    // Checked before reading: the game rewrites its settings when it exits.
    guard !gameIsRunning else { return .gameRunning }
    let text: String
    do {
      text = try String(contentsOf: profile, encoding: .utf8)
    } catch {
      throw LauncherError.operation(
        "The game's settings cannot be read: \(error.localizedDescription)")
    }
    let result = apply(to: text, display: display)
    guard result.text != text else { return .unchanged(missing: result.missing) }
    let folder = profile.deletingLastPathComponent()
    let backup = folder.appendingPathComponent(profile.lastPathComponent + ".bak-\(stamp)")
    do {
      // A second change within one second keeps the first backup, which is the older state.
      if !FileManager.default.fileExists(atPath: backup.path) {
        try FileManager.default.copyItem(at: profile, to: backup)
      }
      try Data(result.text.utf8).write(to: profile, options: .atomic)
    } catch {
      throw LauncherError.operation(
        "The game's settings cannot be updated: \(error.localizedDescription)")
    }
    Self.pruneBackups(of: profile, keeping: Self.retainedBackups)
    return .applied(
      backup: backup.lastPathComponent,
      lines: Self.lines(in: result.text, keys: values.map(\.key)), missing: result.missing)
  }

  /// Removes all but the newest `count` `<name>.bak-*` files beside `profile` (the stamps sort by time).
  static func pruneBackups(of profile: URL, keeping count: Int) {
    let folder = profile.deletingLastPathComponent()
    let prefix = profile.lastPathComponent + ".bak-"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0.hasPrefix(prefix) }
      .sorted(by: >)
    for name in names.dropFirst(count) {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }
}
