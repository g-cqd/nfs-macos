import CryptoKit
import Foundation

/// Copies a manifest-bounded regular file and verifies the bytes written to the staged generation.
enum VerifiedGameFile {
  static func copy(_ entry: ManifestFile, from root: URL, to target: URL) throws {
    let source = root.appendingPathComponent(entry.path)
    let values = try source.resourceValues(forKeys: [
      .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      values.fileSize == entry.size,
      source.resolvingSymlinksInPath().path == source.standardizedFileURL.path
    else {
      throw LauncherError.operation(
        "Missing or incompatible game file: \(entry.path). Import a supported Most Wanted PC 1.3 installation."
      )
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { do { try input.close() } catch { print("Could not close game input: \(error)") } }
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
      throw LauncherError.operation("Could not create staged game file: \(entry.path)")
    }
    let output = try FileHandle(forWritingTo: target)
    defer {
      do { try output.close() } catch { print("Could not close staged game file: \(error)") }
    }
    var hash = SHA256()
    var remaining = entry.size
    while let chunk = try input.read(upToCount: min(1_048_576, remaining + 1)), !chunk.isEmpty {
      guard chunk.count <= remaining else {
        throw LauncherError.operation("Game file grew during import: \(entry.path)")
      }
      remaining -= chunk.count
      hash.update(data: chunk)
      try output.write(contentsOf: chunk)
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard remaining == 0, digest == entry.sha256 else {
      throw LauncherError.operation(
        "Game file verification failed: \(entry.path). Use a supported, complete PC 1.3 installation."
      )
    }
  }
}
