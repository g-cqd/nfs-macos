import Foundation
import Testing

@testable import LauncherCore

struct NFS2015GameKindTests {
  static let plan = StoreClientPlan(
    name: "EA app", installRoot: "Program Files/Electronic Arts/EA Desktop",
    clientExecutable: "EA Desktop/EADesktop.exe", clientArguments: ["--in-process-gpu"],
    launcherExecutable: "EA Desktop/EALauncher.exe",
    launchURL: "origin2://game/launch/?offerIds={offer}", offerID: "1024486",
    signInEvidence: ["AppData/Local/Electronic Arts/EA Desktop"],
    readinessEvidence: ["AppData/Local/Electronic Arts/EA Desktop/Logs"], readinessChildren: 1,
    readinessSeconds: 120, gameRoot: "Program Files/EA Games/Need for Speed")

  @Test
  func `names the game's own executable, folder and helper`() {
    #expect(GameKind.nfs2015.executable == "NFS16.exe")
    #expect(GameKind.nfs2015.helper == "NFS2015Session")
    #expect(GameKind.nfs2015.title == "Need for Speed")
    #expect(GameKind(rawValue: "nfs2015") == .nfs2015)
  }

  @Test
  func `references the player's installation instead of copying it`() {
    #expect(!GameKind.nfs2015.copiesGameData)
    #expect(GameKind.nfs2015.requiresStoreClient)
    #expect(GameKind.nfs2015.preservedConfiguration.isEmpty)
    #expect(GameKind.nfsmw.copiesGameData && GameKind.cod4.copiesGameData)
    #expect(!GameKind.nfsmw.requiresStoreClient && !GameKind.cod4.requiresStoreClient)
  }

  @Test
  func `serves Direct3D 11 through DXGI and never through the Direct3D 9 renderer`() throws {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Need for Speed.app"),
      support: URL(fileURLWithPath: "/tmp/NFS Player"), game: .nfs2015)
    let environment = try LaunchEnvironment.make(
      paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support,
      tuning: RuntimeTuning([
        "WINE_TF_EMULATION": "1", "WINE_TF_MAX_STEPS": "0", "WINE_TF_MAX_NS": "0",
      ]))
    let rules = try #require(environment["WINE_COMPATDB"])
    #expect(rules.contains("dxgi=gptk"))
    #expect(!rules.contains("mtld3d"))
    #expect(environment["WINEDLLPATH"] == nil)
    #expect(environment["WINEDLLOVERRIDES"]?.contains("IGOProxy32.exe=d") == true)
    #expect(environment["WINE_TF_EMULATION"] == "1")
    #expect(environment["WINE_TF_MAX_STEPS"] == "0")
    #expect(environment["WINE_TF_MAX_NS"] == "0")
  }

  @Test(arguments: [
    ["WINE_TF_EMULATION": "yes"], ["DYLD_INSERT_LIBRARIES": "/tmp/x"], ["WINE_TF_MAX_NS": ""],
  ])
  func `refuses a runtime switch it does not support`(values: [String: String]) {
    #expect(throws: LauncherError.self) { try RuntimeTuning(values).validate() }
  }

  @Test
  func `accepts a referencing manifest with no game files`() throws {
    let manifest = BundleManifest(
      version: "abc123", gameFiles: [], gameID: .nfs2015, referencesInstallation: true,
      runtimeTuning: RuntimeTuning(["WINE_TF_EMULATION": "1"]), storeClient: Self.plan,
      controllerDevices: ["054C/05C4"])
    try manifest.validate()
    #expect(manifest.references)
    #expect(manifest.client?.launchRequest == "origin2://game/launch/?offerIds=1024486")
    #expect(manifest.controllers == ["054C/05C4"])
  }

  @Test
  func `rejects a referencing manifest that carries game files or omits its client`() throws {
    let file = ManifestFile(path: "NFS16.exe", size: 1, sha256: String(repeating: "a", count: 64))
    for manifest in [
      BundleManifest(
        version: "abc123", gameFiles: [file], gameID: .nfs2015, referencesInstallation: true,
        storeClient: Self.plan),
      BundleManifest(
        version: "abc123", gameFiles: [], gameID: .nfs2015, referencesInstallation: true),
      BundleManifest(version: "abc123", gameFiles: [], gameID: .nfs2015),
      BundleManifest(
        version: "abc123", gameFiles: [], gameID: .nfs2015, referencesInstallation: true,
        storeClient: Self.plan, controllerDevices: ["054C"]),
    ] {
      #expect(throws: LauncherError.self) { try manifest.validate() }
    }
  }

  @Test
  func `rejects a copying manifest that claims to reference an installation`() throws {
    let file = ManifestFile(path: "speed.exe", size: 1, sha256: String(repeating: "a", count: 64))
    #expect(throws: LauncherError.self) {
      try BundleManifest(
        version: "abc123", gameFiles: [file], gameID: .nfsmw, referencesInstallation: true
      ).validate()
    }
    #expect(throws: LauncherError.self) {
      try BundleManifest(
        version: "abc123", gameFiles: [file], gameID: .nfsmw, storeClient: Self.plan
      ).validate()
    }
  }

  @Test
  func `refuses to publish a copy for a referencing game`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
      bundle: root.appendingPathComponent("Game.app"),
      support: root.appendingPathComponent("Player"), game: .nfs2015)
    let manifest = BundleManifest(
      version: "abc123", gameFiles: [], gameID: .nfs2015, referencesInstallation: true,
      storeClient: Self.plan)
    #expect(throws: LauncherError.self) {
      try GameInstaller(paths: paths, manifest: manifest).prepare { _ in }
    }
  }
}
