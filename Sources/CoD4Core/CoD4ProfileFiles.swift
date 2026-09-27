import Foundation
import LauncherCore

/// Bounds profile traversal and rejects links before any profile is copied or published.
enum CoD4ProfileFiles {
  static func inventory(_ root: URL) throws -> [URL] {
    let files = FileManager.default
    let root = root.standardizedFileURL
    guard root.isFileURL, root == root.resolvingSymlinksInPath(),
      try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    else { throw LauncherError.operation("Select a real profile folder without symbolic links.") }
    var pending = [root]
    var result: [URL] = []
    var entries = 0
    var bytes = 0
    while let directory = pending.popLast() {
      guard directory.pathComponents.count - root.pathComponents.count < 16 else {
        throw LauncherError.operation("The profile has too many nested folders.")
      }
      for entry in try files.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
      {
        entries += 1
        guard entries <= 4096 else {
          throw LauncherError.operation("The profile contains too many files.")
        }
        let values = try entry.resourceValues(forKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isSymbolicLink != true else {
          throw LauncherError.operation("Profile links are not supported.")
        }
        if values.isDirectory == true {
          pending.append(entry)
        } else {
          guard values.isRegularFile == true, let size = values.fileSize, size <= 64 * 1024 * 1024
          else {
            throw LauncherError.operation("The profile contains an unsupported or oversized file.")
          }
          bytes += size
          guard bytes <= 512 * 1024 * 1024 else {
            throw LauncherError.operation("The profile exceeds 512 MiB.")
          }
          result.append(entry)
        }
      }
    }
    return result
  }

  static func copy(_ source: URL, to destination: URL) throws {
    let inventory = try inventory(source)
    let files = FileManager.default
    guard !files.fileExists(atPath: destination.path),
      !destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/")
    else { throw LauncherError.operation("Choose a new destination outside the source profile.") }
    try files.createDirectory(at: destination, withIntermediateDirectories: false)
    do {
      for file in inventory {
        let rootPath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(rootPath + "/") else {
          throw LauncherError.operation("A profile file escaped its source folder.")
        }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        let target = destination.appendingPathComponent(relative)
        guard file.standardizedFileURL.path == file.resolvingSymlinksInPath().path else {
          throw LauncherError.operation("The profile changed during copying.")
        }
        try files.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: file, to: target)
      }
      _ = try self.inventory(destination)
    } catch {
      do { try files.removeItem(at: destination) } catch {
        print("Could not remove incomplete profile: \(error)")
      }
      throw error
    }
  }
}
