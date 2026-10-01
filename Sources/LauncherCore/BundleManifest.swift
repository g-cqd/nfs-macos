import Foundation

/// A bounded inventory used to verify a game generation before publishing it.
package struct BundleManifest: Codable {
  let version: String
  let gameFiles: [ManifestFile]
  let gameID: GameKind?
  /// Present for an import-only app: the player's files are recognised and inventoried at import time.
  package let importRules: ImportRules?
  var kind: GameKind { gameID ?? .nfsmw }

  init(
    version: String, gameFiles: [ManifestFile], gameID: GameKind? = nil,
    importRules: ImportRules? = nil
  ) {
    self.version = version
    self.gameFiles = gameFiles
    self.gameID = gameID
    self.importRules = importRules
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
      }),
      !gameFiles.isEmpty, gameFiles.count <= 30_000
    else {
      throw .operation("The game manifest has an invalid version or file count.")
    }
    var seen = Set<String>()
    var total = 0
    for file in gameFiles {
      try ManifestFile.validate(path: file.path)
      guard file.size >= 0, file.size <= kind.fileByteLimit,
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
    if let importRules {
      try importRules.validate()
      guard importRules.executable.lowercased() == kind.executable.lowercased() else {
        throw .operation("The game recognition rules belong to a different executable.")
      }
      guard importRules.maximumBytes <= kind.byteLimit else {
        throw .operation("The game recognition rules allow more data than this game supports.")
      }
    } else {
      guard seen.contains(kind.executable.lowercased()) else {
        throw .operation("The game executable is missing from the manifest.")
      }
    }
  }
}
