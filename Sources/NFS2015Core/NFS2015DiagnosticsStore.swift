import Foundation
import LauncherCore

/// Keeps the diagnostics preference in one small file of this app's own folder.
///
/// A file that is missing, oversized, invalid or of another version is never an error: the
/// defaults apply and the player is told why. The diagnostic-log switch is one-shot: `take()`
/// reads the choice for a launch and clears the switch in the same step, so a launch that
/// crashes the helper cannot leave it armed for the next one.
package struct NFS2015DiagnosticsStore: Sendable {
  package static let fileName = "diagnostics.json"
  static let sizeLimit = 4096

  /// What a read found: the choice to use, and why a saved file was not used.
  package struct Loaded: Equatable, Sendable {
    package let preference: NFS2015DiagnosticsPreference
    package let notice: String?
  }

  private let support: URL

  package init(support: URL) { self.support = support }

  package var location: URL { support.appendingPathComponent(Self.fileName) }

  /// The saved choice, or the defaults, never throwing.
  package func load() -> Loaded {
    let url = location
    guard FileManager.default.fileExists(atPath: url.path) else {
      return Loaded(preference: .standard, notice: nil)
    }
    do {
      let data = try BoundedFile.read(url, limit: Self.sizeLimit)
      return Loaded(
        preference: try JSONDecoder().decode(NFS2015DiagnosticsPreference.self, from: data),
        notice: nil)
    } catch {
      return Loaded(
        preference: .standard,
        notice: """
          The saved diagnostics choice could not be used (\(error.localizedDescription)), so the \
          defaults apply. Press Reset to clear it, or choose again and save.
          """)
    }
  }

  /// Keeps `preference`, replacing the file in one step and reading it back.
  /// - Returns: Whether the file changed.
  package func save(_ preference: NFS2015DiagnosticsPreference) throws(LauncherError) -> Bool {
    if FileManager.default.fileExists(atPath: location.path),
      load() == Loaded(preference: preference, notice: nil)
    {
      return false
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(preference).write(to: location, options: .atomic)
    } catch {
      throw .operation("Could not save the diagnostics choice: \(error.localizedDescription)")
    }
    guard load() == Loaded(preference: preference, notice: nil) else {
      throw .operation("The diagnostics choice did not read back as saved.")
    }
    return true
  }

  /// Forgets the saved choice, which means the defaults, including a file that could not be used.
  package func reset() throws(LauncherError) -> Bool {
    guard FileManager.default.fileExists(atPath: location.path) else { return false }
    do { try FileManager.default.removeItem(at: location) } catch {
      throw .operation("Could not clear the diagnostics choice: \(error.localizedDescription)")
    }
    return true
  }

  /// The choice for one launch. When the diagnostic log was switched on it is switched off here.
  /// - Returns: The preference as saved, so this launch can use the log once.
  package func take() -> Loaded {
    let loaded = load()
    guard loaded.preference.diagnosticLoggingNextLaunch else { return loaded }
    var spent = loaded.preference
    spent.diagnosticLoggingNextLaunch = false
    do { _ = try save(spent) } catch {
      // Without the cleared switch the log would run again next time, so run it for no launch.
      print("Could not switch the diagnostic log off after use: \(error.localizedDescription)")
      return Loaded(preference: spent, notice: error.localizedDescription)
    }
    return loaded
  }

  /// Carries out a request and says what happened; a failure is an answer, not an error.
  package func apply(_ request: NFS2015DiagnosticsRequest) -> NFS2015DiagnosticsOutcome {
    do {
      try request.validate()
      switch request.action {
      case .save:
        guard let preference = request.preference else { return .refused("Nothing to save.") }
        return try save(preference) ? .saved : .unchanged
      case .reset:
        return try reset() ? .reset : .unchanged
      }
    } catch {
      return .refused(error.localizedDescription)
    }
  }
}
