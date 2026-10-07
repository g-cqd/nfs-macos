import Foundation
import LauncherCore

/// Gives a game that has never run a safe first resolution, by writing the two lines it needs.
///
/// The game's own options file stays the single record of its settings. This writes that file
/// only when the game's settings folder is empty or absent, so it can never replace or sit beside
/// anything the game wrote (the binary options file included, which this app never reads or
/// names). It writes only `GstRender.ResolutionWidth` and `GstRender.ResolutionHeight`: no other
/// value is invented, and no name, id or key binding is involved. The game is expected to read the
/// two lines, fall back to its own defaults for every other option, and rewrite the whole file
/// when it exits **(not verified: the game has not been started with such a file)**. The file
/// passes the same layout check the settings page applies.
package enum NFS2015FirstRunOptions {
  package static let markerName = "first-run-seed.json"
  static let heightKey = "GstRender.ResolutionHeight"
  static let widthKey = "GstRender.ResolutionWidth"

  package enum Outcome: Equatable, Sendable {
    /// The file was written with this resolution.
    case seeded(NFS2015DisplayFacts.Size)
    /// Nothing was written, for this reason.
    case skipped(String)

    package var sentence: String {
      switch self {
      case .seeded(let size):
        "Seeded the game's first resolution as \(size.text): it had no options file yet."
      case .skipped(let reason): "No first-run resolution was seeded: \(reason)"
      }
    }
  }

  /// What the seeded file holds, exactly.
  static func contents(for size: NFS2015DisplayFacts.Size) -> String {
    "\(heightKey) \(size.height)\n\(widthKey) \(size.width)\n"
  }

  /// Seeds the file when the game has never written one. Never throws: a failure is a reason.
  /// - Precondition: The caller holds the session lock and the game is not running.
  package static func seed(
    _ size: NFS2015DisplayFacts.Size, in userProfile: URL, support: URL
  ) -> Outcome {
    guard (320...16_384).contains(size.width), (200...16_384).contains(size.height) else {
      return .skipped("the resolution \(size.text) is not one the game is asked for.")
    }
    let path = NFS2015SettingsStore.optionsPath.split(separator: "/").map(String.init)
    guard path.count >= 3, let name = path.last else {
      return .skipped("the options file's location is not one this app knows how to build.")
    }
    do {
      guard
        let documents = try GuestPath.resolve(path[0], in: userProfile, followingLinks: true)
      else {
        return .skipped("the Windows profile has no \(path[0]) folder yet.")
      }
      var folder = documents
      for component in path.dropFirst().dropLast() {
        if let existing = try GuestPath.resolve(component, in: folder, followingLinks: true) {
          folder = existing
        } else {
          folder = folder.appendingPathComponent(component)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
      }
      guard try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty else {
        return .skipped("the game's settings folder already holds files.")
      }
      let text = contents(for: size)
      _ = try ProfileOptionsDocument(text: text)
      let target = folder.appendingPathComponent(name)
      let staged = folder.appendingPathComponent(name + ".seed")
      try Data(text.utf8).write(to: staged, options: .atomic)
      do { try FileManager.default.moveItem(at: staged, to: target) } catch {
        try? FileManager.default.removeItem(at: staged)
        throw error
      }
      guard try BoundedFile.read(target, limit: 4096) == Data(text.utf8) else {
        return .skipped("the file did not read back as written.")
      }
      record(size, in: support)
      return .seeded(size)
    } catch {
      return .skipped(error.localizedDescription)
    }
  }

  /// Notes in this app's own folder that the options file began as a seed.
  private static func record(_ size: NFS2015DisplayFacts.Size, in support: URL) {
    let note = ["resolution": size.text, "seededAt": Date().formatted(.iso8601)]
    do {
      try JSONEncoder().encode(note).write(
        to: support.appendingPathComponent(markerName), options: .atomic)
    } catch { print("Could not record the first-run seed: \(error.localizedDescription)") }
  }
}
