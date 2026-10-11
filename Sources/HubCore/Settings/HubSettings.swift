import Darwin
import Foundation

/// Where the Game Hub keeps its two movable parts: the data store and the Wine runtime app.
///
/// The settings live on the Mac (`~/Library/Application Support/GameHub/settings.json`), never on
/// the data store, because the data store may be unplugged when the Hub starts. A missing file
/// means ``defaults(home:)``.
package struct HubSettings: Codable, Equatable, Sendable {
  package var schemaVersion: Int
  /// The absolute, normalised path of the data store folder (the one that holds `Hub/hub.json`).
  package var dataStoreRoot: String
  /// The absolute, normalised path of the runtime app bundle (`GameHub Runtime <id>.app`).
  package var runtimeApp: String

  package init(dataStoreRoot: String, runtimeApp: String) {
    self.schemaVersion = HubSettings.currentSchemaVersion
    self.dataStoreRoot = dataStoreRoot
    self.runtimeApp = runtimeApp
  }

  package static let currentSchemaVersion = 1
  /// The largest `settings.json` the Hub reads.
  package static let maxFileBytes = 64 * 1024

  private enum CodingKeys: String, CaseIterable, CodingKey {
    case schemaVersion, dataStoreRoot, runtimeApp
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)), type: "settings.json")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    dataStoreRoot = try container.decode(String.self, forKey: .dataStoreRoot)
    runtimeApp = try container.decode(String.self, forKey: .runtimeApp)
    try validate()
  }

  // MARK: - Defaults and location

  /// The data store of a Mac that has never changed the settings. `Packaging/build_hub_app.py`
  /// reads this line, so keep it a plain string literal.
  package static let defaultDataStoreRoot = "/Volumes/ExT2/GameHub"

  /// The settings of a Mac that has never changed them: the data store on the big drive and the
  /// runtime installed as an app in the user's `Applications` folder. These are the only default
  /// paths in the Hub; everything else is derived from the settings.
  package static func defaults(home: URL) -> HubSettings {
    HubSettings(
      dataStoreRoot: defaultDataStoreRoot,
      runtimeApp: home.appendingPathComponent("Applications/GameHub Runtime hub-0.app").path)
  }

  /// `~/Library/Application Support/GameHub/settings.json` for `home`.
  package static func fileURL(home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support/GameHub/settings.json")
  }

  // MARK: - Validation

  /// - Throws: `.invalid` when the schema version is not 1, or a path is not absolute and
  ///   normalised (no `.`, `..`, empty component, trailing slash or NUL), or the runtime path
  ///   does not name an `.app` bundle.
  package func validate() throws(HubError) {
    guard schemaVersion == HubSettings.currentSchemaVersion else {
      throw .invalid("settings.json: schemaVersion must be 1, got \(schemaVersion).")
    }
    guard DatastorePath.isNormalised(dataStoreRoot), dataStoreRoot != "/" else {
      throw .invalid("settings.json: dataStoreRoot must be an absolute, normalised folder path.")
    }
    guard DatastorePath.isNormalised(runtimeApp), runtimeApp.hasSuffix(".app") else {
      throw .invalid("settings.json: runtimeApp must be an absolute path to an .app bundle.")
    }
  }

  // MARK: - Reading and writing

  /// Reads the settings of `home`; a missing file gives ``defaults(home:)``.
  /// - Throws: `.unsafePath` when the file is a symbolic link or not a regular file, `.invalid`
  ///   when it is too large, not strict JSON, has an unknown key or fails ``validate()``.
  package static func load(home: URL) throws(HubError) -> HubSettings {
    let path = fileURL(home: home).path
    guard let data = try DatastoreIO.readBounded(path, limit: maxFileBytes) else {
      return defaults(home: home)
    }
    do {
      return try JSONDecoder().decode(HubSettings.self, from: data)
    } catch let error as HubError {
      throw error
    } catch {
      throw .invalid("Cannot read settings.json: \(error.localizedDescription)")
    }
  }

  /// Writes the settings to the Mac's settings file: a temporary file in the same folder, flushed
  /// to the platter, then renamed over the old file, so a reader sees the old settings or the new
  /// ones and a crash leaves one of the two. The folder is created when missing.
  /// - Returns: A warning when the new file is in place but the folder could not be flushed
  ///   afterwards (the settings are saved; only their durability across a power cut is in doubt).
  /// - Throws: `.invalid` when the settings fail ``validate()``, `.unsafePath` when the existing
  ///   file is not a regular file, `.io` when writing fails. When it throws, the old file is
  ///   still the settings in force.
  @discardableResult
  package func save(home: URL) throws(HubError) -> String? {
    try validate()
    let destination = HubSettings.fileURL(home: home).path
    let folder = DatastorePath.parent(of: destination)
    do {
      try FileManager.default.createDirectory(
        atPath: folder, withIntermediateDirectories: true)
    } catch {
      throw .io("Cannot create \(folder): \(error.localizedDescription)")
    }
    var existing = stat()
    if lstat(destination, &existing) == 0, (existing.st_mode & S_IFMT) != S_IFREG {
      throw .unsafePath("\(destination) is not a regular file; refusing to replace it.")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(self)
    } catch {
      throw .io("Cannot encode settings.json: \(error.localizedDescription)")
    }

    let temporary = "\(destination).tmp-\(UUID().uuidString)"
    let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw posixFailure("open", temporary) }
    var failure: HubError?
    var offset = 0
    while offset < data.count && failure == nil {
      let written = data.withUnsafeBytes { buffer in
        Darwin.write(fd, buffer.baseAddress.map { $0 + offset }, buffer.count - offset)
      }
      if written < 0 {
        if errno != EINTR { failure = posixFailure("write", temporary) }
      } else {
        offset += written
      }
    }
    if failure == nil {
      do throws(HubError) {
        try DatastoreIO.syncFile(fd, temporary)
      } catch {
        failure = error
      }
    }
    Darwin.close(fd)
    if failure == nil, Darwin.rename(temporary, destination) != 0 {
      failure = posixFailure("rename", "\(temporary) -> \(destination)")
    }
    if let failure {
      _ = Darwin.unlink(temporary)
      throw failure
    }
    do throws(HubError) {
      try DatastoreIO.syncDirectory(folder)
    } catch {
      return "The settings were saved, but the folder could not be flushed: \(text(of: error))"
    }
    return nil
  }

  // MARK: - Changing

  /// The settings as saved, with a warning when saving them could not be made fully durable.
  package struct Saved: Equatable, Sendable {
    package var settings: HubSettings
    package var warning: String?
  }

  /// Applies `change` to the settings saved right now and saves the result, so one change never
  /// writes back a stale snapshot of another. A saved file whose content cannot be read
  /// (`.invalid`) is replaced, starting from ``defaults(home:)``; a symbolic link or an I/O
  /// failure stops the update.
  /// - Throws: whatever `change` throws, or the errors of ``load(home:)`` and ``save(home:)``.
  package static func update(
    home: URL, _ change: (HubSettings) throws(HubError) -> HubSettings
  ) throws(HubError) -> Saved {
    var latest: HubSettings
    do throws(HubError) {
      latest = try load(home: home)
    } catch {
      guard case .invalid = error else { throw error }
      latest = defaults(home: home)
    }
    let changed = try change(latest)
    let warning = try changed.save(home: home)
    return Saved(settings: changed, warning: warning)
  }

  /// These settings with the runtime app at `path`, when the app there is a usable runtime.
  /// - Parameter expectedSHA256: The manifest hash the data store's `hub.json` records; nil
  ///   accepts any runtime.
  /// - Throws: `.invalid` with the state's message unless the app is intact and matches.
  package func selectingRuntimeApp(
    at path: String, expectedSHA256: String?
  ) throws(HubError) -> HubSettings {
    var changed = self
    changed.runtimeApp = path
    try changed.validate()
    let status = RuntimeStatus.check(app: path, expectedSHA256: expectedSHA256)
    guard case .ok = status else { throw .invalid(status.message) }
    return changed
  }

  /// ``update(home:_:)`` with the data store set to `root`.
  package static func updateDataStore(home: URL, to root: String) throws(HubError) -> Saved {
    try update(home: home) { (latest: HubSettings) throws(HubError) in
      try latest.movingDataStore(to: root)
    }
  }

  /// ``update(home:_:)`` with the runtime app set to `path`, which must be a usable runtime.
  package static func updateRuntimeApp(
    home: URL, to path: String, expectedSHA256: String?
  ) throws(HubError) -> Saved {
    try update(home: home) { (latest: HubSettings) throws(HubError) in
      try latest.selectingRuntimeApp(at: path, expectedSHA256: expectedSHA256)
    }
  }

  /// These settings with the data store at `root`.
  package func movingDataStore(to root: String) throws(HubError) -> HubSettings {
    var changed = self
    changed.dataStoreRoot = root
    try changed.validate()
    return changed
  }
}
