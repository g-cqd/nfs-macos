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

  static let measured = [
    RendererSelection(
      api: "dxgi", backend: "dxmt", executable: "NFS16.exe",
      reason: "Reaches menus where D3DMetal faults on a timestamp query"),
    RendererSelection(
      api: "dxgi", backend: "gptk", executable: "EADesktop.exe",
      reason: "The EA client renders its interface correctly on D3DMetal"),
  ]

  @Test
  func `serves Direct3D 11 through the bundle's chosen DXGI backend, never through mtld3d`()
    throws
  {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Need for Speed.app"),
      support: URL(fileURLWithPath: "/tmp/NFS Player"), game: .nfs2015)
    let environment = try LaunchEnvironment.make(
      paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support,
      tuning: RuntimeTuning([
        "WINE_TF_EMULATION": "1", "WINE_TF_MAX_STEPS": "0", "WINE_TF_MAX_NS": "0",
      ]), renderers: Self.measured)
    let rules = try #require(environment["WINE_COMPATDB"])
    #expect(rules.hasPrefix("v=3\n"))
    #expect(rules.contains("exe=NFS16.exe;dxgi=dxmt"))
    // The store client is a separate program, so the backend denied to the game may serve it.
    #expect(rules.contains("exe=EADesktop.exe;dxgi=gptk"))
    #expect(!rules.contains("mtld3d"))
    #expect(!rules.contains("exe=NFS16.exe;dxgi=gptk"))
    #expect(environment["WINEDLLPATH"] == nil)
    #expect(environment["WINEDLLOVERRIDES"]?.contains("IGOProxy32.exe=d") == true)
    #expect(environment["WINE_TF_EMULATION"] == "1")
    #expect(environment["WINE_TF_MAX_STEPS"] == "0")
    #expect(environment["WINE_TF_MAX_NS"] == "0")
  }

  @Test
  func `refuses the renderer backend this game is measured to crash on`() throws {
    #expect(GameKind.nfs2015.deniedRendererBackends["gptk"] != nil)
    #expect(GameKind.cod4.deniedRendererBackends.isEmpty)
    // Named directly, and by a catch-all that would also serve the game.
    for denied in [
      RendererSelection(api: "dxgi", backend: "gptk", executable: "NFS16.exe"),
      RendererSelection(api: "dxgi", backend: "gptk", executable: "nfs16.exe"),
      RendererSelection(api: "dxgi", backend: "gptk"),
    ] {
      let error = #expect(throws: LauncherError.self) {
        try RendererSelection.compatibilityDatabase([denied], kind: .nfs2015)
      }
      #expect(error?.localizedDescription.contains("timestamp quer") == true)
    }
    // The same backend is not denied for a game that has no such measurement.
    #expect(
      try RendererSelection.compatibilityDatabase(
        [RendererSelection(api: "dxgi", backend: "gptk")], kind: .cod4
      ).contains("dxgi=gptk"))
  }

  @Test
  func `keeps the fixed Direct3D 9 rule for a game that declares no selection`() throws {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/tmp/Game.app"),
      support: URL(fileURLWithPath: "/tmp/Player"), game: .nfsmw)
    let rules = try #require(
      try LaunchEnvironment.make(
        paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support
      )["WINE_COMPATDB"])
    #expect(rules.contains("d3d9=mtld3d"))
    #expect(rules.contains("dxgi=wined3d"))
  }

  @Test(arguments: [
    RendererSelection(api: "dxgi", backend: "DXVK"),
    RendererSelection(api: "dxgi", backend: "dxvk", executable: "../escape.exe"),
    RendererSelection(api: "dxgi", backend: "dxvk", executable: "NFS16"),
    RendererSelection(api: "dxgi", backend: "dxvk", reason: "a;exe=*;dxgi=gptk"),
  ])
  func `refuses a renderer rule that is malformed or could inject another rule`(
    selection: RendererSelection
  ) {
    #expect(throws: LauncherError.self) { try selection.validate() }
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
      controllerDevices: ["054C/05C4"],
      prefixSettings: [
        RegistrySetting(
          hive: .currentUser, path: #"Software\Wine\Mac Driver"#, name: "RetinaMode",
          value: "Y", kind: .string)
      ], renderers: Self.measured)
    try manifest.validate()
    #expect(manifest.registry.count == 1)
    #expect(manifest.rendererSelection.count == 2)
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
      BundleManifest(
        version: "abc123", gameFiles: [], gameID: .nfs2015, referencesInstallation: true,
        storeClient: Self.plan,
        renderers: [RendererSelection(api: "dxgi", backend: "gptk")]),
      BundleManifest(
        version: "abc123", gameFiles: [], gameID: .nfs2015, referencesInstallation: true,
        storeClient: Self.plan,
        renderers: [RendererSelection(api: "dxgi", backend: "gptk", executable: "NFS16.exe")]),
    ] {
      #expect(throws: LauncherError.self) { try manifest.validate() }
    }
  }

  @Test
  func `rejects prefix settings on a manifest whose app owns its prefix`() throws {
    let file = ManifestFile(path: "speed.exe", size: 1, sha256: String(repeating: "a", count: 64))
    #expect(throws: LauncherError.self) {
      try BundleManifest(
        version: "abc123", gameFiles: [file], gameID: .nfsmw,
        prefixSettings: [
          RegistrySetting(
            hive: .currentUser, path: "Software", name: "A", value: "B", kind: .string)
        ]
      ).validate()
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
