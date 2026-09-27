import Foundation

/// Bundle-relative executables and user-owned state locations.
package struct AppPaths {
  package let bundle: URL
  package let support: URL
  package let kind: GameKind

  /// Rejects a support directory inside the application, including symbolic links.
  package init(bundle: URL, support: URL, game: GameKind = .nfsmw) throws(LauncherError) {
    let bundle = bundle.standardizedFileURL.resolvingSymlinksInPath()
    let support = support.standardizedFileURL.resolvingSymlinksInPath()
    guard bundle.isFileURL, support.isFileURL,
      support.path != bundle.path, !support.path.hasPrefix(bundle.path + "/")
    else {
      throw .operation("Player data must be stored outside the app.")
    }
    self.bundle = bundle
    self.support = support
    self.kind = game
  }

  package var resources: URL { bundle.appendingPathComponent("Contents/Resources") }
  package var template: URL { resources.appendingPathComponent("Game") }
  package var wine: URL { bundle.appendingPathComponent("Contents/SharedSupport/Wine/bin/wine") }
  package var wineServer: URL {
    wine.deletingLastPathComponent().appendingPathComponent("wineserver")
  }
  package var sidecar: URL { bundle.appendingPathComponent("Contents/Helpers/x87sidecar") }
  package var session: URL { bundle.appendingPathComponent("Contents/Helpers/" + kind.helper) }
  package var data: URL { support.appendingPathComponent("Data") }
  package var prefix: URL { data.appendingPathComponent("Prefix") }
  package var saves: URL { data.appendingPathComponent("Saves") }
  package var currentGame: URL { data.appendingPathComponent("Current/Game") }

  /// Indicates whether setup can proceed; the session verifies files before installation.
  package var hasGameData: Bool {
    [template, currentGame].contains {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent(kind.executable).path)
    }
  }

  /// The private working copy for a validated manifest version.
  package func game(version: String) -> URL {
    data.appendingPathComponent("Versions").appendingPathComponent(version).appendingPathComponent(
      "Game")
  }
}
