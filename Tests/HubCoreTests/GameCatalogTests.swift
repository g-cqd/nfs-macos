import Foundation
import Testing

@testable import HubCore

@Suite struct GameCatalogTests {
  // MARK: - Bundle tests

  @Test func bundleWithContent() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundlesDir = tempDir.appendingPathComponent("Bundles", isDirectory: true)
    try FileManager.default.createDirectory(at: bundlesDir, withIntermediateDirectories: true)

    let appDir = bundlesDir
      .appendingPathComponent("Test Game Bundled 20261001-abc123.app", isDirectory: true)
    let resourcesDir = appDir
      .appendingPathComponent("Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

    let gameDir = resourcesDir.appendingPathComponent("Game", isDirectory: true)
    try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

    try "dummy game file".write(
      to: gameDir.appendingPathComponent("game.exe"),
      atomically: true,
      encoding: .utf8
    )

    let recipeJSON = """
      {
        "gameID": "test-game",
        "displayName": "Test Game"
      }
      """
    try recipeJSON.write(
      to: resourcesDir.appendingPathComponent("bundle-recipe.json"),
      atomically: true,
      encoding: .utf8
    )

    let layout = HubLayout(
      hub: tempDir,
      bundles: bundlesDir,
      steam: tempDir.appendingPathComponent("Steam", isDirectory: true),
      eaGames: tempDir.appendingPathComponent("EA Games", isDirectory: true),
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)

    #expect(entries.count == 1)
    guard !entries.isEmpty else { return }
    #expect(entries[0].title == "Test Game")
    #expect(entries[0].id.rawValue == "test-game")
    #expect(entries[0].source == .bundle)
    #expect(entries[0].kindID == nil)
  }

  @Test func bundleEmptyGameFolderSkipped() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundlesDir = tempDir.appendingPathComponent("Bundles", isDirectory: true)
    try FileManager.default.createDirectory(at: bundlesDir, withIntermediateDirectories: true)

    let appDir = bundlesDir
      .appendingPathComponent("Empty Game 20261001-abc123.app", isDirectory: true)
    let gameDir = appDir
      .appendingPathComponent("Contents/Resources/Game", isDirectory: true)
    try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

