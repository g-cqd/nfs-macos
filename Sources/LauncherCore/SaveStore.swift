import CryptoKit
import Foundation

/// Profile operations for the locked session helper. A stale fingerprint rejects writes.
package struct SaveStore {
  private let paths: AppPaths
  private let files = FileManager.default
  package init(paths: AppPaths) { self.paths = paths }
  private var directory: URL { paths.saves.appendingPathComponent("NFS Most Wanted") }

  package func profileURL(_ name: String) throws(LauncherError) -> URL {
    guard ProfileName.isValid(name) else { throw .operation("Invalid profile name.") }
    let url = directory.appendingPathComponent(name).appendingPathComponent(name)
    guard url.resolvingSymlinksInPath().path.hasPrefix(paths.support.path + "/") else {
      throw .operation("Profile points outside the saves folder.")
    }
    return url
  }

  package func backupURL(profile: String, name: String) throws(LauncherError) -> URL {
    guard ProfileName.isValid(profile), ProfileName.isValid(name), name.hasSuffix(".save") else {
      throw .operation("Invalid backup name.")
    }
    let root = paths.support.appendingPathComponent("Backups")
    let url = root.appendingPathComponent(profile).appendingPathComponent(name)
    guard url.resolvingSymlinksInPath().path.hasPrefix(paths.support.path + "/") else {
      throw .operation("Backup points outside its folder.")
    }
    return url
  }

  package func backups(profile: String) throws(LauncherError) -> [String] {
    guard ProfileName.isValid(profile) else { throw .operation("Invalid profile name.") }
    let root = paths.support.appendingPathComponent("Backups").appendingPathComponent(profile)
    return try children(root, limit: 200).map(\.lastPathComponent).filter {
      ProfileName.isValid($0) && $0.hasSuffix(".save")
    }.sorted().reversed()
  }

  package func profiles() throws(LauncherError) -> [ProfileSummary] {
    var summaries: [ProfileSummary] = []
    for folder in try children(directory, limit: 100).sorted(by: {
      $0.lastPathComponent < $1.lastPathComponent
    }) {
      let name = folder.lastPathComponent
      guard ProfileName.isValid(name) else { continue }
      let url = try profileURL(name)
      guard files.fileExists(atPath: url.path) else { continue }
      let bytes = try BoundedFile.read(url, limit: CareerSave.size)
      let fingerprint = hash(bytes)
      let backups = try backups(profile: name)
      do {
        let save = try CareerSave(bytes)
        summaries.append(
          ProfileSummary(
            id: name, fingerprint: fingerprint, cash: save.cash, cars: try save.cars(),
            backups: backups, issue: nil))
      } catch {
        summaries.append(
          ProfileSummary(
            id: name, fingerprint: fingerprint, cash: nil, cars: [], backups: backups,
            issue: error.localizedDescription))
      }
    }
    let present = Set(summaries.map(\.id))
    for folder in try children(paths.support.appendingPathComponent("Backups"), limit: 100) {
      let name = folder.lastPathComponent
      guard ProfileName.isValid(name), !present.contains(name) else { continue }
      let saved = try backups(profile: name)
      guard !saved.isEmpty else { continue }
      summaries.append(
        ProfileSummary(id: name, fingerprint: "", cash: nil, cars: [], backups: saved, issue: nil))
    }
    return summaries.sorted { $0.id < $1.id }
  }

  package func perform(_ request: SaveRequest) throws(LauncherError) {
    do {
      let profile: String
      let expected: String?
      switch request {
      case .create(let name):
        guard !(try profiles()).contains(where: { $0.id.lowercased() == name.lowercased() }) else {
          throw LauncherError.operation("A profile or backup with that name already exists.")
        }
        guard try children(directory, limit: 100).count < 100 else {
          throw LauncherError.operation("The player folder already contains 100 profiles.")
        }
        profile = name
        expected = nil
      case .replace(let name, _, let hash):
        profile = name
        expected = hash
      case .cheat(let name, let hash, _), .backup(let name, let hash), .remove(let name, let hash):
        profile = name
        expected = hash
      case .restore(let name, _, let hash):
        profile = name
        expected = hash
      }
      let url = try profileURL(profile)
      let old =
        files.fileExists(atPath: url.path) ? try BoundedFile.read(url, limit: CareerSave.size) : nil
      guard old.map(hash) == expected else {
        throw LauncherError.operation("The save changed. Reload it before applying this edit.")
      }
      let updated: Data
      switch request {
      case .create(let name):
        let template = paths.resources.appendingPathComponent("Defaults/FreshCareer.save")
        updated = try CareerSave(BoundedFile.read(template, limit: CareerSave.size)).renamed(name)
          .data
      case .remove:
        guard let old else {
          throw LauncherError.operation("The selected profile no longer exists.")
        }
        try backup(old, profile: profile)
        try FileTransaction(root: paths.support).apply([FileChange(url: url, bytes: nil)])
        return
      case .replace(_, let bytes, _): updated = bytes
      case .cheat(_, _, let action):
        guard let old else { throw LauncherError.operation("The selected save no longer exists.") }
        updated = try CareerSave(old).applying(action).data
      case .backup:
        guard let old else { throw LauncherError.operation("The selected save no longer exists.") }
        try backup(old, profile: profile)
        return
      case .restore(_, let name, _):
        updated = try BoundedFile.read(
          backupURL(profile: profile, name: name), limit: CareerSave.size)
      }
      let save = try CareerSave(updated)
      guard save.alias == profile else {
        throw LauncherError.operation("The save's player name must match the selected profile.")
      }
      _ = try save.cars()
      guard old != updated else { return }
      if let old { try backup(old, profile: profile) }
      try FileTransaction(root: paths.support).apply([FileChange(url: url, bytes: updated)])
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not update the save: \(error.localizedDescription)")
    }
  }

  private func backup(_ bytes: Data, profile: String) throws {
    guard try backups(profile: profile).count < 200 else {
      throw LauncherError.operation(
        "This profile has 200 backups. Move some out of its Backups folder before making more edits."
      )
    }
    let date = Date().formatted(
      .iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
        .timeSeparator(.omitted))
    let url = try backupURL(
      profile: profile, name: date + "-" + UUID().uuidString.prefix(8) + ".save")
    try files.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url, options: .withoutOverwriting)
  }

  private func children(_ url: URL, limit: Int) throws(LauncherError) -> [URL] {
    guard files.fileExists(atPath: url.path) else { return [] }
    do {
      let children = try files.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      guard children.count <= limit else {
        throw LauncherError.operation("Too many entries in \(url.lastPathComponent).")
      }
      return children
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not list \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }

  private func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}
