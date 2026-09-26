import CryptoKit
import Foundation

@testable import LauncherCore

struct InstallerFixture {
  let root: URL
  let paths: AppPaths
  let manifest: BundleManifest

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    paths = try AppPaths(
      bundle: root.appendingPathComponent("Most Wanted.app"),
      support: root.appendingPathComponent("Player"))
    try FileManager.default.createDirectory(at: paths.template, withIntermediateDirectories: true)
    let bytes = Data("test executable".utf8)
    try bytes.write(to: paths.template.appendingPathComponent("speed.exe"))
    manifest = BundleManifest(
      version: "v1",
      gameFiles: [
        ManifestFile(
          path: "speed.exe", size: bytes.count,
          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
      ])
  }

  func remove() {
    do { try FileManager.default.removeItem(at: root) } catch {
      print("Fixture cleanup failed: \(error)")
    }
  }
}
