import Foundation
import LauncherCore

/// Maps CoD4's private files so Wine can resolve its native working directory.
package struct CoD4GameDrive {
  package let paths: AppPaths
  private var mapping: URL { paths.prefix.appendingPathComponent("dosdevices/g:") }
  private let destination = "../../Current/Game"

  package init(paths: AppPaths) { self.paths = paths }

  /// Adds a game-only drive without exposing the user's home or replacing a mapping.
  /// - Precondition: Wine is stopped and the caller holds the session lock.
  package func install() throws(LauncherError) {
    do {
      let root = paths.support.resolvingSymlinksInPath().path + "/"
      guard mapping.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root),
        paths.currentGame.resolvingSymlinksInPath().path.hasPrefix(root),
        try paths.currentGame.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      else {
        throw LauncherError.operation(
          "CoD4's working directory must stay inside its player folder.")
      }
      // Wine cannot reverse-map a native cwd through the C:\CoD4 directory symlink.
      try FileManager.default.createSymbolicLink(
        atPath: mapping.path, withDestinationPath: destination)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not map CoD4's working directory: \(error.localizedDescription)")
    }
  }

  /// Removes only the mapping created for this session.
  /// - Precondition: Wine is stopped and the caller holds the session lock.
  package func remove() throws(LauncherError) {
    do {
      let files = FileManager.default
      guard try files.destinationOfSymbolicLink(atPath: mapping.path) == destination else {
        throw LauncherError.operation(
          "CoD4's game drive changed during play; leaving it untouched.")
      }
      try files.removeItem(at: mapping)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not remove CoD4's game drive: \(error.localizedDescription)")
    }
  }
}
