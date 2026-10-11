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

    // Sort by canonical root first, so the result never depends on the order the file system lists
    // folders. The same folder can be reached twice (`games` and `Games` on a case-insensitive
    // volume, a Steam library listed twice): keep the first entry per (source, root). Two wrapped
    // apps are different entries even when their `Game` folders are links to one folder.
    let ordered = entries
      .map { (entry: $0, root: canonicalPath($0.root), identity: identity(of: $0)) }
      .sorted { lhs, rhs in
        if lhs.root != rhs.root { return lhs.root < rhs.root }
        if lhs.identity != rhs.identity { return lhs.identity < rhs.identity }
        return lhs.entry.root.path < rhs.entry.root.path
      }
    var seenIdentities = Set<String>()
    let unique = ordered.filter { seenIdentities.insert($0.root + "\u{0}" + $0.identity).inserted }

    // The first entry of each ID keeps it. A later duplicate takes the lowest `-N` (N >= 2) that no
    // entry uses, so an ID that already ends in `-2` is never taken over.
    var usedIDs = Set(unique.map { $0.entry.id.rawValue })
    var claimedIDs = Set<String>()
    var finalEntries: [CatalogEntry] = []
    for item in unique {
      var entry = item.entry
      let baseID = entry.id.rawValue
      if !claimedIDs.insert(baseID).inserted {
        var suffix = 2
        while usedIDs.contains("\(baseID)-\(suffix)") { suffix += 1 }
        let newID = "\(baseID)-\(suffix)"
        usedIDs.insert(newID)
        entry.id = GameID(newID)
      }
      finalEntries.append(entry)
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

    // The enumerator does not enter a link to a folder, so start from the real folder.
    guard let enumerator = manager.enumerator(
      at: URL(fileURLWithPath: resolvedPath(root.path), isDirectory: true),
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

    guard let bundleApps = contents(of: layout.bundles) else {
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
      guard let gameContents = contents(of: gameFolder),
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

      // The recipe kind is recorded before `scan` makes the ID unique.
      let entry = CatalogEntry(
        id: GameID(gameID),
        title: title,
        source: .bundle,
        root: gameFolder,
        executable: executable,
        detail: appURL.lastPathComponent,
        kindID: GameKind(rawValue: gameID)?.rawValue
      )

      entries.append(entry)
    }

    return entries
  }

  private static func scanSteam(_ layout: HubLayout) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    let manager = FileManager.default

    // The primary library is the layout's own `steamapps`. Libraries named by `libraryfolders.vdf`
    // must stay inside the Steam folder; each real folder is scanned once.
    let steamappsURL = layout.steam.appendingPathComponent("steamapps", isDirectory: true)
    var libraries: [(steamapps: URL, confinedToSteam: Bool)] = [(steamappsURL, false)]
    var scannedLibraries: Set<String> = [resolvedPath(steamappsURL.path)]

    let libFoldersURL = steamappsURL.appendingPathComponent("libraryfolders.vdf")
    if let vdfText = try? BoundedFile.text(libFoldersURL, limit: 256_000) {
      for library in parseLibraryFolders(vdfText, baseLayout: layout) {
        let libraryApps = library.appendingPathComponent("steamapps", isDirectory: true)
        guard isContained(libraryApps, in: layout.steam, allowingEqual: false),
              scannedLibraries.insert(resolvedPath(libraryApps.path)).inserted else {
          continue
        }
        libraries.append((libraryApps, true))
      }
    }

    // Scan each library for app manifests
    for (libraryPath, confinedToSteam) in libraries {
      guard let manifests = contents(of: libraryPath) else {
        continue
      }

      let commonURL = libraryPath.appendingPathComponent("common", isDirectory: true)

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

        guard let gameRoot = steamGameRoot(installDir: installDir, common: commonURL),
              !confinedToSteam || isContained(gameRoot, in: layout.steam, allowingEqual: false)
        else {
          continue
        }

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

  /// The game folder `installDir` names under `common`, or `nil` when the name is not a single
  /// plain folder name or the folder, once every link is resolved, is not strictly inside `common`.
  private static func steamGameRoot(installDir: String, common: URL) -> URL? {
    guard !installDir.isEmpty, installDir != ".", installDir != "..",
          !installDir.contains("/"), !installDir.contains("\\") else {
      return nil
    }
    let root = common.appendingPathComponent(installDir, isDirectory: true)
    guard isContained(root, in: common, allowingEqual: false) else { return nil }
    return root
  }

  private static func scanEA(_ layout: HubLayout) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    let manager = FileManager.default

    guard let publishers = contents(of: layout.eaGames) else {
      return []
    }

    for publisherURL in publishers {
      guard isDirectory(publisherURL) else { continue }

      guard let games = contents(of: publisherURL) else {
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
      guard let subfolders = contents(of: url) else {
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
    // `XMLParser.delegate` is weak: keep the delegate alive until the parse has finished.
    withExtendedLifetime(delegate) {
      _ = parser.parse()
    }

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
       let itemFiles = contents(of: manifestsURL) {
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

    guard let topLevel = contents(of: layout.epic) else {
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
      guard let games = contents(of: gamesURL) else {
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

  /// What makes an entry the same game twice: its source, plus the canonical `.app` for a wrapped
  /// game (two apps are two games even when their `Game` folders are links to one folder, but a
  /// link to an app is that app). A bundle's root is `<app>/Contents/Resources/Game`.
  private static func identity(of entry: CatalogEntry) -> String {
    guard entry.source == .bundle else { return entry.source.rawValue }
    let app = (0..<3).reduce(entry.root) { url, _ in url.deletingLastPathComponent() }
    return "\(entry.source.rawValue)|\(canonicalPath(app))"
  }

  /// The entries of the folder `folder` names, following a link to it, or `nil` when it cannot be
  /// read. `contentsOfDirectory(at:)` fails on a link to a folder; the path form does not.
  private static func contents(of folder: URL) -> [URL]? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
      return nil
    }
    return names.map { folder.appendingPathComponent($0) }
  }

  /// The canonical on-disk path of `url` (resolves every link and the volume's own letter case).
  private static func canonicalPath(_ url: URL) -> String {
    let resolved = resolvedPath(url.path)
    return (try? URL(fileURLWithPath: resolved).resourceValues(forKeys: [.canonicalPathKey]))?
      .canonicalPath ?? resolved
  }

  /// Whether `url` names a folder on disk, following links (`stat` semantics), so a symlinked
  /// publisher, game or `.app` folder counts. A URL's trailing slash is not reliable for entries
  /// returned by `contentsOfDirectory`, and `isDirectoryKey` does not follow links.
  private static func isDirectory(_ url: URL) -> Bool {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFDIR
  }

  /// `path` with every link resolved. `realpath(3)` resolves the deepest ancestor that exists,
  /// and the part that does not exist yet is appended with `.` and `..` applied. A relative path
  /// is taken from the current directory.
  private static func resolvedPath(_ path: String) -> String {
    let absolute = path.hasPrefix("/")
      ? path : FileManager.default.currentDirectoryPath + "/" + path
    var existing = absolute.split(separator: "/").map(String.init)
    var missing: [String] = []

    while true {
      if let real = realPath("/" + existing.joined(separator: "/")) {
        return normalized(real, appending: missing)
      }
      guard let last = existing.popLast() else {
        return normalized("/", appending: missing)
      }
      missing.insert(last, at: 0)
    }
  }

  /// The result of `realpath(3)` for `path`, or `nil` when some component does not exist.
  private static func realPath(_ path: String) -> String? {
    guard let buffer = realpath(path, nil) else { return nil }
    defer { free(buffer) }
    return String(cString: buffer)
  }

  /// `base` followed by `components`, with `.` dropped and `..` removing the previous component.
  private static func normalized(_ base: String, appending components: [String]) -> String {
    var parts = base.split(separator: "/").map(String.init)
    for component in components {
      switch component {
      case ".": continue
      case "..": _ = parts.popLast()
      default: parts.append(component)
      }
    }
    return "/" + parts.joined(separator: "/")
  }

  /// Whether `url`, with every link resolved on both sides, lies inside `root`. With
  /// `allowingEqual` false, `root` itself does not count.
  private static func isContained(_ url: URL, in root: URL, allowingEqual: Bool = true) -> Bool {
    let child = resolvedPath(url.path)
    let parent = resolvedPath(root.path)
    if child == parent { return allowingEqual }
    return child.hasPrefix(parent == "/" ? "/" : parent + "/")
  }

  // MARK: - Valve text format

  /// One `{ ... }` block of a Valve text file: its `"key" "value"` pairs and its child blocks.
  private struct VDFSection {
    var values: [String: String] = [:]
    var sections: [(key: String, section: VDFSection)] = []
  }

  private enum VDFToken {
    case string(String)
    case open
    case close
  }

  /// Splits Valve text into quoted or bare strings and braces. Inside quotes `\\` is a backslash
  /// and `\"` a quote; any other backslash is kept. Line ends of any kind are plain whitespace,
  /// and `//` starts a comment. A string cut off by the end of the text is dropped.
  private static func tokenizeVDF(_ content: String) -> [VDFToken] {
    let scalars = Array(content.unicodeScalars)
    var tokens: [VDFToken] = []
    var index = 0

    while index < scalars.count {
      let scalar = scalars[index]
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        index += 1
      } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
        while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" { index += 1 }
      } else if scalar == "{" {
        tokens.append(.open)
        index += 1
      } else if scalar == "}" {
        tokens.append(.close)
        index += 1
      } else if scalar == "\"" {
        index += 1
        var text = String.UnicodeScalarView()
        var closed = false
        while index < scalars.count {
          let current = scalars[index]
          if current == "\"" {
            closed = true
            index += 1
            break
          }
          if current == "\\", index + 1 < scalars.count,
             scalars[index + 1] == "\\" || scalars[index + 1] == "\"" {
            text.append(scalars[index + 1])
            index += 2
          } else {
            text.append(current)
            index += 1
          }
        }
        guard closed else { break }
        tokens.append(.string(String(text)))
      } else {
        var text = String.UnicodeScalarView()
        while index < scalars.count {
          let current = scalars[index]
          if CharacterSet.whitespacesAndNewlines.contains(current) || current == "{"
            || current == "}" || current == "\"" {
            break
          }
          text.append(current)
          index += 1
        }
        tokens.append(.string(String(text)))
      }
    }

    return tokens
  }

  /// Parses Valve text into its top-level section. Blocks left open at the end of the text are
  /// closed; a block with no key is ignored.
  private static func parseVDF(_ content: String) -> VDFSection {
    var stack: [(key: String, section: VDFSection)] = [("", VDFSection())]
    var pendingKey: String?

    func closeInnermost() {
      guard stack.count > 1, let finished = stack.popLast() else { return }
      stack[stack.count - 1].section.sections.append(finished)
    }

    for token in tokenizeVDF(content) {
      switch token {
      case .string(let text):
        if let key = pendingKey {
          stack[stack.count - 1].section.values[key] = text
          pendingKey = nil
        } else {
          pendingKey = text
        }
      case .open:
        if let key = pendingKey {
          stack.append((key, VDFSection()))
          pendingKey = nil
        }
      case .close:
        pendingKey = nil
        closeInnermost()
      }
    }
    while stack.count > 1 { closeInnermost() }

    return stack[0].section
  }

  /// Whether `content` is well-formed Valve text: at least one block, every `{` has a key before
  /// it, and every block is closed. The lenient parser above repairs such damage silently; this
  /// strict view lets a caller reject a file that was cut off or edited into a broken shape.
  package static func isWellFormedValveText(_ content: String) -> Bool {
    var depth = 0
    var blocks = 0
    var previousWasKey = false
    var expectsValue = false
    for token in tokenizeVDF(content) {
      switch token {
      case .string:
        if expectsValue {
          expectsValue = false
          previousWasKey = false
        } else {
          expectsValue = true
          previousWasKey = true
        }
      case .open:
        guard previousWasKey else { return false }
        depth += 1
        blocks += 1
        expectsValue = false
        previousWasKey = false
      case .close:
        guard depth > 0, !expectsValue else { return false }
        depth -= 1
      }
    }
    return depth == 0 && blocks > 0 && !expectsValue
  }

  /// The library roots `libraryfolders.vdf` names that lie inside the Steam folder. Reads the
  /// numbered sections (`"0" { "path" "..." }`) and the older `"1" "path"` pairs; a `path` that
  /// is relative, or that resolves outside the Steam folder, is dropped. A `Z:` drive prefix (the
  /// Wine view of `/`) is converted to a macOS path.
  private static func parseLibraryFolders(_ content: String, baseLayout: HubLayout) -> [URL] {
    let top = parseVDF(content)
    guard let folders = top.sections.first(where: { $0.key.lowercased() == "libraryfolders" })?
      .section else {
      return []
    }

    var rawPaths: [String] = []
    for (key, section) in folders.sections where isNumeric(key) {
      if let path = section.values["path"] { rawPaths.append(path) }
    }
    for (key, value) in folders.values where isNumeric(key) {
      rawPaths.append(value)
    }

    var paths: [URL] = []
    for raw in rawPaths {
      var pathStr = raw.trimmingCharacters(in: .whitespaces)

      // Convert Windows path to macOS path (e.g., `Z:\Volumes\ExT2\Steam` -> `/Volumes/ExT2/Steam`)
      if pathStr.hasPrefix("Z:") || pathStr.hasPrefix("z:") {
        pathStr = pathStr.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
      }
      guard pathStr.hasPrefix("/") else { continue }

      // REQUIRE containment: must be under the steam layout
      let library = URL(fileURLWithPath: pathStr, isDirectory: true)
      guard isContained(library, in: baseLayout.steam) else { continue }

      paths.append(library)
    }

    return paths
  }

  private static func isNumeric(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
  }

  /// The `AppState` pairs of an `appmanifest_*.acf` file. Only pairs directly inside `AppState`
  /// count; pairs of nested blocks (`UserConfig`, `InstalledDepots`, ...) never overwrite them.
  private static func parseACF(_ content: String) -> [String: String]? {
    parseVDF(content).sections.first(where: { $0.key.lowercased() == "appstate" })?.section.values
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
       pathComponents.first?.first?.isLetter == true &&
       pathComponents.first?.hasSuffix(":") == true {
      pathComponents.removeFirst()
    }

    // A bare drive names no game folder, and `.` or `..` must never step out of the base.
    guard !pathComponents.isEmpty,
          !pathComponents.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
      return nil
    }

    // Append components
    var testURL = baseURL
    for component in pathComponents {
      testURL = testURL.appendingPathComponent(component)
    }

    // REQUIRE containment: strictly under baseURL once every link on both sides is resolved
    guard isContained(testURL, in: baseURL, allowingEqual: false) else {
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