    let layout = HubLayout(
      hub: tempDir,
      bundles: bundlesDir,
      steam: tempDir.appendingPathComponent("Steam", isDirectory: true),
      eaGames: tempDir.appendingPathComponent("EA Games", isDirectory: true),
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)
    #expect(entries.isEmpty)
  }

  // MARK: - Steam tests

  @Test func steamAppManifest() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let steamappsDir = steamDir.appendingPathComponent("steamapps", isDirectory: true)
    try FileManager.default.createDirectory(at: steamappsDir, withIntermediateDirectories: true)

    let gameDir = steamappsDir
      .appendingPathComponent("common/TestGame123", isDirectory: true)
    try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
    try "game content".write(
      to: gameDir.appendingPathComponent("game.exe"),
      atomically: true,
      encoding: .utf8
    )

    let manifestACF = """
      "AppState"
      {
        "appid"		"123456"
        "name"		"Test Game"
        "installdir"		"TestGame123"
        "SizeOnDisk"		"5000000000"
        "StateFlags"		"4"
      }
      """
    try manifestACF.write(
      to: steamappsDir.appendingPathComponent("appmanifest_123456.acf"),
      atomically: true,
      encoding: .utf8
    )

    let layout = HubLayout(
      hub: tempDir,
      bundles: tempDir.appendingPathComponent("Bundles", isDirectory: true),
      steam: steamDir,
      eaGames: tempDir.appendingPathComponent("EA Games", isDirectory: true),
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)

    #expect(entries.count == 1)
    #expect(entries[0].title == "Test Game")
    #expect(entries[0].id.rawValue == "steam-123456")
    #expect(entries[0].source == .steam)
    #expect(entries[0].sizeBytes == 5000000000)
  }

  @Test func steamMissingInstallFolderSkipped() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let steamappsDir = steamDir.appendingPathComponent("steamapps", isDirectory: true)
    try FileManager.default.createDirectory(at: steamappsDir, withIntermediateDirectories: true)

    let manifestACF = """
      "AppState"
      {
        "appid"		"987654"
        "name"		"Missing Game"
        "installdir"		"MissingGame"
        "SizeOnDisk"		"1000000000"
      }
      """
    try manifestACF.write(
      to: steamappsDir.appendingPathComponent("appmanifest_987654.acf"),
      atomically: true,
      encoding: .utf8
    )

    let layout = HubLayout(
      hub: tempDir,
      bundles: tempDir.appendingPathComponent("Bundles", isDirectory: true),
      steam: steamDir,
      eaGames: tempDir.appendingPathComponent("EA Games", isDirectory: true),
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)
    #expect(entries.isEmpty)
  }

  @Test func steamVDFSingleLineFormat() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let lib2 = steamDir.appendingPathComponent("Lib2", isDirectory: true)
    try FileManager.default.createDirectory(
      at: steamDir.appendingPathComponent("steamapps"), withIntermediateDirectories: true)

    // Real VDF layout: tab-separated `"key"<tabs>"value"` pairs on one line, numbered sections, and
    // a nested `apps` block whose keys must not be taken for library paths.
    let libFoldersVDF = """
      "libraryfolders"
      {
      \t"0"
      \t{
      \t\t"path"\t\t"\(steamDir.path)"
      \t\t"label"\t\t""
      \t\t"apps"
      \t\t{
      \t\t\t"111111"\t\t"1000000"
      \t\t}
      \t}
      \t"1"
      \t{
      \t\t"path"\t\t"\(lib2.path)"
      \t\t"apps"
      \t\t{
      \t\t\t"111111"\t\t"1000000"
      \t\t}
      \t}
      }
      """
    try write(libFoldersVDF, to: steamDir.appendingPathComponent("steamapps/libraryfolders.vdf"))
    try writeSteamGame(
      library: lib2, appID: "111111", name: "VDF Test Game", installDir: "TestGame")

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.map(\.id.rawValue) == ["steam-111111"])
    #expect(entries.first?.title == "VDF Test Game")
    #expect(
      entries.first?.root.path
        == lib2.appendingPathComponent("steamapps/common/TestGame").path)
  }

  @Test func steamVDFRealWindowsPathFormat() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let lib2 = steamDir.appendingPathComponent("Lib2", isDirectory: true)
    try FileManager.default.createDirectory(
      at: steamDir.appendingPathComponent("steamapps"), withIntermediateDirectories: true)

    // Real format from Steam on Windows or Wine: `Z:` drive, escaped backslashes, CRLF line ends.
    func windowsPath(_ url: URL) -> String {
      "Z:" + url.path.replacingOccurrences(of: "/", with: "\\\\")
    }
    let libFoldersVDF = [
      "\"libraryfolders\"",
      "{",
      "\t\"0\"",
      "\t{",
      "\t\t\"path\"\t\t\"\(windowsPath(steamDir))\"",
      "\t\t\"apps\"",
      "\t\t{",
      "\t\t\t\"222222\"\t\t\"1000000\"",
      "\t\t}",
      "\t}",
      "\t\"1\"",
      "\t{",
      "\t\t\"path\"\t\t\"\(windowsPath(lib2))\"",
      "\t}",
      "}",
    ].joined(separator: "\r\n")
    try write(libFoldersVDF, to: steamDir.appendingPathComponent("steamapps/libraryfolders.vdf"))
    try writeSteamGame(
      library: lib2, appID: "222222", name: "Windows Path Game", installDir: "TestGame",
      lineEnding: "\r\n")

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.map(\.id.rawValue) == ["steam-222222"])
    #expect(entries.first?.title == "Windows Path Game")
    #expect(
      entries.first?.root.path
        == lib2.appendingPathComponent("steamapps/common/TestGame").path)
  }

  @Test func steamVDFHostilePathRejected() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let outside = tempDir.appendingPathComponent("Outside", isDirectory: true)
    let inside = steamDir.appendingPathComponent("Lib2", isDirectory: true)
    try FileManager.default.createDirectory(
      at: steamDir.appendingPathComponent("steamapps"), withIntermediateDirectories: true)

    // A REAL library outside the Steam folder, with a valid game in it.
    try writeSteamGame(library: outside, appID: "666", name: "Outside Game", installDir: "Evil")
    // A library inside the Steam folder, so the scan is known to read the file.
    try writeSteamGame(library: inside, appID: "777", name: "Inside Game", installDir: "Good")

    let libFoldersVDF = """
      "libraryfolders"
      {
        "0"
        {
          "path"    "\(outside.path)"
        }
        "1"
        {
          "path"    "\(steamDir.path)/../Outside"
        }
        "2"
        {
          "path"    "Outside"
        }
        "3"
        {
          "path"    "\(inside.path)"
        }
      }
      """
    try write(libFoldersVDF, to: steamDir.appendingPathComponent("steamapps/libraryfolders.vdf"))

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.map(\.id.rawValue) == ["steam-777"])
  }

  @Test func steamVDFSymlinkedLibraryOutsideRejected() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let outside = tempDir.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(
      at: steamDir.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
    try writeSteamGame(library: outside, appID: "666", name: "Outside Game", installDir: "Evil")

    // `Steam/Link` is a link to the outside library, once absolute and once relative.
    try FileManager.default.createSymbolicLink(
      at: steamDir.appendingPathComponent("Link"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(
      atPath: steamDir.appendingPathComponent("RelLink").path, withDestinationPath: "../Outside")

    let libFoldersVDF = """
      "libraryfolders"
      {
        "0"
        {
          "path"    "\(steamDir.path)/Link"
        }
        "1"
        {
          "path"    "\(steamDir.path)/RelLink"
        }
      }
      """
    try write(libFoldersVDF, to: steamDir.appendingPathComponent("steamapps/libraryfolders.vdf"))

    #expect(GameCatalog.scan(layout: makeLayout(tempDir)).isEmpty)
  }

  @Test(arguments: ["../../../Documents", "..", ".", "", "Good/Sub", "Good\\Sub", "Good/../Good"])
  func steamInstallDirEscapeRejected(installDir: String) throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let common = steamDir.appendingPathComponent("steamapps/common", isDirectory: true)
    // Every name above would reach an existing folder if it were appended unchecked.
    try FileManager.default.createDirectory(
      at: common.appendingPathComponent("Good/Sub"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: common.appendingPathComponent("Good\\Sub"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: tempDir.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    try write(
      acf(appID: "42", name: "Escaping Game", installDir: installDir),
      to: steamDir.appendingPathComponent("steamapps/appmanifest_42.acf"))

    #expect(GameCatalog.scan(layout: makeLayout(tempDir)).isEmpty)
  }

  @Test func steamInstallDirSymlinkOutOfLibraryRejected() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let common = steamDir.appendingPathComponent("steamapps/common", isDirectory: true)
    let outside = tempDir.appendingPathComponent("Outside/Game", isDirectory: true)
    try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: common.appendingPathComponent("Linked"), withDestinationURL: outside)
    try write(
      acf(appID: "43", name: "Linked Game", installDir: "Linked"),
      to: steamDir.appendingPathComponent("steamapps/appmanifest_43.acf"))

    #expect(GameCatalog.scan(layout: makeLayout(tempDir)).isEmpty)
  }

  @Test func steamACFEscapedQuotesAndNestedBlocks() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let steamapps = steamDir.appendingPathComponent("steamapps", isDirectory: true)
    try FileManager.default.createDirectory(
      at: steamapps.appendingPathComponent("common/RealDir"), withIntermediateDirectories: true)

    // The nested blocks repeat top-level keys with other values: they must not win.
    let manifest = [
      "\"AppState\"",
      "{",
      "\t\"appid\"\t\t\"99\"",
      "\t\"name\"\t\t\"Tom \\\"X\\\" \\\\ Co\"",
      "\t\"installdir\"\t\t\"RealDir\"",
      "\t\"UserConfig\"",
      "\t{",
      "\t\t\"name\"\t\t\"Nested Name\"",
      "\t\t\"installdir\"\t\t\"../Wrong\"",
      "\t}",
      "\t\"MountedConfig\"",
      "\t{",
      "\t\t\"appid\"\t\t\"1\"",
      "\t}",
      "}",
    ].joined(separator: "\r\n")
    try write(manifest, to: steamapps.appendingPathComponent("appmanifest_99.acf"))

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.count == 1)
    #expect(entries.first?.id.rawValue == "steam-99")
    #expect(entries.first?.title == "Tom \"X\" \\ Co")
    #expect(entries.first?.root.lastPathComponent == "RealDir")
  }

  // MARK: - EA tests

  @Test func eaGameWithExe() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let eaGamesDir = tempDir
      .appendingPathComponent("EA Games", isDirectory: true)
    try FileManager.default.createDirectory(at: eaGamesDir, withIntermediateDirectories: true)

    let publisherDir = eaGamesDir.appendingPathComponent("EA", isDirectory: true)
    let gameDir = publisherDir
      .appendingPathComponent("TestEAGame", isDirectory: true)
    try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

    try "game exe content".write(
      to: gameDir.appendingPathComponent("game.exe"),
      atomically: true,
      encoding: .utf8
    )

    let layout = HubLayout(
      hub: tempDir,
      bundles: tempDir.appendingPathComponent("Bundles", isDirectory: true),
      steam: tempDir.appendingPathComponent("Steam", isDirectory: true),
      eaGames: eaGamesDir,
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)

    #expect(entries.count == 1)
    #expect(entries[0].title == "TestEAGame")
    #expect(entries[0].source == .ea)
  }

  @Test func eaGameWithInstallerdata() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let eaGamesDir = tempDir
      .appendingPathComponent("EA Games", isDirectory: true)
    try FileManager.default.createDirectory(at: eaGamesDir, withIntermediateDirectories: true)

    let publisherDir = eaGamesDir.appendingPathComponent("EA", isDirectory: true)
    let gameDir = publisherDir
      .appendingPathComponent("Battlefield4", isDirectory: true)
    let installerDir = gameDir.appendingPathComponent("__Installer", isDirectory: true)
    try FileManager.default.createDirectory(at: installerDir, withIntermediateDirectories: true)

    let xmlContent = """
      <?xml version='1.0' encoding='utf-8'?>
      <DiPManifest version="4.0">
        <gameTitles>
          <gameTitle locale="en_US">Battlefield 4</gameTitle>
        </gameTitles>
      </DiPManifest>
      """
    try xmlContent.write(
      to: installerDir.appendingPathComponent("installerdata.xml"),
      atomically: true,
      encoding: .utf8
    )

    let layout = HubLayout(
      hub: tempDir,
      bundles: tempDir.appendingPathComponent("Bundles", isDirectory: true),
      steam: tempDir.appendingPathComponent("Steam", isDirectory: true),
      eaGames: eaGamesDir,
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)

    #expect(entries.count == 1)
    #expect(entries[0].title == "Battlefield 4")
    #expect(entries[0].source == .ea)
  }

  /// Writes `<root>/<name>/__Installer/installerdata.xml` titled `title`, the mark of an EA game.
  private func writeEAGame(_ name: String, title: String, in root: URL) throws {
    let xml = """
      <?xml version='1.0' encoding='utf-8'?>
      <DiPManifest version="4.0">
        <gameTitles>
          <gameTitle locale="en_US">\(title)</gameTitle>
        </gameTitles>
      </DiPManifest>
      """
    try write(xml, to: root.appendingPathComponent("\(name)/__Installer/installerdata.xml"))
  }

  @Test func eaFlatLayoutYieldsOneEntryPerGame() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let eaGamesDir = tempDir.appendingPathComponent("EA Games", isDirectory: true)
    // Folder name, XML title and the id the folder name slugs to. One title differs from its folder.
    let games: [(folder: String, title: String, id: String)] = [
      ("Battlefield 3", "Battlefield 3", "ea-battlefield-3"),
      ("Battlefield 4", "Battlefield 4", "ea-battlefield-4"),
      ("Crysis 3", "Crysis 3", "ea-crysis-3"),
      ("F1 24", "F1 24", "ea-f1-24"),
      ("Need for Speed", "Need for Speed (2015)", "ea-need-for-speed"),
    ]
    for game in games {
      try writeEAGame(game.folder, title: game.title, in: eaGamesDir)
    }

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.count == 5)
    #expect(entries.allSatisfy { $0.source == .ea })
    for game in games {
      let entry = entries.first { $0.id.rawValue == game.id }
      #expect(entry?.title == game.title)
      #expect(entry?.root.path == eaGamesDir.appendingPathComponent(game.folder).path)
    }
  }

  @Test func eaContainerFolderYieldsEveryGameInside() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let container = tempDir.appendingPathComponent("EA Games/BF4", isDirectory: true)
    let names = ["Battlefield 4", "Crysis 3", "F1 24"]
    for name in names {
      try writeEAGame(name, title: name, in: container)
    }

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(Set(entries.map(\.title)) == Set(names))
    #expect(entries.count == 3)
    for name in names {
      #expect(
        entries.first { $0.title == name }?.root.path
          == container.appendingPathComponent(name).path)
    }
  }

  @Test func eaDeepestLayoutFound() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let eaGamesDir = tempDir.appendingPathComponent("EA Games", isDirectory: true)
    try writeEAGame("Game", title: "Game", in: eaGamesDir.appendingPathComponent("Pub/Box"))

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.map(\.id.rawValue) == ["ea-game"])
    #expect(entries.first?.root.path == eaGamesDir.appendingPathComponent("Pub/Box/Game").path)
  }

  @Test func eaInstallerMarkerBeatsStrayExecutableAbove() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let eaGamesDir = tempDir.appendingPathComponent("EA Games", isDirectory: true)
    try write("exe", to: eaGamesDir.appendingPathComponent("EA/Uninstall.exe"))
    try writeEAGame("BF4", title: "Battlefield 4", in: eaGamesDir.appendingPathComponent("EA"))

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.map(\.title) == ["Battlefield 4"])
    #expect(entries.first?.root.path == eaGamesDir.appendingPathComponent("EA/BF4").path)
  }

  @Test func eaHiddenFoldersSkipped() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let eaGamesDir = tempDir.appendingPathComponent("EA Games", isDirectory: true)
    try writeEAGame("Hidden", title: "Hidden", in: eaGamesDir.appendingPathComponent(".Trashes"))
    try writeEAGame(".Backup", title: "Backup", in: eaGamesDir.appendingPathComponent("Box"))
    try writeEAGame("Shown", title: "Shown", in: eaGamesDir.appendingPathComponent("Box"))

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.map(\.title) == ["Shown"])
  }

  // MARK: - Epic tests

  @Test func epicGameByExe() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let epicDir = tempDir.appendingPathComponent("Epic", isDirectory: true)
    try FileManager.default.createDirectory(at: epicDir, withIntermediateDirectories: true)

    let gameDir = epicDir.appendingPathComponent("TestEpicGame", isDirectory: true)
    try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

    try "epic game".write(
      to: gameDir.appendingPathComponent("game.exe"),
      atomically: true,
      encoding: .utf8
    )

    let layout = HubLayout(
      hub: tempDir,
      bundles: tempDir.appendingPathComponent("Bundles", isDirectory: true),
      steam: tempDir.appendingPathComponent("Steam", isDirectory: true),
      eaGames: tempDir.appendingPathComponent("EA Games", isDirectory: true),
      epic: epicDir,
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)

    #expect(entries.count == 1)
    #expect(entries[0].title == "TestEpicGame")
    #expect(entries[0].source == .epic)
  }

  @Test func epicWindowsPathEscapeBlocked() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let epicDir = tempDir.appendingPathComponent("Epic", isDirectory: true)
    let outside = tempDir.appendingPathComponent("Outside", isDirectory: true)
    let manifestDir = epicDir.appendingPathComponent("Manifests", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
    // Real folders on the far side of every link below.
    try FileManager.default.createDirectory(
      at: outside.appendingPathComponent("X"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: tempDir.appendingPathComponent("Users/gc/Documents"), withIntermediateDirectories: true)

    // `Games` is a link out of the Epic folder (absolute), `Rel` another (relative).
    try FileManager.default.createSymbolicLink(
      at: epicDir.appendingPathComponent("Games"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(
      atPath: epicDir.appendingPathComponent("Rel").path, withDestinationPath: "../Outside")

    let locations = [
      "C:\\\\..\\\\..\\\\Users\\\\gc\\\\Documents",
      "C:\\\\Games\\\\X",
      "C:\\\\Rel\\\\X",
      "D:/Games/X",
    ]
    for (index, location) in locations.enumerated() {
      try write(
        """
        {
          "DisplayName": "Hostile Game \(index)",
          "InstallLocation": "\(location)",
          "LaunchExecutable": "game.exe"
        }
        """,
        to: manifestDir.appendingPathComponent("test\(index).item"))
    }

    #expect(GameCatalog.scan(layout: makeLayout(tempDir)).isEmpty)
  }

  @Test func epicLinkInsideEpicFolderAllowed() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let epicDir = tempDir.appendingPathComponent("Epic", isDirectory: true)
    let manifestDir = epicDir.appendingPathComponent("Manifests", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: epicDir.appendingPathComponent("Real/X"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: epicDir.appendingPathComponent("Alias").path, withDestinationPath: "Real")
    try write(
      """
      {"DisplayName": "Aliased", "InstallLocation": "C:\\\\Alias\\\\X"}
      """,
      to: manifestDir.appendingPathComponent("ok.item"))

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.map(\.title) == ["Aliased"])
  }

  @Test func epicBareDriveInstallLocationRejected() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let epicDir = tempDir.appendingPathComponent("Epic", isDirectory: true)
    let manifestDir = epicDir.appendingPathComponent("Manifests", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)

    for (index, location) in ["C:", "C:\\\\", "C:\\\\."].enumerated() {
      try write(
        """
        {"DisplayName": "Whole Epic Folder", "InstallLocation": "\(location)"}
        """,
        to: manifestDir.appendingPathComponent("bare\(index).item"))
    }

    #expect(GameCatalog.scan(layout: makeLayout(tempDir)).isEmpty)
  }

  // MARK: - Ubisoft tests

  @Test func ubisoftGame() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let ubisoftDir = tempDir
      .appendingPathComponent("Ubisoft", isDirectory: true)
    try FileManager.default.createDirectory(at: ubisoftDir, withIntermediateDirectories: true)

    let gamesDir = ubisoftDir.appendingPathComponent("games", isDirectory: true)
    let gameDir = gamesDir.appendingPathComponent("TestUbisoftGame", isDirectory: true)
    try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

    try "ubisoft game".write(
      to: gameDir.appendingPathComponent("game.exe"),
      atomically: true,
      encoding: .utf8
    )

    let layout = HubLayout(
      hub: tempDir,
      bundles: tempDir.appendingPathComponent("Bundles", isDirectory: true),
      steam: tempDir.appendingPathComponent("Steam", isDirectory: true),
      eaGames: tempDir.appendingPathComponent("EA Games", isDirectory: true),
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: ubisoftDir,
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)

    #expect(entries.count == 1)
    #expect(entries[0].title == "TestUbisoftGame")
    #expect(entries[0].source == .ubisoft)
  }

  // MARK: - Sorting and deduplication tests

  @Test func sortingByTitleThenID() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundlesDir = tempDir.appendingPathComponent("Bundles", isDirectory: true)
    try FileManager.default.createDirectory(at: bundlesDir, withIntermediateDirectories: true)

    for (index, bundleID) in ["z-id", "a-id"].enumerated() {
      let appDir = bundlesDir
        .appendingPathComponent("Game A 202610\(index + 1)-abc123.app", isDirectory: true)
      let gameDir = appDir.appendingPathComponent("Contents/Resources/Game", isDirectory: true)
      try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
      try "content".write(
        to: gameDir.appendingPathComponent("file.txt"),
        atomically: true,
        encoding: .utf8
      )

      let recipe = """
        {"gameID": "\(bundleID)", "displayName": "Game A"}
        """
      let resourcesDir = appDir.appendingPathComponent("Contents/Resources", isDirectory: true)
      try recipe.write(
        to: resourcesDir.appendingPathComponent("bundle-recipe.json"),
        atomically: true,
        encoding: .utf8
      )
    }

    let layout = HubLayout(
      hub: tempDir,
      bundles: bundlesDir,
      steam: tempDir.appendingPathComponent("Steam", isDirectory: true),
      eaGames: tempDir.appendingPathComponent("EA Games", isDirectory: true),
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)

    #expect(entries.count == 2)
    guard entries.count >= 2 else { return }
    #expect(entries[0].id.rawValue == "a-id")
    #expect(entries[1].id.rawValue == "z-id")
  }

  @Test func idDeduplicationOnCollision() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundlesDir = tempDir.appendingPathComponent("Bundles", isDirectory: true)
    try FileManager.default.createDirectory(at: bundlesDir, withIntermediateDirectories: true)

    // Create two apps with same gameID
    for index in 0..<2 {
      let appDir = bundlesDir
        .appendingPathComponent("Game X \(index)-abc123.app", isDirectory: true)
      let gameDir = appDir.appendingPathComponent("Contents/Resources/Game", isDirectory: true)
      try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
      try "content".write(
        to: gameDir.appendingPathComponent("file.txt"),
        atomically: true,
        encoding: .utf8
      )

      let recipe = """
        {"gameID": "same-id", "displayName": "Game X"}
        """
      let resourcesDir = appDir.appendingPathComponent("Contents/Resources", isDirectory: true)
      try recipe.write(
        to: resourcesDir.appendingPathComponent("bundle-recipe.json"),
        atomically: true,
        encoding: .utf8
      )
    }

    let layout = HubLayout(
      hub: tempDir,
      bundles: bundlesDir,
      steam: tempDir.appendingPathComponent("Steam", isDirectory: true),
      eaGames: tempDir.appendingPathComponent("EA Games", isDirectory: true),
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )

    let entries = GameCatalog.scan(layout: layout)

    #expect(entries.count == 2)
    guard entries.count >= 2 else { return }
    // The first bundle (by path) keeps the ID, the second takes `-2`
    #expect(entries[0].id.rawValue == "same-id")
    #expect(entries[1].id.rawValue == "same-id-2")
  }

  // MARK: - Symlinked folders

  @Test func eaSymlinkedPublisherAndGameFollowed() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let eaGamesDir = tempDir.appendingPathComponent("EA Games", isDirectory: true)
    let elsewhere = tempDir.appendingPathComponent("Elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: eaGamesDir, withIntermediateDirectories: true)
    // `EA Games/Linked` is a link to a publisher folder, `EA Games/Real/Game` a link to a game.
    try write("exe", to: elsewhere.appendingPathComponent("Publisher/FirstGame/first.exe"))
    try write("exe", to: elsewhere.appendingPathComponent("SecondGame/second.exe"))
    try FileManager.default.createSymbolicLink(
      at: eaGamesDir.appendingPathComponent("Linked"),
      withDestinationURL: elsewhere.appendingPathComponent("Publisher"))
    try FileManager.default.createDirectory(
      at: eaGamesDir.appendingPathComponent("Real"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: eaGamesDir.appendingPathComponent("Real/Game"),
      withDestinationURL: elsewhere.appendingPathComponent("SecondGame"))

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(Set(entries.map(\.title)) == ["FirstGame", "Game"])
    #expect(entries.allSatisfy { $0.source == .ea })
  }

  @Test func bundlesWithLinkedGameFolderBothSurvive() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundlesDir = tempDir.appendingPathComponent("Bundles", isDirectory: true)
    let shared = tempDir.appendingPathComponent("SharedGame", isDirectory: true)
    try write("content", to: shared.appendingPathComponent("file.txt"))

    for name in ["A", "B"] {
      let resources = bundlesDir.appendingPathComponent("\(name).app/Contents/Resources")
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: resources.appendingPathComponent("Game"), withDestinationURL: shared)
      try write(
        #"{"gameID": "game-\#(name.lowercased())", "displayName": "Game \#(name)"}"#,
        to: resources.appendingPathComponent("bundle-recipe.json"))
    }
    // A third app that is a link to the first one is the same app reached by another name.
    try FileManager.default.createSymbolicLink(
      at: bundlesDir.appendingPathComponent("C.app"),
      withDestinationURL: bundlesDir.appendingPathComponent("A.app"))

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))

    #expect(entries.count == 2)
    #expect(Set(entries.map(\.detail)) == ["A.app", "B.app"])
  }

  // MARK: - Sorting and deduplication tests

  @Test func bundlesOfOneGameKeepKindIDAndGetUniqueIDs() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundlesDir = tempDir.appendingPathComponent("Bundles", isDirectory: true)
    for name in ["Build A", "Build B", "Other"] {
      try makeBundle(
        in: bundlesDir, name: name, gameID: name == "Other" ? "custom-game" : "cod4")
    }

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))
    let byApp = Dictionary(uniqueKeysWithValues: entries.map { ($0.detail, $0) })

    #expect(entries.count == 3)
    #expect(byApp["Build A.app"]?.id.rawValue == "cod4")
    #expect(byApp["Build B.app"]?.id.rawValue == "cod4-2")
    #expect(byApp["Build A.app"]?.kindID == "cod4")
    #expect(byApp["Build B.app"]?.kindID == "cod4")
    #expect(byApp["Other.app"]?.id.rawValue == "custom-game")
    #expect(byApp["Other.app"]?.kindID == nil)
  }

  @Test func idsAreStableAcrossScansAndCreationOrder() throws {
    let names = ["M", "A", "Z", "C", "B"]
    var assignments: [[String: String]] = []

    for order in [names, names.reversed()] {
      let tempDir = try makeTempDir()
      defer { try? FileManager.default.removeItem(at: tempDir) }
      let bundlesDir = tempDir.appendingPathComponent("Bundles", isDirectory: true)
      for name in order {
        try makeBundle(in: bundlesDir, name: name, gameID: "bf3")
      }

      // Two scans of one folder, and two folders created in opposite orders.
      for _ in 0..<2 {
        let entries = GameCatalog.scan(layout: makeLayout(tempDir))
        assignments.append(Dictionary(uniqueKeysWithValues: entries.map { ($0.detail, $0.id.rawValue) }))
      }
    }

    #expect(assignments.count == 4)
    #expect(assignments.allSatisfy { $0 == assignments[0] })
    #expect(assignments[0] == [
      "A.app": "bf3", "B.app": "bf3-2", "C.app": "bf3-3", "M.app": "bf3-4", "Z.app": "bf3-5",
    ])
  }

  @Test func generatedIDNeverCollidesWithExistingSuffixedID() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundlesDir = tempDir.appendingPathComponent("Bundles", isDirectory: true)
    try makeBundle(in: bundlesDir, name: "A1", gameID: "a")
    try makeBundle(in: bundlesDir, name: "A2", gameID: "a")
    try makeBundle(in: bundlesDir, name: "A3", gameID: "a-2")

    let entries = GameCatalog.scan(layout: makeLayout(tempDir))
    let byApp = Dictionary(uniqueKeysWithValues: entries.map { ($0.detail, $0.id.rawValue) })

    #expect(Set(entries.map(\.id.rawValue)).count == 3)
    #expect(byApp == ["A1.app": "a", "A2.app": "a-3", "A3.app": "a-2"])
  }

  // MARK: - Measure function

  @Test func measureFolderSize() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try "test content".write(
      to: tempDir.appendingPathComponent("file1.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "more content".write(
      to: tempDir.appendingPathComponent("file2.txt"),
      atomically: true,
      encoding: .utf8
    )

    let size = GameCatalog.measure(tempDir)

    #expect(size > 0)
  }

  @Test func measureFollowsLinkToGameFolder() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let real = tempDir.appendingPathComponent("Real", isDirectory: true)
    try write("test content", to: real.appendingPathComponent("file.txt"))
    let link = tempDir.appendingPathComponent("Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    #expect(GameCatalog.measure(link) > 0)
    #expect(GameCatalog.measure(link) == GameCatalog.measure(real))
  }

  // MARK: - Helpers

  /// A new folder under the temporary folder, with every link in its path already resolved
  /// (`/var` is a link to `/private/var`), so paths compare equal to what the scan returns.
  private func makeTempDir() throws -> URL {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let url = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeLayout(_ tempDir: URL) -> HubLayout {
    HubLayout(
      hub: tempDir,
      bundles: tempDir.appendingPathComponent("Bundles", isDirectory: true),
      steam: tempDir.appendingPathComponent("Steam", isDirectory: true),
      eaGames: tempDir.appendingPathComponent("EA Games", isDirectory: true),
      epic: tempDir.appendingPathComponent("Epic", isDirectory: true),
      ubisoft: tempDir.appendingPathComponent("Ubisoft", isDirectory: true),
      instances: tempDir.appendingPathComponent("Instances", isDirectory: true)
    )
  }

  /// Writes `text` to `url`, creating the folders above it.
  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// An `appmanifest_*.acf` body, with `"` and `\` in the values escaped the way Steam writes them.
  private func acf(appID: String, name: String, installDir: String, lineEnding: String = "\n")
    -> String
  {
    func escaped(_ value: String) -> String {
      value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    }
    return [
      "\"AppState\"",
      "{",
      "\t\"appid\"\t\t\"\(escaped(appID))\"",
      "\t\"name\"\t\t\"\(escaped(name))\"",
      "\t\"installdir\"\t\t\"\(escaped(installDir))\"",
      "\t\"SizeOnDisk\"\t\t\"1000000\"",
      "}",
    ].joined(separator: lineEnding)
  }

  /// Creates a game folder with an executable in `<library>/steamapps/common/<installDir>` and its
  /// `appmanifest_<appID>.acf` in `<library>/steamapps`.
  private func writeSteamGame(
    library: URL, appID: String, name: String, installDir: String, lineEnding: String = "\n"
  ) throws {
    let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)
    try write("game", to: steamapps.appendingPathComponent("common/\(installDir)/game.exe"))
    try write(
      acf(appID: appID, name: name, installDir: installDir, lineEnding: lineEnding),
      to: steamapps.appendingPathComponent("appmanifest_\(appID).acf"))
  }

  /// Creates `<bundles>/<name>.app` with a game file and a recipe naming `gameID`.
  private func makeBundle(in bundles: URL, name: String, gameID: String) throws {
    let resources = bundles.appendingPathComponent("\(name).app/Contents/Resources")
    try write("content", to: resources.appendingPathComponent("Game/file.txt"))
    try write(
      #"{"gameID": "\#(gameID)", "displayName": "\#(name)"}"#,
      to: resources.appendingPathComponent("bundle-recipe.json"))
  }

  // MARK: - Real layout scan

  @Test(.enabled(if: ProcessInfo.processInfo.environment["HUB_LIVE_TEST"] != nil))
  func realLayoutScan() {
    // The default settings (never the developer's saved ones): a home without a settings file.
    let layout = HubLayout.standard(
      home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))

    let entries = GameCatalog.scan(layout: layout)

    print("=== Real Layout Scan Results ===")
    print("Total entries found: \(entries.count)")
    print("Entries by source:")
    for source in GameSource.allCases {
      let count = entries.filter { $0.source == source }.count
      if count > 0 {
        print("  \(source): \(count)")
      }
    }

    #expect(entries.count > 0, "Real layout should find at least one game")

    let bundleCount = entries.filter { $0.source == .bundle }.count
    #expect(bundleCount > 0, "Should find at least one bundle game")
  }
}
