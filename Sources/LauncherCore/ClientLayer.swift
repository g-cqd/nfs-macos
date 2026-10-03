import CryptoKit
import Foundation

/// The store client that comes with a bundled app, applied to a fresh prefix on first launch.
///
/// A layer is the publisher's own client, installed once at build time by the publisher's official
/// installer and shipped as data: program files, and the registry entries and services that
/// installer created. It contains no account, session, token, machine identifier or log, and the
/// player signs in to the client themselves. Applying it replaces running that installer; the
/// installer button stays available for a player who needs a newer client.
///
/// Applying edits the prefix's hive files directly, so it must run while the prefix's Wine server
/// is stopped, which is the state of the unpublished prefix during first-launch preparation.
package struct ClientLayer: Sendable {
  package let manifest: ClientLayerManifest
  /// The SHA-256 of the manifest, which pins every blob and registry part it names.
  package let digest: String
  private let root: URL

  static let manifestName = "client-layer.json"
  static let manifestLimit = 8 * 1024 * 1024

  /// - Parameters:
  ///   - root: The layer's folder inside the app.
  ///   - expectedSHA256: The digest the game manifest pins for the layer's manifest.
  /// - Throws: A failure when the manifest is missing, differs from its pin, or breaks a rule.
  /// - Complexity: O(manifest bytes + entries).
  package init(root: URL, expectedSHA256: String) throws(LauncherError) {
    let data = try BoundedFile.read(
      root.appendingPathComponent(Self.manifestName), limit: Self.manifestLimit)
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actual == expectedSHA256 else {
      throw .operation(
        "The EA app that comes with this app does not match its pin; reinstall the app.")
    }
    do {
      manifest = try JSONDecoder().decode(ClientLayerManifest.self, from: data)
    } catch {
      throw .operation("The EA app's description is unreadable: \(error.localizedDescription)")
    }
    try manifest.validate()
    // Resolved once, so that the file operations below can refuse any link on the path to a blob.
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    digest = actual
  }

  /// The client's name and version, for the player's log.
  package var summary: String { "\(manifest.client.name) \(manifest.client.version)" }

  /// Writes the client's files into the prefix and appends its registry entries to the hives.
  ///
  /// - Parameter prefix: A Windows prefix with a `drive_c` and its hive files, whose Wine server is stopped.
  /// - Throws: A failure naming the entry; a partly written prefix must be discarded by the caller.
  /// - Complexity: O(layer bytes) for the verification of every file; cloning needs no copy.
  package func apply(to prefix: URL) throws(LauncherError) {
    let prefix = prefix.standardizedFileURL.resolvingSymlinksInPath()
    let driveC = prefix.appendingPathComponent("drive_c")
    var info = URLResourceValues()
    do { info = try driveC.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) } catch {
      throw .operation("The Windows folder has no drive_c.")
    }
    guard info.isDirectory == true, info.isSymbolicLink != true else {
      throw .operation("The Windows folder has no drive_c.")
    }
    let blobs = root.appendingPathComponent("blobs")
    for entry in manifest.entries {
      try ClientLayerFile.install(entry, blobs: blobs, into: driveC)
    }
    for part in manifest.registry { try append(part, to: prefix) }
  }

  private func append(_ part: ClientLayerManifest.RegistryPart, to prefix: URL)
    throws(LauncherError)
  {
    let data = try BoundedFile.read(
      root.appendingPathComponent(part.file), limit: RegistryHiveText.partLimit)
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == part.sha256
    else {
      throw .operation("The EA app's registry entries do not match their pin: \(part.hive)")
    }
    try RegistryHiveText.validate(part: data, hive: part.hive, keys: part.keys)
    let hive = prefix.appendingPathComponent(part.hive)
    let merged = try RegistryHiveText.merged(
      hive: try BoundedFile.read(hive, limit: RegistryHiveText.hiveLimit), part: data)
    let pending = prefix.appendingPathComponent(".\(part.hive).client-layer")
    do {
      try merged.write(to: pending, options: .atomic)
      _ = try FileManager.default.replaceItemAt(hive, withItemAt: pending)
    } catch {
      do { try FileManager.default.removeItem(at: pending) } catch {
        print("Could not remove the staged registry file: \(error)")
      }
      throw .operation(
        "Could not record the EA app's registry entries: \(error.localizedDescription)")
    }
  }
}
