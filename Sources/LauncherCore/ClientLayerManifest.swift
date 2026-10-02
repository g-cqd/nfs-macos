import Foundation

/// The manifest of a client layer: the store client's own files and registry entries, installed once
/// at build time by the publisher's official installer and carried by the app as plain data.
///
/// The manifest names every file by size and SHA-256, every registry part by SHA-256, and holds
/// no account, session, machine or user state. `Packaging/client_layer.py` writes it and enforces the
/// same rules when it is built, and the audit enforces them again on the finished app. This type
/// enforces them a third time, on the player's Mac, before anything is written to their prefix.
package struct ClientLayerManifest: Codable, Equatable, Sendable {
  package struct Installer: Codable, Equatable, Sendable {
    package let fileName: String
    package let sha256: String
    package let bytes: Int
    package let signer: String
  }

  package struct Package: Codable, Equatable, Sendable {
    package let fileName: String
    package let sha256: String
    package let bytes: Int
  }

  /// The client that was installed, and the installer and package it came from.
  package struct Client: Codable, Equatable, Sendable {
    package let name: String
    package let version: String
    package let installer: Installer
    package let package: Package
  }

  package struct Entry: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case file, directory }

    /// Relative to the prefix's `drive_c`, with forward slashes.
    package let path: String
    package let kind: Kind
    package let mode: Int
    package let size: Int?
    package let sha256: String?
    /// Extended attributes by name, base64 encoded; only Wine's own are accepted.
    package let xattrs: [String: String]?
  }

  /// Wine hive text for the kept keys, appended to the prefix's hive file.
  package struct RegistryPart: Codable, Equatable, Sendable {
    package let hive: String
    package let file: String
    package let sha256: String
    package let keys: Int
  }

  package let format: Int
  package let client: Client
  package let entries: [Entry]
  package let registry: [RegistryPart]

  static let supportedFormat = 1
  static let maximumEntries = 20_000
  static let maximumBytes = 2 * 1024 * 1024 * 1024
  static let hives = ["system.reg", "user.reg"]
  /// Wine keeps DOS attribute bits and an NTFS junction's target in these; nothing else is carried.
  static let allowedAttributes: Set<String> = ["user.DOSATTRIB", "user.WINEREPARSE"]
  static let maximumAttributeBytes = 4096

  /// Rejects a manifest that is malformed or that would write outside what a client layer may hold.
  /// - Complexity: O(entries).
  package func validate() throws(LauncherError) {
    guard format == Self.supportedFormat, (1...Self.maximumEntries).contains(entries.count) else {
      throw .operation("The EA app that comes with this app has an unsupported description.")
    }
    for text in [client.name, client.version] {
      guard !text.isEmpty, text.utf8.count <= 64,
        text.utf8.allSatisfy({ (32...126).contains($0) })
      else {
        throw .operation("The EA app's description names an unusable client.")
      }
    }
    var seen = Set<String>()
    var total = 0
    for entry in entries {
      try ClientLayerPolicy.validate(path: entry.path)
      guard seen.insert(entry.path.lowercased()).inserted else {
        throw .operation("The EA app's files list a path twice: \(entry.path)")
      }
      try validate(attributes: entry)
      switch entry.kind {
      case .directory:
        guard entry.mode == 0o755, entry.size == nil, entry.sha256 == nil else {
          throw .operation("The EA app's files hold a malformed folder: \(entry.path)")
        }
      case .file:
        guard [0o644, 0o755].contains(entry.mode), let size = entry.size, size >= 0,
          let digest = entry.sha256, Self.isDigest(digest)
        else {
          throw .operation("The EA app's files hold a malformed file: \(entry.path)")
        }
        total += size
        guard total <= Self.maximumBytes else {
          throw .operation("The EA app's files exceed their size limit.")
        }
      }
    }
    var hives = Set<String>()
    for part in registry {
      guard Self.hives.contains(part.hive), part.file == "registry/\(part.hive).part",
        Self.isDigest(part.sha256), part.keys > 0, hives.insert(part.hive).inserted
      else {
        throw .operation("The EA app's registry entries are malformed: \(part.hive)")
      }
    }
  }

  private func validate(attributes entry: Entry) throws(LauncherError) {
    for (name, value) in entry.xattrs ?? [:] {
      guard Self.allowedAttributes.contains(name),
        let bytes = Data(base64Encoded: value), bytes.count <= Self.maximumAttributeBytes
      else {
        throw .operation("The EA app's files carry an unreviewed attribute: \(entry.path)")
      }
    }
  }

  static func isDigest(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
