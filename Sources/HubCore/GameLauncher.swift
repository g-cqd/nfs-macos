import Foundation

/// Finds what starts a game.
package enum GameLauncher {
  /// The wrapped app that owns a bundled game's files, or `nil` for any other source.
  ///
  /// A wrapped game's root is `<Name>.app/Contents/Resources/Game`; the app is three levels up.
  /// Returns `nil` unless that folder really is inside an existing `.app` folder.
  package static func wrappedApp(for entry: CatalogEntry) -> URL? {
    guard entry.source == .bundle else { return nil }
    let root = entry.root.standardizedFileURL
    guard Array(root.pathComponents.suffix(3)) == ["Contents", "Resources", "Game"] else {
      return nil
    }
    let app = root.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    guard app.pathExtension == "app" else { return nil }
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: app.path, isDirectory: &isFolder), isFolder.boolValue
    else { return nil }
    return app
  }
}
