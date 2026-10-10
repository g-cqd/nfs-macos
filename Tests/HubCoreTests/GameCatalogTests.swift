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
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let steamappsDir = steamDir.appendingPathComponent("steamapps", isDirectory: true)
    try FileManager.default.createDirectory(at: steamappsDir, withIntermediateDirectories: true)

    // Real VDF format: key and value on ONE line
    let libFoldersVDF = """
      "LibraryFolders"
      {
        "path"		"\(steamappsDir.path)"
      }
      """
    try libFoldersVDF.write(
      to: steamappsDir.appendingPathComponent("libraryfolders.vdf"),
      atomically: true,
      encoding: .utf8
    )

    // Create game in the library
    let gameDir = steamappsDir
      .appendingPathComponent("common/TestGame", isDirectory: true)
    try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
    try "game".write(
      to: gameDir.appendingPathComponent("game.exe"),
      atomically: true,
      encoding: .utf8
    )

    let manifestACF = """
      "AppState"
      {
        "appid"		"111111"
        "name"		"VDF Test Game"
        "installdir"		"TestGame"
        "SizeOnDisk"		"1000000"
      }
      """
    try manifestACF.write(
      to: steamappsDir.appendingPathComponent("appmanifest_111111.acf"),
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
    guard !entries.isEmpty else { return }
    #expect(entries[0].title == "VDF Test Game")
  }

  @Test func steamVDFRealWindowsPathFormat() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let steamappsDir = steamDir.appendingPathComponent("steamapps", isDirectory: true)
    try FileManager.default.createDirectory(at: steamappsDir, withIntermediateDirectories: true)

    // Real format from actual Steam VDF: Windows path with Z: drive
    let libFoldersVDF = """
      "libraryfolders"
      {
        "0"
        {
          "path"		"Z:\\\\Volumes\\\\ExT2\\\\Steam"
        }
      }
      """
    try libFoldersVDF.write(
      to: steamappsDir.appendingPathComponent("libraryfolders.vdf"),
      atomically: true,
      encoding: .utf8
    )

    // Create game in the library (manually under the resolved path)
    let gameDir = steamappsDir
      .appendingPathComponent("common/TestGame", isDirectory: true)
    try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
    try "game".write(
      to: gameDir.appendingPathComponent("game.exe"),
      atomically: true,
      encoding: .utf8
    )

    let manifestACF = """
      "AppState"
      {
        "appid"		"222222"
        "name"		"Windows Path Game"
        "installdir"		"TestGame"
        "SizeOnDisk"		"1000000"
      }
      """
    try manifestACF.write(
      to: steamappsDir.appendingPathComponent("appmanifest_222222.acf"),
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
    // Should find at least the game in the primary steamapps folder
    #expect(!entries.isEmpty)
  }

  @Test func steamVDFHostilePathRejected() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let steamDir = tempDir.appendingPathComponent("Steam", isDirectory: true)
    let steamappsDir = steamDir.appendingPathComponent("steamapps", isDirectory: true)
    try FileManager.default.createDirectory(at: steamappsDir, withIntermediateDirectories: true)

    // Hostile VDF: path escapes the steam layout
    let libFoldersVDF = """
      "LibraryFolders"
      {
        "path"		"/tmp"
      }
      """
    try libFoldersVDF.write(
      to: steamappsDir.appendingPathComponent("libraryfolders.vdf"),
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
    // Should reject the hostile path and find no games
    #expect(entries.isEmpty)
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
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let epicDir = tempDir.appendingPathComponent("Epic", isDirectory: true)
    try FileManager.default.createDirectory(at: epicDir, withIntermediateDirectories: true)

    let manifestDir = epicDir.appendingPathComponent("Manifests", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)

    // Item with hostile Windows path that escapes the layout
    let itemJSON = """
      {
        "DisplayName": "Hostile Game",
        "InstallLocation": "C:\\\\..\\\\..\\\\Users\\\\gc\\\\Documents",
        "LaunchExecutable": "game.exe"
      }
      """
    try itemJSON.write(
      to: manifestDir.appendingPathComponent("test.item"),
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
    // Should reject the hostile path and find no games
    #expect(entries.isEmpty)
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
    // IDs should be deduplicated
    #expect(entries[0].id.rawValue == "same-id-2")
    #expect(entries[1].id.rawValue == "same-id-3")
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

  // MARK: - Real layout scan

  @Test(.enabled(if: ProcessInfo.processInfo.environment["HUB_LIVE_TEST"] != nil))
  func realLayoutScan() {
    let layout = HubLayout.standard()

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
