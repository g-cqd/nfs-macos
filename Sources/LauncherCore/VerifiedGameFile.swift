import CryptoKit
import Darwin
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
        "Missing or incompatible game file: \(entry.path). Import the complete PC installation matching this app's manifest."
      )
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { do { try input.close() } catch { print("Could not close game input: \(error)") } }
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    // The opened regular source is cloned atomically; the clone is hashed before publication.
    // Later writes to the working game must never modify the signed bundle's original bytes.
    let cloned = fclonefileat(input.fileDescriptor, AT_FDCWD, target.path, 0) == 0
    let cloneError = errno
    var output: FileHandle?
    let verification: FileHandle
    if cloned {
      verification = try FileHandle(forReadingFrom: target)
    } else {
      guard [ENOTSUP, EXDEV, ENOSYS, EINVAL].contains(cloneError),
        !FileManager.default.fileExists(atPath: target.path),
        FileManager.default.createFile(atPath: target.path, contents: nil)
      else {
        throw LauncherError.operation("Could not stage game file \(entry.path) (\(cloneError)).")
      }
      output = try FileHandle(forWritingTo: target)
      verification = input
    }
    defer {
      do {
        try output?.close()
        if cloned { try verification.close() }
      } catch { print("Could not close staged game file: \(error)") }
    }
    var hash = SHA256()
    var remaining = entry.size
    while let chunk = try verification.read(upToCount: min(1_048_576, remaining + 1)),
      !chunk.isEmpty
    {
      guard chunk.count <= remaining else {
        throw LauncherError.operation("Game file grew during import: \(entry.path)")
      }
      remaining -= chunk.count
      hash.update(data: chunk)
      try output?.write(contentsOf: chunk)
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard remaining == 0, digest == entry.sha256 else {
      throw LauncherError.operation(
        "Game file verification failed: \(entry.path). Use the complete PC installation matching this app's manifest."
      )
    }
  }
}
