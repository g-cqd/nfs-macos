import Foundation

/// Where an app's game manifest says its client layer is, and the digest that pins it.
///
/// The recipe pins the layer's digest and the packager copies it here, inside the signed bundle,
/// so a layer swapped for another one is refused before any of it is applied.
package struct ClientLayerReference: Codable, Equatable, Sendable {
  /// The layer's folder name below the app's resources.
  package let path: String
  /// The SHA-256 of the layer's manifest.
  package let manifestSHA256: String
  /// The client version the layer carries, for the player's log.
  package let version: String

  package init(path: String, manifestSHA256: String, version: String) {
    self.path = path
    self.manifestSHA256 = manifestSHA256
    self.version = version
  }

  package func validate() throws(LauncherError) {
    try ManifestFile.validate(path: path)
    guard !path.contains("/"), ClientLayerManifest.isDigest(manifestSHA256),
      (1...32).contains(version.utf8.count),
      version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 })
    else {
      throw .operation("The client layer declaration is not a pinned folder.")
    }
  }
}
