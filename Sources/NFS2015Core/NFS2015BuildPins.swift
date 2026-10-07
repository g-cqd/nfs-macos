import Foundation
import LauncherCore

/// What this build of the app is made of, read from the files it carries.
///
/// A crash report names the build so a failure on another Mac can be matched to the exact
/// runtime inputs: the renderer and x87 sidecar revisions, the Wine runtime file hashes, the
/// runtime switches and the client layer. Everything comes from `runtime-provenance.json`,
/// `game-manifest.json` and `Info.plist` in the app; a file that is missing or unreadable leaves
/// its fields empty, and reading never fails.
package struct NFS2015BuildPins: Equatable, Sendable {
  package var bundleVersion: String?
  package var gameManifestVersion: String?
  package var runtimeProfile: String?
  /// Source revisions by name, such as `mtld3d` and `x87sidecar`.
  package var sources: [String: String] = [:]
  package var runtimeHashes: [String: String] = [:]
  package var sidecarSHA256: String?
  package var runtimeTuning: [String: String] = [:]
  package var clientLayerSHA256: String?

  private struct Provenance: Decodable {
    var runtimeProfile: String?
    var sources: [String: String]?
    var inputRuntimeHashes: [String: String]?
    var inputSidecarSHA256: String?
    var runtimeTuning: [String: String]?
  }

  private struct Info: Decodable {
    var version: String?

    private enum CodingKeys: String, CodingKey { case version = "CFBundleVersion" }
  }

  package init() {}

  /// - Parameters:
  ///   - bundle: The app bundle.
  ///   - manifest: The app's game manifest, when it could be read.
  package init(bundle: URL, manifest: BundleManifest?) {
    let resources = bundle.appendingPathComponent("Contents/Resources")
    if let data = try? BoundedFile.read(
      resources.appendingPathComponent("runtime-provenance.json"), limit: 1_048_576),
      let provenance = try? JSONDecoder().decode(Provenance.self, from: data)
    {
      runtimeProfile = provenance.runtimeProfile
      sources = provenance.sources ?? [:]
      runtimeHashes = provenance.inputRuntimeHashes ?? [:]
      sidecarSHA256 = provenance.inputSidecarSHA256
      runtimeTuning = provenance.runtimeTuning ?? [:]
    }
    if let data = try? BoundedFile.read(
      bundle.appendingPathComponent("Contents/Info.plist"), limit: 262_144)
    {
      bundleVersion = (try? PropertyListDecoder().decode(Info.self, from: data))?.version
    }
    gameManifestVersion = manifest?.version
    clientLayerSHA256 = manifest?.layer?.manifestSHA256
  }

  /// The report's build lines, each short and free of names.
  package var lines: [String] {
    func list(_ values: [String: String]) -> String {
      values.isEmpty
        ? "none recorded"
        : values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
    var lines = [
      "app build: \(bundleVersion ?? "unknown"), game manifest \(gameManifestVersion ?? "unknown")",
      "runtime profile: \(runtimeProfile ?? "unknown")",
      "sources: \(list(sources))",
      "x87 sidecar sha256: \(sidecarSHA256 ?? "unknown")",
      "runtime switches in the recipe: \(list(runtimeTuning))",
      "client layer sha256: \(clientLayerSHA256 ?? "none")",
    ]
    for (path, hash) in runtimeHashes.sorted(by: { $0.key < $1.key }) {
      lines.append("runtime file \(path) sha256 \(hash)")
    }
    return lines
  }
}
