import Foundation
import LauncherCore

/// Finds the games on the big drive: wrapped apps, Steam, EA, Epic and Ubisoft folders.
package enum GameCatalog {
  /// Scans `layout` and returns every game found, sorted by title. Unreadable folders are skipped.
  /// - Complexity: reads folder listings and manifests; measures sizes only on request.
  package static func scan(layout: HubLayout) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []

    entries.append(contentsOf: scanBundles(layout))
    entries.append(contentsOf: scanSteam(layout))
    entries.append(contentsOf: scanEA(layout))
    entries.append(contentsOf: scanEpic(layout))
    entries.append(contentsOf: scanUbisoft(layout))

    // The same folder can be reached twice (`games` and `Games` on a case-insensitive volume, a
    // Steam library listed twice): keep the first entry per canonical on-disk root.
    var seenRoots = Set<String>()
    entries = entries.filter { seenRoots.insert(canonicalPath($0.root)).inserted }

    // Deduplicate IDs: collisions get `-2`, `-3`, etc. or stable hash suffix
    var idCounts: [String: Int] = [:]
    for entry in entries {
      let baseID = entry.id.rawValue
      idCounts[baseID] = (idCounts[baseID] ?? 0) + 1
    }

    var finalEntries: [CatalogEntry] = []
    var idUsed: [String: Int] = [:]
    for entry in entries {
      let baseID = entry.id.rawValue
      var finalID = baseID
      if (idCounts[baseID] ?? 0) > 1 {
        let count = (idUsed[baseID] ?? 0) + 1
        idUsed[baseID] = count
        finalID = "\(baseID)-\(count + 1)"
      }
      var newEntry = entry
      newEntry.id = GameID(finalID)
      finalEntries.append(newEntry)
    }

    return finalEntries.sorted { lhs, rhs in
      if lhs.title == rhs.title {
        return lhs.id.rawValue < rhs.id.rawValue
      }
      return lhs.title < rhs.title
    }
  }

  /// Measures the allocated size of a folder tree, stopping at `limit` entries.
  package static func measure(_ root: URL, limit: Int = 2_000_000) -> Int64 {
    let manager = FileManager.default
    var totalSize: Int64 = 0
    var entryCount = 0

    guard let enumerator = manager.enumerator(
      at: root,
      includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
      options: []
    ) else {
      return 0
    }

    for case let fileURL as URL in enumerator {
      guard entryCount < limit else { break }

      do {
        let values = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        if let size = values.totalFileAllocatedSize {
          totalSize += Int64(size)
        }
        entryCount += 1
      } catch {
        // Skip files we cannot read
      }
    }

    return totalSize
  }

  // MARK: - Private scanning functions

  private static func scanBundles(_ layout: HubLayout) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    let manager = FileManager.default

    guard let bundleApps = try? manager.contentsOfDirectory(
      at: layout.bundles,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return []
    }

    for appURL in bundleApps {
      guard isDirectory(appURL) && appURL.lastPathComponent.hasSuffix(".app") else {
        continue
      }

      let gameFolder = appURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("Game", isDirectory: true)

      // Check if Game folder has content
      guard let gameContents = try? manager.contentsOfDirectory(
        at: gameFolder,
        includingPropertiesForKeys: nil,
        options: []
      ),
            !gameContents.isEmpty else {
        continue
      }

      // Try to load manifest
      let resourcesFolder = appURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)

      let recipeURL = resourcesFolder.appendingPathComponent("bundle-recipe.json")
      let manifestURL = resourcesFolder.appendingPathComponent("game-manifest.json")

      var title: String = appURL.deletingPathExtension().lastPathComponent
      var gameID: String = derivedIDFromBundleName(appURL.lastPathComponent)
      var executable: String? = nil

      // Try to load recipe for title and game ID
      if let recipeData = try? BoundedFile.read(recipeURL, limit: 256_000),
         let recipe = try? JSONDecoder().decode(BundleRecipe.self, from: recipeData) {
        title = recipe.displayName
        gameID = recipe.gameID
      } else if let manifestData = try? BoundedFile.read(manifestURL, limit: 256_000),
                let manifest = try? JSONDecoder().decode(BundleManifestModel.self, from: manifestData) {
        // Fallback to manifest
        gameID = manifest.gameID
      }

      // Look for executable in manifest
      if let manifestData = try? BoundedFile.read(manifestURL, limit: 256_000),
         let manifest = try? JSONDecoder().decode(BundleManifestModel.self, from: manifestData) {
        // Use GameKind if available, else manifest's explicit executable
        if let kind = GameKind(rawValue: gameID) {
          executable = kind.executable
        } else if let exec = manifest.gameFiles?.first?.path {
          executable = exec
        }
      }

      let entry = CatalogEntry(
        id: GameID(gameID),
        title: title,
        source: .bundle,
        root: gameFolder,
        executable: executable,
        detail: appURL.lastPathComponent
      )

      entries.append(entry)
    }

    return entries
  }

  private static func scanSteam(_ layout: HubLayout) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    let manager = FileManager.default

    let steamappsURL = layout.steam.appendingPathComponent("steamapps", isDirectory: true)

    // Parse library folders
    var libraryPaths: [URL] = [steamappsURL]
    let libFoldersURL = steamappsURL.appendingPathComponent("libraryfolders.vdf")
    if let vdfText = try? BoundedFile.text(libFoldersURL, limit: 256_000) {
      // `path` in libraryfolders.vdf names a library root; its manifests live in `<root>/steamapps`.
      libraryPaths.append(
        contentsOf: parseLibraryFolders(vdfText, baseLayout: layout).map { library in
          library.lastPathComponent == "steamapps"
            ? library : library.appendingPathComponent("steamapps", isDirectory: true)
        })
    }

    // Scan each library for app manifests
    for libraryPath in libraryPaths {
      guard let manifests = try? manager.contentsOfDirectory(
        at: libraryPath,
        includingPropertiesForKeys: nil,
        options: []
      ) else {
        continue
      }

      for manifestURL in manifests {
        guard manifestURL.lastPathComponent.hasPrefix("appmanifest_") &&
              manifestURL.lastPathComponent.hasSuffix(".acf") else {
          continue
        }

        guard let acfText = try? BoundedFile.text(manifestURL, limit: 256_000) else {
          continue
        }

        guard let appData = parseACF(acfText) else {
          continue
        }

        guard let appID = appData["appid"],
              let name = appData["name"],
              let installDir = appData["installdir"] else {
          continue
        }

        let gameRoot = libraryPath
          .appendingPathComponent("common", isDirectory: true)
          .appendingPathComponent(installDir, isDirectory: true)

        // Only include if the folder exists
        guard manager.fileExists(atPath: gameRoot.path) else {
          continue
        }

        var sizeBytes: Int64? = nil
        if let sizeStr = appData["SizeOnDisk"], let size = Int64(sizeStr) {
          sizeBytes = size
        }

        let entry = CatalogEntry(
          id: GameID("steam-\(appID)"),
          title: name,
          source: .steam,
          root: gameRoot,
          sizeBytes: sizeBytes,
          detail: "Steam app \(appID)"
        )

        entries.append(entry)
      }
    }

    return entries
  }

  private static func scanEA(_ layout: HubLayout) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    let manager = FileManager.default

    guard let publishers = try? manager.contentsOfDirectory(
      at: layout.eaGames,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return []
    }

    for publisherURL in publishers {
      guard isDirectory(publisherURL) else { continue }

      guard let games = try? manager.contentsOfDirectory(
        at: publisherURL,
        includingPropertiesForKeys: nil,
        options: []
      ) else {
        continue
      }

      for gameURL in games {
        guard isDirectory(gameURL) else { continue }

        let entry = findEAGame(at: gameURL, depth: 0)
        if let entry = entry {
          entries.append(entry)
        }
      }
    }

    return entries
  }

  private static func findEAGame(at url: URL, depth: Int) -> CatalogEntry? {
    let manager = FileManager.default
    let folderName = url.lastPathComponent

    // Check if this folder is a game
    if isEAGameFolder(url) {
      let title = titleFromEAGame(url) ?? folderName
      let id = "ea-\(slugify(folderName))"

      return CatalogEntry(
        id: GameID(id),
        title: title,
        source: .ea,
        root: url,
        detail: folderName
      )
    }

    // If not a game and depth < 1, look one level deeper
    if depth < 1 {
      guard let subfolders = try? manager.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: []
      ) else {
        return nil
      }

      for subfolder in subfolders {
        guard isDirectory(subfolder) else { continue }

        if let entry = findEAGame(at: subfolder, depth: depth + 1) {
          return entry
        }
      }
    }

    return nil
  }

  private static func isEAGameFolder(_ url: URL) -> Bool {
    let manager = FileManager.default

    // Check for __Installer folder
    let installerPath = url.appendingPathComponent("__Installer", isDirectory: true)
    if manager.fileExists(atPath: installerPath.path) {
      return true
    }

    // Check for installerdata.xml
    let installerDataPath = url.appendingPathComponent("installerdata.xml")
    if manager.fileExists(atPath: installerDataPath.path) {
      return true
    }

    // Check for .exe files
    do {
      let contents = try manager.contentsOfDirectory(atPath: url.path)
      for item in contents {
        if item.hasSuffix(".exe") {
          return true
        }
      }
      return false
    } catch {
      return false
    }
  }

  private static func titleFromEAGame(_ url: URL) -> String? {
    let installerDataPath = url
      .appendingPathComponent("__Installer", isDirectory: true)
      .appendingPathComponent("installerdata.xml")

    guard let xmlData = try? BoundedFile.read(installerDataPath, limit: 256_000) else {
      return nil
    }

    var title: String? = nil
    let parser = XMLParser(data: xmlData)
    let delegate = XMLTitleExtractor { extractedTitle in
      title = extractedTitle
    }
    parser.delegate = delegate
    parser.parse()

    return title
  }

  private static func scanEpic(_ layout: HubLayout) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    let manager = FileManager.default

    // Try to find Manifests folder
    var manifestsURL: URL? = layout.epic.appendingPathComponent("Manifests", isDirectory: true)

    // Also check ProgramData path
    let altManifestPath = layout.epic
      .appendingPathComponent("ProgramData", isDirectory: true)
      .appendingPathComponent("Epic", isDirectory: true)
      .appendingPathComponent("EpicGamesLauncher", isDirectory: true)
      .appendingPathComponent("Data", isDirectory: true)
      .appendingPathComponent("Manifests", isDirectory: true)

    if manager.fileExists(atPath: altManifestPath.path) {
      manifestsURL = altManifestPath
    }

    // Try to parse .item files
    if let manifestsURL = manifestsURL,
       let itemFiles = try? manager.contentsOfDirectory(
         at: manifestsURL,
         includingPropertiesForKeys: nil,
         options: []
       ) {
      for itemURL in itemFiles {
        guard itemURL.lastPathComponent.hasSuffix(".item") else { continue }

        guard let itemData = try? BoundedFile.read(itemURL, limit: 256_000),
              let item = try? JSONDecoder().decode(EpicItem.self, from: itemData) else {
          continue
        }

        var gameRoot: URL? = nil

        if let installLocation = item.InstallLocation {
          // Map Windows paths to macOS paths with security checks
          gameRoot = mapWindowsPath(installLocation, baseURL: layout.epic)
        }

        guard let gameRoot = gameRoot, manager.fileExists(atPath: gameRoot.path) else {
          continue
        }

        let entry = CatalogEntry(
          id: GameID("epic-\(slugify(item.DisplayName ?? "game"))"),
          title: item.DisplayName ?? "Unknown",
          source: .epic,
          root: gameRoot,
          executable: item.LaunchExecutable,
          detail: "Epic app"
        )

        entries.append(entry)
      }
    } else {
      // Fall back to scanning for .exe files
      entries.append(contentsOf: scanEpicByExe(layout))
    }

    return entries
  }

  private static func scanEpicByExe(_ layout: HubLayout) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    let manager = FileManager.default

    let excludedFolders = Set(["Launcher", "Epic Games Launcher", "Manifests", "Cache", "Data"])

    guard let topLevel = try? manager.contentsOfDirectory(
      at: layout.epic,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return []
    }

    for folder in topLevel {
      guard isDirectory(folder) else { continue }

      let folderName = folder.lastPathComponent
      guard !excludedFolders.contains(folderName) else { continue }

      if hasExeWithinDepth(folder, depth: 2) {
        let entry = CatalogEntry(
          id: GameID("epic-\(slugify(folderName))"),
          title: folderName,
          source: .epic,
          root: folder,
          detail: "Epic app"
        )
        entries.append(entry)
      }
    }

    return entries
  }

  private static func scanUbisoft(_ layout: HubLayout) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    let manager = FileManager.default

    // Try both "games" and "Games"
    let possiblePaths = [
      layout.ubisoft.appendingPathComponent("games", isDirectory: true),
      layout.ubisoft.appendingPathComponent("Games", isDirectory: true)
    ]

    for gamesURL in possiblePaths {
      guard let games = try? manager.contentsOfDirectory(
        at: gamesURL,
        includingPropertiesForKeys: nil,
        options: []
      ) else {
        continue
      }

      for gameURL in games {
        guard isDirectory(gameURL) else { continue }

        if hasExeWithinDepth(gameURL, depth: 2) {
          let folderName = gameURL.lastPathComponent
          let entry = CatalogEntry(
            id: GameID("ubisoft-\(slugify(folderName))"),
            title: folderName,
            source: .ubisoft,
            root: gameURL,
            detail: folderName
          )
          entries.append(entry)
        }
      }
    }

    return entries
  }

  // MARK: - Helper functions

  /// The canonical on-disk path of `url` (resolves links and the volume's own letter case).
  private static func canonicalPath(_ url: URL) -> String {
    (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
      ?? url.resolvingSymlinksInPath().path
  }

  /// Whether `url` names a folder on disk (not a symlink to one). Asks the file system; a URL's
  /// trailing slash is not reliable for entries returned by `contentsOfDirectory`.
  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
  }

  private static func resolveSymlinksInPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    var resolvedUrl = url.standardizedFileURL
    // Try resolving symlinks by accessing the real path through FileManager
    if let realPath = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
      resolvedUrl = URL(fileURLWithPath: realPath).standardizedFileURL
    }
    return resolvedUrl.path
  }

  private static func parseLibraryFolders(_ content: String, baseLayout: HubLayout) -> [URL] {
    var paths: [URL] = []
    let steamResolved = resolveSymlinksInPath(baseLayout.steam.path)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Parse key and value from SINGLE line: "path"		"/x"
      let parts = trimmed.split(separator: "\"", omittingEmptySubsequences: false)
      guard parts.count >= 4 else { continue }

      let key = String(parts[1]).trimmingCharacters(in: .whitespaces)
      guard key == "path" else { continue }

      var pathStr = String(parts[3]).trimmingCharacters(in: .whitespaces)

      // Convert Windows path to macOS path (e.g., "Z:\\Volumes\\ExT2\\Steam" -> "/Volumes/ExT2/Steam")
      if pathStr.hasPrefix("Z:") || pathStr.hasPrefix("z:") {
        pathStr = pathStr.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
      }

      let resolved = resolveSymlinksInPath(pathStr)

      // REQUIRE containment: must be under steam layout
      guard resolved == steamResolved || resolved.hasPrefix(steamResolved + "/") else {
        continue
      }

      let steamappsURL = URL(fileURLWithPath: resolved, isDirectory: true)
        .appendingPathComponent("steamapps", isDirectory: true)
      paths.append(steamappsURL)
    }

    return paths
  }

  private static func parseACF(_ content: String) -> [String: String]? {
    var result: [String: String] = [:]
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Skip comments and braces
      guard !trimmed.isEmpty && !trimmed.hasPrefix("//") && trimmed != "{" && trimmed != "}" else {
        continue
      }

      // Parse key-value pairs
      // `"key"<whitespace>"value"` splits into ["", key, whitespace, value, ""].
      let parts = trimmed.split(separator: "\"", omittingEmptySubsequences: false)
      guard parts.count >= 4 else { continue }

      let key = String(parts[1]).trimmingCharacters(in: .whitespaces)
      let value = String(parts[3]).trimmingCharacters(in: .whitespaces)

      result[key] = value
    }

    return result
  }

  private static func mapWindowsPath(_ windowsPath: String, baseURL: URL) -> URL? {
    // Split on both \\ and /
    let components = windowsPath
      .replacingOccurrences(of: "\\", with: "/")
      .split(separator: "/")
      .map(String.init)

    // Drop leading 2-char drive letter (e.g., "C:")
    var pathComponents = components
    if pathComponents.first?.count == 2 &&
       pathComponents.first?.last?.isLetter == true &&
       pathComponents.first?.hasSuffix(":") == true {
      pathComponents.removeFirst()
    }

    // Reject empty, ".", or ".." components
    guard !pathComponents.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
      return nil
    }

    // Append components
    var testURL = baseURL
    for component in pathComponents {
      testURL = testURL.appendingPathComponent(component)
    }

    // Resolve symlinks consistently on both sides
    let baseResolved = resolveSymlinksInPath(baseURL.path)
    let testResolved = resolveSymlinksInPath(testURL.path)

    // REQUIRE containment: must be under baseURL
    guard testResolved == baseResolved || testResolved.hasPrefix(baseResolved + "/") else {
      return nil
    }

    return testURL
  }

  private static func hasExeWithinDepth(_ url: URL, depth: Int) -> Bool {
    guard depth >= 0 else { return false }

    let manager = FileManager.default
    do {
      let contents = try manager.contentsOfDirectory(atPath: url.path)

      for item in contents {
        if item.hasSuffix(".exe") {
          return true
        }
      }

      if depth > 0 {
        let subdirs = try manager.contentsOfDirectory(atPath: url.path)

        for subdir in subdirs {
          let subdirURL = url.appendingPathComponent(subdir)
          if isDirectory(subdirURL) && hasExeWithinDepth(subdirURL, depth: depth - 1) {
            return true
          }
        }
      }
    } catch {
      return false
    }

    return false
  }

  private static func slugify(_ name: String) -> String {
    let slugged = name
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    // Handle empty slugs from non-ASCII titles
    return slugged.isEmpty ? "unnamed" : slugged
  }

  private static func derivedIDFromBundleName(_ bundleName: String) -> String {
    // Remove .app extension
    let withoutApp = bundleName.hasSuffix(".app")
      ? String(bundleName.dropLast(4))
      : bundleName

    // Remove trailing date/revision patterns (e.g., "20261002-7d108a4")
    var withoutDate = withoutApp
    if let lastSpace = withoutDate.lastIndex(of: " ") {
      let potentialDate = String(withoutDate[withoutDate.index(after: lastSpace)...])
      if potentialDate.count <= 20 && potentialDate.contains("-") {
        withoutDate = String(withoutDate[..<lastSpace])
      }
    }

    // Slugify the remaining name
    return slugify(withoutDate)
  }
}

