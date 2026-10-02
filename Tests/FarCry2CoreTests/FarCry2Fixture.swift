import FarCry2Core
import Foundation
import LauncherCore

/// A player folder shaped like a freshly initialised Wine prefix, with invented profile contents.
struct FarCry2Fixture {
  /// Attribute names and sample values come from public reports of the game's profile; the file is
  /// otherwise invented. It is not game data.
  static let profileXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <GamerProfile>
      <!-- <RenderProfile Platform="d3d10"> inside a comment must be ignored -->
      <RenderProfile MultiSampleMode="0" AlphaToCoverage="0" ResolutionX="1440" ResolutionY="900" Quality="customd3d10" Fullscreen="0" Maximized="0" VSync="1" RefreshRate="0" DisableMip0Loading="1" Platform="d3d10a" ShowFPS="0" AllowAsynchShaderLoading="1">
        <CustomQuality>
          <quality id="custom" ResolutionX="800" ResolutionY="600" EnvironmentQuality="2" TextureQuality="2"/>
          <quality id="customd3d10" ResolutionX="800" ResolutionY="600" EnvironmentQuality="2"/>
        </CustomQuality>
      </RenderProfile>
      <Audio Volume="0.8"/>
    </GamerProfile>

    """

  let root: URL
  let paths: AppPaths
  var user: FarCry2UserData { FarCry2UserData(paths: paths) }
  var wineProfile: URL { paths.prefix.appendingPathComponent("drive_c/users/crossover") }

  init(profileName: String = "crossover", extraProfiles: [String] = []) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    paths = try AppPaths(
      bundle: root.appendingPathComponent("Far Cry 2.app"),
      support: root.appendingPathComponent("Support"), game: .farcry2)
    try buildPrefix(profileName: profileName, extraProfiles: extraProfiles)
    try FileManager.default.createDirectory(
      at: paths.saves, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: paths.currentGame.deletingLastPathComponent(), withIntermediateDirectories: true)
  }

  /// Wine 11 creates real `Documents` and `AppData/Local` folders inside the prefix.
  func buildPrefix(profileName: String = "crossover", extraProfiles: [String] = []) throws {
    let files = FileManager.default
    for name in [profileName, "Public"] + extraProfiles {
      for folder in ["Documents", "AppData/Local", "Saved Games"] {
        try files.createDirectory(
          at: paths.prefix.appendingPathComponent("drive_c/users/\(name)/\(folder)"),
          withIntermediateDirectories: true)
      }
    }
  }

  /// Installs a game generation whose `bin` can hold `mtld3d.conf`.
  func installGameFolder(renderer: String? = nil) throws {
    let game = paths.game(version: "test").appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    if let renderer {
      try Data(renderer.utf8).write(to: game.appendingPathComponent("mtld3d.conf"))
    }
    try? FileManager.default.removeItem(at: paths.data.appendingPathComponent("Current"))
    try FileManager.default.createSymbolicLink(
      atPath: paths.data.appendingPathComponent("Current").path,
      withDestinationPath: "Versions/test")
  }

  func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  func remove() {
    do { try FileManager.default.removeItem(at: root) } catch { print("Cleanup failed: \(error)") }
  }
}
