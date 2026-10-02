import Foundation

/// A bounded inventory used to verify a game generation before publishing it.
package struct BundleManifest: Codable {
  let version: String
  let gameFiles: [ManifestFile]
  let gameID: GameKind?
  /// Present for an import-only app: the player's files are recognised and inventoried at import time.
  package let importRules: ImportRules?
  /// Set when the app references the player's installation in place instead of copying it.
  let referencesInstallation: Bool?
  /// Runtime switches the recipe declares for the staged Wine build.
  let runtimeTuning: RuntimeTuning?
  /// The store client that must be installed, signed into and running before the game starts.
  let storeClient: StoreClientPlan?
  /// Controller `VID/PID` pairs this game needs Wine to present through XInput.
  let controllerDevices: [String]?
  /// Registry values this game needs in the prefix it runs in.
  let prefixSettings: [RegistrySetting]?
  /// Which runtime backend serves each graphics API for this game.
  let renderers: [RendererSelection]?
  /// A .NET runtime installed into a seeded prefix before the store client's installer runs.
  let managedRuntime: ManagedRuntime?
  /// The store client's own files and registry entries, installed at build time and applied to the
  /// prefix on first launch so the player never runs the client's installer.
  let clientLayer: ClientLayerReference?

  package var kind: GameKind { gameID ?? .nfsmw }
  package var references: Bool { referencesInstallation ?? false }
  /// Set for a store-client game that ships its files: the app creates and seeds its own prefix.
  package var seedsPrefix: Bool { kind.requiresStoreClient && !references }
  package var tuning: RuntimeTuning { runtimeTuning ?? RuntimeTuning() }
  package var client: StoreClientPlan? { storeClient }
  package var controllers: [String] { controllerDevices ?? [] }
  package var registry: [RegistrySetting] { prefixSettings ?? [] }
  package var rendererSelection: [RendererSelection] { renderers ?? [] }
  package var managed: ManagedRuntime? { managedRuntime }
  package var layer: ClientLayerReference? { clientLayer }

  init(
    version: String, gameFiles: [ManifestFile], gameID: GameKind? = nil,
    importRules: ImportRules? = nil,
    referencesInstallation: Bool? = nil, runtimeTuning: RuntimeTuning? = nil,
    storeClient: StoreClientPlan? = nil, controllerDevices: [String]? = nil,
    prefixSettings: [RegistrySetting]? = nil, renderers: [RendererSelection]? = nil,
    managedRuntime: ManagedRuntime? = nil, clientLayer: ClientLayerReference? = nil
  ) {
    self.version = version
    self.gameFiles = gameFiles
    self.gameID = gameID
    self.importRules = importRules
    self.referencesInstallation = referencesInstallation
    self.runtimeTuning = runtimeTuning
    self.storeClient = storeClient
    self.controllerDevices = controllerDevices
    self.prefixSettings = prefixSettings
    self.renderers = renderers
    self.managedRuntime = managedRuntime
    self.clientLayer = clientLayer
  }

  /// Reads at most 8 MiB and rejects duplicate, oversized or unsafe entries.
  package static func read(from url: URL) throws(LauncherError) -> Self {
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true, let size = values.fileSize, size <= 8 * 1024 * 1024 else {
        throw LauncherError.operation("The game manifest is missing or too large.")
      }
      let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
      try manifest.validate()
      return manifest
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Cannot read the game manifest: \(error.localizedDescription)")
    }
  }

  func validate() throws(LauncherError) {
    guard !version.isEmpty, version.utf8.count <= 64,
      version.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0) || $0 == 45 || $0 == 95
      }), gameFiles.count <= 30_000
    else {
      throw .operation("The game manifest has an invalid version or file count.")
    }
    try tuning.validate()
    // Only a bundled store-client edition seeds a prefix of its own to install it into.
    if let managedRuntime {
      guard seedsPrefix else {
        throw .operation("Only a bundled store-client manifest declares a managed runtime.")
      }
      try managedRuntime.validate()
    }
    if let clientLayer {
      guard seedsPrefix else {
        throw .operation("Only a bundled store-client manifest declares a client layer.")
      }
      try clientLayer.validate()
    }
    // Only a store-client game references an installation; it either does, or ships its own files.
    guard !references || kind.requiresStoreClient else {
      throw .operation("The game manifest does not match this app's installation contract.")
    }
    if kind.requiresStoreClient {
      try validateStoreClientGame()
      return
    }
    guard renderers == nil else {
      throw .operation("Only a referencing manifest selects its renderer backends.")
    }
    guard prefixSettings == nil else {
      // A bundle that owns its prefix imports Defaults/settings.reg during wineboot instead.
      throw .operation("Only a referencing manifest declares prefix settings.")
    }
    guard storeClient == nil, !gameFiles.isEmpty else {
      throw .operation("The game manifest has an invalid file count.")
    }
    var seen = Set<String>()
    var total = 0
    for file in gameFiles {
      try ManifestFile.validate(path: file.path)
      guard file.size >= 0, file.size <= kind.fileByteLimit,
        file.sha256.utf8.count == 64,
        file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        seen.insert(file.path.lowercased()).inserted
      else {
        throw .operation("The game manifest has an invalid or duplicate file: \(file.path)")
      }
      total += file.size
      guard total <= kind.byteLimit else {
        throw .operation("The game payload exceeds its size limit.")
      }
    }
    if let importRules {
      try importRules.validate()
      guard importRules.executable.lowercased() == kind.executable.lowercased() else {
        throw .operation("The game recognition rules belong to a different executable.")
      }
      guard importRules.maximumBytes <= kind.byteLimit else {
        throw .operation("The game recognition rules allow more data than this game supports.")
      }
    } else {
      guard seen.contains(kind.executable.lowercased()) else {
        throw .operation("The game executable is missing from the manifest.")
      }
    }
  }
  /// A store-client game's manifest: the recipe's launch contract, and either no files at all
  /// (it references the player's installation) or the exact files seeded into the app's prefix.
  private func validateStoreClientGame() throws(LauncherError) {
    guard let client else {
      throw .operation(
        "A store-client game manifest must name its store client.")
    }
    try client.validate()
    guard controllers.count <= 32,
      controllers.allSatisfy({ device in
        let parts = device.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2
          && parts.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isHexDigit) }
      })
    else {
      throw .operation("The manifest lists an invalid controller device.")
    }
    _ = try RegistrySetting.script(registry)
    // A D3D11 title must say which backend serves it, and may not pick a denied one.
    _ = try RendererSelection.compatibilityDatabase(rendererSelection, kind: kind)
    guard importRules == nil else {
      throw .operation("A store-client game is recognised by its client, not by import rules.")
    }
    if references {
      guard gameFiles.isEmpty else {
        throw .operation(
          "A referencing game manifest must carry no game files and name its store client.")
      }
      return
    }
    try validateSeededFiles()
  }

  /// The files a bundled store-client edition copies into its own prefix.
  private func validateSeededFiles() throws(LauncherError) {
    guard !gameFiles.isEmpty else {
      throw .operation("The game manifest has an invalid file count.")
    }
    var seen = Set<String>()
    var total = 0
    for file in gameFiles {
      try ManifestFile.validate(path: file.path)
      guard !ManifestFile.isAccountState(path: file.path) else {
        throw .operation("The game manifest lists account or machine state: \(file.path)")
      }
      guard file.size >= 0, file.size <= kind.fileByteLimit,
        file.sha256.utf8.count == 64,
        file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        seen.insert(file.path.lowercased()).inserted
      else {
        throw .operation("The game manifest has an invalid or duplicate file: \(file.path)")
      }
      total += file.size
      guard total <= kind.byteLimit else {
        throw .operation("The game payload exceeds its size limit.")
      }
    }
    guard seen.contains(kind.executable.lowercased()) else {
      throw .operation("The game executable is missing from the manifest.")
    }
  }
}
