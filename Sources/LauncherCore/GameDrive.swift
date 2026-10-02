import Foundation

/// Maps one game's private folder as drive `G:` so Wine can resolve the native working directory.
///
/// Wine can open `C:\<folder>` (a link to the active generation) but cannot reverse-map a native
/// current directory through that link; without this drive the game starts in `C:\windows`. The mapping
/// covers only the private game directory and never exposes the user's home or the filesystem root.
/// - Note: This is the generic form of `CoD4GameDrive`; CoD4 keeps its own copy until its owner
///   chooses to delegate here.
package struct GameDrive {
  package let paths: AppPaths
  private var mapping: URL { paths.prefix.appendingPathComponent("dosdevices/g:") }
  private let destination = "../../Current/Game"

  package init(paths: AppPaths) { self.paths = paths }

  /// Adds a game-only drive without replacing an existing mapping.
  /// - Precondition: Wine is stopped and the caller holds the session lock.
  package func install() throws(LauncherError) {
    do {
      let root = paths.support.resolvingSymlinksInPath().path + "/"
      guard mapping.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root),
        paths.currentGame.resolvingSymlinksInPath().path.hasPrefix(root),
        try paths.currentGame.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      else {
        throw LauncherError.operation(
          "The game's working directory must stay inside its player folder.")
      }
      try FileManager.default.createSymbolicLink(
        atPath: mapping.path, withDestinationPath: destination)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not map the game's working directory: \(error.localizedDescription)")
    }
  }

  /// Removes only the mapping created for this session; a changed mapping is left untouched.
  /// - Precondition: Wine is stopped and the caller holds the session lock.
  package func remove() throws(LauncherError) {
    do {
      let files = FileManager.default
      guard try files.destinationOfSymbolicLink(atPath: mapping.path) == destination else {
        throw LauncherError.operation("The game drive changed during play; leaving it untouched.")
      }
      try files.removeItem(at: mapping)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not remove the game drive: \(error.localizedDescription)")
    }
  }

  /// Removes a mapping left by an interrupted session; does nothing when no mapping exists.
  package func removeStale() throws(LauncherError) {
    var isLeftover = false
    do {
      isLeftover =
        try FileManager.default.destinationOfSymbolicLink(atPath: mapping.path) == destination
    } catch { return }
    if isLeftover { try remove() }
  }
}