// MARK: - Decodable types

private struct BundleRecipe: Decodable {
  let gameID: String
  let displayName: String

  enum CodingKeys: String, CodingKey {
    case gameID
    case displayName
  }
}

// Note: BundleManifestModel duplicates LauncherCore's BundleManifest struct because
// LauncherCore's version uses GameKind (specific to known games), while we need String
// IDs for arbitrary games from various stores. Both decode game-manifest.json files.
private struct BundleManifestModel: Decodable {
  let gameID: String
  let gameFiles: [GameFile]?

  enum CodingKeys: String, CodingKey {
    case gameID
    case gameFiles
  }
}

private struct GameFile: Decodable {
  let path: String?

  enum CodingKeys: String, CodingKey {
    case path
  }
}

private struct EpicItem: Decodable {
  let DisplayName: String?
  let InstallLocation: String?
  let LaunchExecutable: String?

  enum CodingKeys: String, CodingKey {
    case DisplayName
    case InstallLocation
    case LaunchExecutable
  }
}

// MARK: - XML parsing

private final class XMLTitleExtractor: NSObject, XMLParserDelegate {
  var callback: (String) -> Void
  var foundTitle: Bool = false
  var currentCharacters: String = ""

  init(_ callback: @escaping (String) -> Void) {
    self.callback = callback
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    if elementName == "gameTitle" && !foundTitle {
      currentCharacters = ""
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if !foundTitle {
      currentCharacters += string
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "gameTitle" && !foundTitle && !currentCharacters.isEmpty {
      callback(currentCharacters.trimmingCharacters(in: .whitespaces))
      foundTitle = true
    }
  }
}
