import Foundation
import LauncherCore

/// Keeps Far Cry 2's settings and saves outside the Wine prefix and the replaceable game generations.
///
/// The game stores `GamerProfile.xml` and `Saved Games` under the Windows user's Documents folder
/// (`My Games\Far Cry 2`) and its input map under `AppData\Local\My Games\Far Cry 2`. Both folders live
/// in the player's `Data/Saves` and are linked into whichever Wine profile folder exists, so deleting
/// or rebuilding the prefix, or updating the app, never touches progress.
package struct FarCry2UserData {
  package let paths: AppPaths
  private let files = FileManager.default

  package init(paths: AppPaths) { self.paths = paths }

  package var documents: URL { paths.saves.appendingPathComponent("FarCry2/Documents") }
  package var localData: URL { paths.saves.appendingPathComponent("FarCry2/LocalAppData") }
  package var conflicts: URL { paths.saves.appendingPathComponent("FarCry2/Conflicts") }
  package var profileFile: URL { documents.appendingPathComponent("GamerProfile.xml") }

  /// Result of making the links consistent; informational, written to the session log.
  package struct Outcome: Equatable, Sendable {
    package let migrated: [String]
    package let conflicts: [String]
  }

  /// The single Windows profile folder Wine created. Wine 11 (CrossOver lineage) names it `crossover`
  /// whatever `USER` says, so the name is discovered rather than assumed.
  package func windowsProfile() throws(LauncherError) -> URL {
    let users = paths.prefix.appendingPathComponent("drive_c/users")
    do {
      let candidates = try files.contentsOfDirectory(
        at: users, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      ).filter { $0.lastPathComponent.caseInsensitiveCompare("Public") != .orderedSame }
      guard candidates.count == 1, let profile = candidates.first,
        try profile.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory
          == true,
        try profile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
      else {
        throw LauncherError.operation(
          "Wine's user folder is not what this app expects. Keep the player folder and check the log."
        )
      }
      return profile
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Cannot find Wine's user folder: \(error.localizedDescription)")
    }
  }

  /// Idempotently links both folders into the Wine profile.
  /// - Precondition: Wine is stopped, guest isolation has run and the session lock is held.
  @discardableResult
  package func install() throws(LauncherError) -> Outcome {
    do {
      try files.createDirectory(at: documents, withIntermediateDirectories: true)
      try files.createDirectory(at: localData, withIntermediateDirectories: true)
      let profile = try windowsProfile()
      var migrated: [String] = []
      var conflicted: [String] = []
      for (relative, persistent) in [
        ("Documents/My Games/Far Cry 2", documents),
        ("AppData/Local/My Games/Far Cry 2", localData),
      ] {
        let link = profile.appendingPathComponent(relative)
        try makeParents(of: link, below: profile)
        switch try state(of: link, expecting: persistent) {
        case .linked: continue
        case .absent: break
        case .directory:
          if try BoundedTree.inventory(persistent).files.isEmpty {
            try files.removeItem(at: persistent)
            try files.moveItem(at: link, to: persistent)
            migrated.append(relative)
          } else {
            try files.createDirectory(at: conflicts, withIntermediateDirectories: true)
            let aside = conflicts.appendingPathComponent(UUID().uuidString)
            try files.moveItem(at: link, to: aside)
            conflicted.append(relative)
          }
        }
        try files.createSymbolicLink(
          atPath: link.path,
          withDestinationPath: Self.relativePath(
            from: link.deletingLastPathComponent(), to: persistent))
      }
      return Outcome(migrated: migrated, conflicts: conflicted)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not link Far Cry 2's player data: \(error.localizedDescription)")
    }
  }

  private enum LinkState { case absent, linked, directory }

  private func state(of link: URL, expecting persistent: URL) throws -> LinkState {
    guard let values = try? link.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    else { return .absent }
    if values.isSymbolicLink == true {
      let destination = try files.destinationOfSymbolicLink(atPath: link.path)
      let expected = Self.relativePath(from: link.deletingLastPathComponent(), to: persistent)
      guard destination == expected else {
        throw LauncherError.operation(
          "A Far Cry 2 player folder link points somewhere unexpected; leaving it untouched.")
      }
      return .linked
    }
    guard values.isDirectory == true else {
      throw LauncherError.operation(
        "A file blocks Far Cry 2's player folder; leaving it untouched.")
    }
    return .directory
  }

  /// Creates missing folders between the Wine profile and the link, refusing any that is a link.
  private func makeParents(of link: URL, below profile: URL) throws {
    var current = profile
    let relative = link.deletingLastPathComponent().path.dropFirst(profile.path.count + 1)
    for component in relative.split(separator: "/") {
      current.appendPathComponent(String(component))
      if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
        guard values.isSymbolicLink != true, values.isDirectory == true else {
          throw LauncherError.operation(
            "Wine's \(component) folder is a link. Guest isolation must run before play.")
        }
      } else {
        try files.createDirectory(at: current, withIntermediateDirectories: false)
      }
    }
  }

  /// A relative path from one folder to another; both are resolved so links cannot make it wrong.
  static func relativePath(from directory: URL, to target: URL) -> String {
    let from = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let to = target.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    var common = 0
    while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
    let ups = Array(repeating: "..", count: from.count - common)
    return (ups + to[common...]).joined(separator: "/")
  }
}
