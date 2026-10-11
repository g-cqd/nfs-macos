import Darwin
import Foundation
import LauncherCore

/// A built instance as the library shows it.
package struct InstanceSummary: Identifiable, Equatable, Sendable {
  package var id: String
  package var gameID: GameID
  package var createdAt: Date
  /// The bytes the instance's real files take.
  package var realBytes: Int64
  package var url: URL

  package init(id: String, gameID: GameID, createdAt: Date, realBytes: Int64, url: URL) {
    self.id = id
    self.gameID = gameID
    self.createdAt = createdAt
    self.realBytes = realBytes
    self.url = url
  }
}

package enum InstanceStore {
  /// Lists the instances under `instances`, newest first.
  ///
  /// The id of an instance is the name of its folder. A folder is skipped, silently, when its name
  /// is not a valid ``InstanceID``, when it is a link or not a folder, when its `instance.json`
  /// is missing, oversized or undecodable (only its header fields are decoded, never its entries), or when the manifest names a different id than the
  /// folder (for example a Finder "x copy" of an instance). Hidden folders (`.staging-*`,
  /// `.trash-*`) are never listed.
  /// - Complexity: O(c + m) for c child folders and m bytes of manifests read.
  package static func list(instances: URL) -> [InstanceSummary] {
    let instancesPath = instances.path
    let children: [String]
    do {
      children = try FileManager.default.contentsOfDirectory(atPath: instancesPath)
    } catch {
      return []
    }
    var summaries: [InstanceSummary] = []
    for child in children where !child.hasPrefix(".") {
      guard let summary = summary(folder: child, in: instancesPath) else { continue }
      summaries.append(summary)
    }
    return summaries.sorted { $0.createdAt > $1.createdAt }
  }

  /// The summary of one child folder, or `nil` when it is not a well-formed instance.
  private static func summary(folder: String, in instancesPath: String) -> InstanceSummary? {
    guard let id = try? InstanceID(folder) else { return nil }
    let folderPath = instancesPath + "/" + folder
    var info = stat()
    guard lstat(folderPath, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      return nil
    }
    do {
      let data = try BoundedFile.read(
        URL(fileURLWithPath: folderPath + "/instance.json"), limit: InstanceManifest.maxFileBytes)
      let header = try InstanceManifest.decoder().decode(InstanceManifestHeader.self, from: data)
      guard header.instanceID == id.rawValue else { return nil }
      return InstanceSummary(
        id: id.rawValue, gameID: header.gameID, createdAt: header.createdAt,
        realBytes: header.realBytes, url: URL(fileURLWithPath: folderPath, isDirectory: true))
    } catch {
      return nil
    }
  }
}
