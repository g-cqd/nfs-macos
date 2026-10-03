import Foundation
import LauncherCore

/// Keeps the player's MetalFX choice in one small file of this app's own folder.
///
/// The file is the app's, not the game's: DXMT reads nothing from it. The app reads it before it
/// starts Wine and turns it into environment variables for the game's executable. A file that is
/// missing, oversized, not valid, of another version or holding a value this app does not offer
/// is never an error: the game starts with MetalFX off and the player is told why.
package struct NFS2015MetalFXStore: Sendable {
  package static let fileName = "metalfx.json"
  static let sizeLimit = 4096

  /// What a read found: the choice to use, and why a saved file was not used.
  package struct Loaded: Equatable, Sendable {
    package let preference: NFS2015MetalFXPreference
    package let notice: String?
  }

  private let support: URL

  package init(support: URL) { self.support = support }

  package var location: URL { support.appendingPathComponent(Self.fileName) }

  /// The saved choice, or off, never throwing.
  package func load() -> Loaded {
    let url = location
    guard FileManager.default.fileExists(atPath: url.path) else {
      return Loaded(preference: .off, notice: nil)
    }
    do {
      let data = try BoundedFile.read(url, limit: Self.sizeLimit)
      let preference = try JSONDecoder().decode(NFS2015MetalFXPreference.self, from: data)
      return Loaded(preference: preference, notice: nil)
    } catch {
      return Loaded(
        preference: .off,
        notice: """
          The saved MetalFX choice could not be used (\(error.localizedDescription)), so MetalFX \
          is off. Press Reset MetalFX to clear it, or choose again and save.
          """)
    }
  }

  /// Keeps `preference`, replacing the file in one step and reading it back.
  /// - Returns: Whether the file changed; false when it already held this choice.
  /// - Throws: A failure when the file cannot be written or does not read back as written.
  package func save(_ preference: NFS2015MetalFXPreference) throws(LauncherError) -> Bool {
    if FileManager.default.fileExists(atPath: location.path),
      load()
        == Loaded(preference: preference, notice: nil)
    {
      return false
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(preference).write(to: location, options: .atomic)
    } catch {
      throw .operation("Could not save the MetalFX choice: \(error.localizedDescription)")
    }
    guard load() == Loaded(preference: preference, notice: nil) else {
      throw .operation("The MetalFX choice did not read back as saved.")
    }
    return true
  }

  /// Forgets the saved choice, which means MetalFX off, including a file that could not be used.
  /// - Returns: Whether a file was removed.
  package func reset() throws(LauncherError) -> Bool {
    guard FileManager.default.fileExists(atPath: location.path) else { return false }
    do { try FileManager.default.removeItem(at: location) } catch {
      throw .operation("Could not clear the MetalFX choice: \(error.localizedDescription)")
    }
    return true
  }

  /// Carries out a request and says what happened; a failure is an answer, not an error.
  package func apply(_ request: NFS2015MetalFXRequest) -> NFS2015MetalFXOutcome {
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
