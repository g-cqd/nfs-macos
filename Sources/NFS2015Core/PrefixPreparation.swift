import Foundation
import LauncherCore

/// Records the registry values the game needs in a prefix the app does not own.
///
/// The app owns no prefix for this game, so it never runs `wineboot` and never imports
/// `Defaults/settings.reg`. Each value is checked against the prefix's own hive file first and
/// imported only when it is missing, so repeated preparation starts nothing and changes nothing.
package struct PrefixPreparation {
  private let support: URL
  package init(support: URL) { self.support = support }

  /// Which of the declared settings the prefix has not recorded.
  /// - Complexity: O(hive bytes) per hive, read once each.
  package func missing(_ settings: [RegistrySetting], in prefix: URL) throws(LauncherError)
    -> [RegistrySetting]
  {
    guard !settings.isEmpty else { return [] }
    for setting in settings { try setting.validate() }
    var hives: [String: String] = [:]
    var missing: [RegistrySetting] = []
    for setting in settings {
      let name = setting.hive.file
      if hives[name] == nil {
        let url = prefix.appendingPathComponent(name)
        // A hive this app cannot read is treated as not recording the value.
        hives[name] =
          FileManager.default.fileExists(atPath: url.path)
          ? ((try? BoundedFile.text(url, limit: 16_777_216)) ?? "") : ""
      }
      if !setting.isRecorded(in: hives[name] ?? "") { missing.append(setting) }
    }
    return missing
  }

  /// Imports only the missing settings, through a caller-supplied `reg import`.
  /// - Parameter importing: Runs `wine reg import <script>` against the prefix.
  /// - Returns: The settings that were imported; empty when the prefix already had them all.
  /// - Precondition: The caller holds the session lock and the game is not running.
  package func apply(
    _ settings: [RegistrySetting], in prefix: URL, importing: (URL) throws -> Void
  ) throws(LauncherError) -> [RegistrySetting] {
    let pending = try missing(settings, in: prefix)
    guard let script = try RegistrySetting.script(pending) else { return [] }
    let url = support.appendingPathComponent("Temporary/prefix-settings.reg")
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(script.utf8).write(to: url, options: .atomic)
    } catch {
      throw .operation("Could not stage the registry script: \(error.localizedDescription)")
    }
    defer {
      do { try FileManager.default.removeItem(at: url) } catch {
        print("Could not remove the registry script: \(error)")
      }
    }
    do { try importing(url) } catch let error as LauncherError { throw error } catch {
      throw .operation("Wine could not record the prefix settings: \(error.localizedDescription)")
    }
    return pending
  }
}
