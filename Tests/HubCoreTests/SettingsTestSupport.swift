import Darwin
import Foundation
import Testing

@testable import HubCore

/// A temporary folder removed when the test ends. Paths are real paths (`/private/var/...`).
final class TempTree {
  let root: String
  private let fileManager = FileManager.default

  init() throws {
    let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(resolved) }
    root = String(cString: resolved) + "/settings-\(UUID().uuidString)"
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  deinit { try? fileManager.removeItem(atPath: root) }

  var url: URL { URL(fileURLWithPath: root, isDirectory: true) }

  func path(_ relative: String) -> String { root + "/" + relative }

  func makeDirectory(_ relative: String) throws {
    try fileManager.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
  }

  func write(_ relative: String, _ text: String, mode: Int = 0o644) throws {
    let full = path(relative)
    try fileManager.createDirectory(
      atPath: DatastorePath.parent(of: full), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: full))
    try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: full)
  }

  func symlink(_ relative: String, to target: String) throws {
    let full = path(relative)
    try fileManager.createDirectory(
      atPath: DatastorePath.parent(of: full), withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(atPath: full, withDestinationPath: target)
  }

  func exists(_ relative: String) -> Bool {
    var info = stat()
    return lstat(path(relative), &info) == 0
  }

  func inode(_ relative: String) -> UInt64? {
    var info = stat()
    return lstat(path(relative), &info) == 0 ? UInt64(info.st_ino) : nil
  }

  func contents(_ relative: String) -> String? {
    try? String(contentsOfFile: path(relative), encoding: .utf8)
  }

  func names(_ relative: String) -> [String] {
    ((try? fileManager.contentsOfDirectory(atPath: path(relative))) ?? []).sorted()
  }

  /// A valid `Hub/hub.json` for the data store at `relative`, naming `<relative>/Prefix`.
  func writeHubConfig(in relative: String, runtimeSHA: String = String(repeating: "ab", count: 32))
    throws
  {
    let config = HubConfig(
      schemaVersion: 1, prefix: path(relative) + "/Prefix", runtime: "hub-0",
      runtimeManifestSHA256: runtimeSHA, generation: 0)
    try makeDirectory(relative + "/Hub")
    try config.write(to: URL(fileURLWithPath: path(relative + "/Hub/hub.json")))
  }
}

/// Volume answers from lists, so a test can have an unplugged drive, a case-insensitive or a
/// read-only volume, or a second drive, without any of them.
struct FakeCapabilities: DataStoreCapabilities {
  var unmountedVolumes: Set<String> = []
  var caseInsensitivePrefixes: [String] = []
  var readOnlyPrefixes: [String] = []
  var capacity = DataStoreCapacity(free: 500 << 30, total: 1000 << 30)
  /// Paths under these prefixes are on another device (device 2); everything else is device 1.
  var otherDevicePrefixes: [String] = []

  func isMounted(volumeRoot: String) -> Bool { !unmountedVolumes.contains(volumeRoot) }

  func isCaseSensitive(at path: String) -> Bool {
    !caseInsensitivePrefixes.contains { DatastorePath.isWithin(path, $0) }
  }

  func isWritable(at path: String) -> Bool {
    !readOnlyPrefixes.contains { DatastorePath.isWithin(path, $0) }
  }

  func capacity(at path: String) -> DataStoreCapacity? { capacity }

  func device(of path: String) -> Int64? {
    otherDevicePrefixes.contains { DatastorePath.isWithin(path, $0) } ? 2 : 1
  }
}

/// A probe that finds nothing running, or reports one open file.
struct QuietProbe: DatastoreProbe {
  var openFiles: [String] = []
  func processCommandLines() throws(HubError) -> [String] { [] }
  func openFilePaths() throws(HubError) -> [String] { openFiles }
}

extension DatastoreCheckEnvironment {
  /// No Wine socket folders, so a prefix check only looks at open files and command lines.
  static var quiet: DatastoreCheckEnvironment {
    DatastoreCheckEnvironment(now: Date(), userID: 501, socketRoots: [])
  }
}

/// A minimal runtime app that `RuntimeApp.locate` accepts: the structure and the hashes, with an
/// empty Wine tree.
func makeFakeRuntimeApp(in tree: TempTree, at relative: String, id: String = "hub-0") throws
  -> String
{
  let manifest = "manifest of \(id)\n"
  let sha = DatastoreIO.sha256Hex(Data(manifest.utf8))
  let record = RuntimeRecord(
    id: id, manifestSHA256: sha, source: "/tmp/source", installedAt: Date(timeIntervalSince1970: 0),
    helpers: [:])
  let metadata = relative + "/Contents/Resources/runtime"
  try tree.write(relative + "/Contents/Info.plist", "<plist/>")
  try tree.write(
    metadata + "/runtime.json",
    String(decoding: try RuntimeRecord.encoder().encode(record), as: UTF8.self))
  try tree.write(metadata + "/\(id).manifest", manifest)
  try tree.write(metadata + "/\(id).manifest.links", "")
  try tree.write(relative + "/Contents/SharedSupport/Wine/bin/wine", "#!/bin/sh\n", mode: 0o755)
  try tree.makeDirectory(relative + "/Contents/Helpers")
  try tree.symlink(relative + "/Contents/MacOS/wine", to: RuntimeApp.launcherLinkTarget)
  return sha
}
