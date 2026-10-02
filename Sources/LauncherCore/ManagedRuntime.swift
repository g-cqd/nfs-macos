import Foundation

/// A managed-code (.NET) runtime the bundle carries for the installers that need one.
///
/// EA's installer is a Windows Installer package with a managed custom action. Without a .NET
/// runtime in the prefix that action cannot start, Windows Installer reports error 1603, and the
/// installer ends with status 1 having changed nothing. Wine's own free replacement, Wine Mono,
/// is shipped as a pinned installer and put into the app's own prefix before the EA installer runs.
package struct ManagedRuntime: Codable, Equatable, Sendable {
  /// The installer's location relative to the app's resources, such as `Addons/wine-mono.msi`.
  package let file: String
  /// The installer's lowercase hexadecimal SHA-256; nothing that differs is ever run.
  package let sha256: String
  /// The runtime's upstream version, for the player's log and the provenance record.
  package let version: String

  /// The largest installer accepted; Wine Mono's is about 85 MB.
  static let sizeLimit = 512 * 1024 * 1024
  /// Where the installed runtime leaves its two native libraries, below `drive_c`.
  static let libraries = [
    "windows/mono/mono-2.0/bin/libmono-2.0-x86_64.dll",
    "windows/mono/mono-2.0/bin/libmono-2.0-x86.dll",
  ]

  package init(file: String, sha256: String, version: String) {
    self.file = file
    self.sha256 = sha256
    self.version = version
  }

  package func validate() throws(LauncherError) {
    try ManifestFile.validate(path: file)
    guard file.lowercased().hasSuffix(".msi"),
      sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      (1...32).contains(version.utf8.count),
      version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 })
    else {
      throw .operation("The managed runtime declaration is not a pinned installer package.")
    }
  }

  /// Whether the prefix already holds the runtime, judged by its libraries rather than a record
  /// of this app, so a prefix made by anything else that has them is left alone.
  package func isInstalled(in prefix: URL) -> Bool {
    let driveC = prefix.appendingPathComponent("drive_c")
    return Self.libraries.allSatisfy { library in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(
        atPath: driveC.appendingPathComponent(library).path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    }
  }

  /// The installer inside the app, once its bytes are proven to be the pinned ones.
  /// - Complexity: O(installer bytes), streamed.
  package func installer(in resources: URL) throws(LauncherError) -> URL {
    try validate()
    let url = resources.appendingPathComponent(file)
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
    } catch {
      throw .operation("The managed runtime installer is missing from the app.")
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size > 0, size <= Self.sizeLimit,
      url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
    else {
      throw .operation("The managed runtime installer in the app is not a regular file.")
    }
    guard try FileDigest.sha256(of: url, size: size) == sha256 else {
      throw .operation("The managed runtime installer does not match its pin; reinstall the app.")
    }
    return url
  }
}
