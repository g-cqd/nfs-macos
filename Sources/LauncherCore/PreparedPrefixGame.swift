import Foundation

/// The `game-manifest.json` of an app that ships a whole prepared prefix (`PreparedPrefix`).
///
/// It is written by the packager from the recipe and signed with the app. Everything the session
/// does is read from here, so a second game of the same shape is a recipe, not new code.
package struct PreparedPrefixGame: Codable, Equatable, Sendable {
  /// The store client inside the prefix, and how it is started.
  package struct Client: Codable, Equatable, Sendable {
    package let name: String
    /// The client's installation root, relative to `drive_c`; it holds version folders.
    package let installRoot: String
    /// The window-owning client, relative to a version folder.
    package let clientExecutable: String
    package let clientArguments: [String]
    /// The game's installation folder, relative to `drive_c`.
    package let gameRoot: String
    /// The programs the client's launch request starts, ending with the game.
    package let launchChain: [String]
    /// The program whose process is the game.
    package let leaseTarget: String

    package init(
      name: String, installRoot: String, clientExecutable: String, clientArguments: [String],
      gameRoot: String, launchChain: [String], leaseTarget: String
    ) {
      self.name = name
      self.installRoot = installRoot
      self.clientExecutable = clientExecutable
      self.clientArguments = clientArguments
      self.gameRoot = gameRoot
      self.launchChain = launchChain
      self.leaseTarget = leaseTarget
    }
  }

  /// A registry key or value the prepared prefix must hold, and why.
  package struct RegistryRecord: Codable, Equatable, Sendable {
    /// `system.reg` or `user.reg`.
    package let hive: String
    package let path: String
    /// A value name inside the key, or nil when the key itself is what matters.
    package let name: String?
    package let reason: String

    package init(hive: String, path: String, name: String? = nil, reason: String) {
      self.hive = hive
      self.path = path
      self.name = name
      self.reason = reason
    }

    /// The section header as Wine writes it in a hive file, with doubled backslashes.
    var section: String { "[" + path.replacingOccurrences(of: "\\", with: "\\\\") + "]" }

    /// Whether the hive text has the key and, when named, the value.
    package func isRecorded(in hive: String) -> Bool {
      let header = section.lowercased()
      var inSection = false
      for line in hive.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("[") {
          if inSection { return false }
          inSection = line.lowercased().hasPrefix(header + " ") || line.lowercased() == header
          if inSection, name == nil { return true }
        } else if inSection, let name,
          line.lowercased().hasPrefix("\"\(name.lowercased())\"=")
            || (name == "@" && line.hasPrefix("@="))
        {
          return true
        }
      }
      return false
    }
  }

  /// A file placed in the game's folder to work around a runtime gap, with its pin and reason.
  package struct GameShim: Codable, Equatable, Sendable {
    /// Relative to the game's folder.
    package let path: String
    package let sha256: String
    package let reason: String

    package init(path: String, sha256: String, reason: String) {
      self.path = path
      self.sha256 = sha256
      self.reason = reason
    }
  }

  package let version: String
  package let gameID: GameKind
  package let prefix: PreparedPrefix
  package let storeClient: Client
  package let storeBrowser: StoreBrowserPlan
  package let renderers: [RendererSelection]
  package let runtimeTuning: RuntimeTuning
  /// The game's settings profile, relative to the prefix.
  package let settingsProfile: String
  package let presets: [TextProfilePreset]
  package let prefixRegistry: [RegistryRecord]
  package let gameShims: [GameShim]
  /// Programs that keep running in the prefix after the game (an anti-cheat service), which the
  /// app stops with the prefix.
  package let backgroundPrograms: [String]

  package static func read(from url: URL) throws(LauncherError) -> PreparedPrefixGame {
    let game: PreparedPrefixGame
    do {
      game = try JSONDecoder().decode(PreparedPrefixGame.self, from: Data(contentsOf: url))
    } catch {
      throw .operation("The app's game manifest cannot be read: \(error.localizedDescription)")
    }
    try game.validate()
    return game
  }

  package func validate() throws(LauncherError) {
    guard version.utf8.count == 24,
      version.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      throw .operation("The game manifest has no usable version.")
    }
    try prefix.validate()
    try storeBrowser.validate()
    try runtimeTuning.validate()
    for path in [
      storeClient.installRoot, storeClient.clientExecutable, storeClient.gameRoot, settingsProfile,
    ] {
      try ManifestFile.validate(path: path)
    }
    let programs = storeClient.launchChain + backgroundPrograms
    guard (1...8).contains(storeClient.launchChain.count), backgroundPrograms.count <= 8,
      programs.allSatisfy(RendererSelection.isExecutableName),
      storeClient.launchChain.contains(storeClient.leaseTarget),
      storeClient.clientArguments.count <= 7,
      storeClient.clientArguments.allSatisfy({
        $0.hasPrefix("--") && $0.utf8.count <= 64
          && $0.utf8.allSatisfy { (97...122).contains($0) || $0 == 45 }
      })
    else {
      throw .operation("The store client's programs or arguments are not plain names.")
    }
    for preset in presets { try preset.validate() }
    guard Set(presets.map(\.name)).count == presets.count, presets.count <= 8,
      prefixRegistry.count <= 64, gameShims.count <= 16
    else {
      throw .operation("The game manifest lists too many or duplicate presets, keys or shims.")
    }
    for record in prefixRegistry {
      guard ["system.reg", "user.reg"].contains(record.hive),
        (1...256).contains(record.path.utf8.count),
        !record.path.contains("]"), (1...300).contains(record.reason.utf8.count)
      else {
        throw .operation("The game manifest lists an unusable registry record.")
      }
    }
    for shim in gameShims {
      try ManifestFile.validate(path: shim.path)
      guard shim.sha256.utf8.count == 64, (1...300).contains(shim.reason.utf8.count) else {
        throw .operation("The game manifest lists an unusable game-folder file: \(shim.path)")
      }
    }
    _ = try LaunchEnvironment.compatibilityRules(gameID, renderers: renderers)
  }

  /// The programs the app watches: the client, its launch chain and the background services.
  package var watchedPrograms: [String] {
    var names = [URL(fileURLWithPath: storeClient.clientExecutable).lastPathComponent]
    for name in storeClient.launchChain + backgroundPrograms where !names.contains(name) {
      names.append(name)
    }
    return names
  }

  /// The client's executable in the newest version folder that has it, as a Windows path, or
  /// nil when no version folder holds it.
  package func clientWindowsPath(prefix: URL) -> String? {
    let root = prefix.appendingPathComponent("drive_c").appendingPathComponent(
      storeClient.installRoot)
    let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
      .filter { name in
        !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." }
          && FileManager.default.fileExists(
            atPath: root.appendingPathComponent(name).appendingPathComponent(
              storeClient.clientExecutable
            ).path)
      }
      .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    guard let version = versions.last else { return nil }
    return "C:\\"
      + (storeClient.installRoot + "/" + version + "/" + storeClient.clientExecutable)
      .replacingOccurrences(of: "/", with: "\\")
  }
}
