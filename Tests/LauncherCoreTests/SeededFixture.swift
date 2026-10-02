import CryptoKit
import Foundation

@testable import LauncherCore

/// A synthetic bundled Need for Speed (2015) app: tiny stand-in files, never real game data.
struct SeededFixture {
  static let gameRoot = "Program Files/EA Games/Need for Speed"
  static let plan = StoreClientPlan(
    name: "EA app", installRoot: "Program Files/Electronic Arts/EA Desktop",
    clientExecutable: "EA Desktop/EADesktop.exe", clientArguments: ["--in-process-gpu"],
    launcherExecutable: "EA Desktop/EALauncher.exe",
    launchURL: "origin2://game/launch/?offerIds={offer}", offerID: "1024486",
    signInEvidence: ["AppData/Local/Electronic Arts/EA Desktop"],
    readinessEvidence: ["AppData/Local/Electronic Arts/EA Desktop/Logs"], readinessChildren: 1,
    readinessSeconds: 120, gameRoot: gameRoot)
  static let renderers = [
    RendererSelection(api: "dxgi", backend: "dxmt", executable: "NFS16.exe", reason: "measured"),
    RendererSelection(
      api: "dxgi", backend: "dxmt", executable: "EADesktop.exe", reason: "measured"),
  ]
  static let contents: [String: String] = [
    "NFS16.exe": "synthetic game executable",
    "Core/Activation64.dll": "synthetic activation library",
    "Data/cas_01.cas": String(repeating: "synthetic data ", count: 64),
    "Support/mnfst.txt": "\"NFS16.exe\"\r\n",
  ]

  let root: URL
  let paths: AppPaths
  let manifest: BundleManifest

  init(version: String = "v1", contents: [String: String] = Self.contents) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    paths = try AppPaths(
      bundle: root.appendingPathComponent("Need for Speed.app"),
      support: root.appendingPathComponent("Player"), game: .nfs2015)
    var entries: [ManifestFile] = []
    for (path, text) in contents.sorted(by: { $0.key < $1.key }) {
      let url = paths.template.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let bytes = Data(text.utf8)
      try bytes.write(to: url)
      entries.append(
        ManifestFile(
          path: path, size: bytes.count,
          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
    }
    manifest = Self.manifest(version: version, files: entries)
  }

  static func manifest(version: String, files: [ManifestFile]) -> BundleManifest {
    BundleManifest(
      version: version, gameFiles: files, gameID: .nfs2015,
      runtimeTuning: RuntimeTuning(["WINE_TF_EMULATION": "1"]), storeClient: plan,
      controllerDevices: ["054C/05C4"], renderers: renderers)
  }

  /// Where the seeded game lands inside the app's own prefix.
  var seededGame: URL {
    paths.prefix.appendingPathComponent("drive_c").appendingPathComponent(Self.gameRoot)
  }

  func remove() {
    do { try FileManager.default.removeItem(at: root) } catch {
      print("Fixture cleanup failed: \(error)")
    }
  }
}
