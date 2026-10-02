import Foundation

/// A bounded inventory used to verify a game generation before publishing it.
package struct BundleManifest: Codable {
  let version: String
  let gameFiles: [ManifestFile]
  let gameID: GameKind?
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

  package var kind: GameKind { gameID ?? .nfsmw }
  package var references: Bool { referencesInstallation ?? false }
  package var tuning: RuntimeTuning { runtimeTuning ?? RuntimeTuning() }
  package var client: StoreClientPlan? { storeClient }
  package var controllers: [String] { controllerDevices ?? [] }
  package var registry: [RegistrySetting] { prefixSettings ?? [] }
  package var rendererSelection: [RendererSelection] { renderers ?? [] }

  init(
    version: String, gameFiles: [ManifestFile], gameID: GameKind? = nil,
    referencesInstallation: Bool? = nil, runtimeTuning: RuntimeTuning? = nil,
    storeClient: StoreClientPlan? = nil, controllerDevices: [String]? = nil,
    prefixSettings: [RegistrySetting]? = nil, renderers: [RendererSelection]? = nil
  ) {
    self.version = version
    self.gameFiles = gameFiles
    self.gameID = gameID
    self.referencesInstallation = referencesInstallation
    self.runtimeTuning = runtimeTuning
    self.storeClient = storeClient
    self.controllerDevices = controllerDevices
    self.prefixSettings = prefixSettings
    self.renderers = renderers
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
    // A referencing app owns no game bytes, so it must carry no inventory and name its client.
    guard references == (kind == .nfs2015) else {
      throw .operation("The game manifest does not match this app's installation contract.")
    }
    if references {
      guard gameFiles.isEmpty, let client else {
        throw .operation(
          "A referencing game manifest must carry no game files and name its store client.")
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
      // A referencing D3D11 title must say which backend serves it, and may not pick a denied one.
      _ = try RendererSelection.compatibilityDatabase(rendererSelection, kind: kind)
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
      guard file.size >= 0, file.size <= 2_000_000_000,
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
    guard seen.contains(kind.executable) else {
      throw .operation("The game executable is missing from the manifest.")
    }
  }
}
