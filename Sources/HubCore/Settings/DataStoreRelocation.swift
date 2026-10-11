import Darwin
import Foundation

/// Why a move of the data store was refused. The text is shown to the user as it is.
package enum DataStoreRefusal: Equatable, Sendable {
  /// The chosen folder is the data store the settings already name.
  case sameLocation
  /// The folder to create the data store in does not exist.
  case parentMissing(String)
  /// The place the data store would move to already holds something.
  case targetExists(String)
  case notAFolder(String)
  /// The place is inside the data store being moved.
  case insideCurrentStore
  /// The chosen volume or data store cannot serve: drive missing, not case-sensitive, not
  /// writable, or a `hub.json` that cannot be used.
  case targetUnusable(DataStoreStatus)
  /// The current data store cannot be moved: it is missing, unplugged or unreadable.
  case currentUnusable(DataStoreStatus)
  /// Names beside the data store (`Steam`, ...) are links into it; renaming it would break them.
  case compatibilityLinks([String])
  case insufficientSpace(required: Int64, free: Int64, margin: Int64)

  package var message: String {
    switch self {
    case .sameLocation:
      "That folder is the data store the Hub already uses."
    case .parentMissing(let path):
      "The folder \(path) does not exist, so the data store cannot be created in it."
    case .targetExists(let path):
      "\(path) already exists and is not a Game Hub data store. Choose another folder."
    case .notAFolder(let path):
      "\(path) is not a folder."
    case .insideCurrentStore:
      "The chosen place is inside the current data store."
    case .targetUnusable(let status):
      "This place cannot hold the data store. \(status.message)"
    case .currentUnusable(let status):
      "The current data store cannot be moved. \(status.message) "
        + "You can still point the Hub at another existing data store."
    case .compatibilityLinks(let names):
      "These names beside the data store are links into it and would break if it were renamed: "
        + names.joined(separator: ", ") + ". Point them at the new place first, or copy instead."
    case .insufficientSpace(let required, let free, let margin):
      "The copy needs \(DataStoreRefusal.bytes(required)) plus \(DataStoreRefusal.bytes(margin)) "
        + "of room to spare, but the target has \(DataStoreRefusal.bytes(free)) free."
    }
  }

  private static func bytes(_ value: Int64) -> String {
    value.formatted(.byteCount(style: .binary))
  }
}

/// What moving the data store to a chosen folder would do. Planning writes nothing.
package enum DataStoreRelocationPlan: Equatable, Sendable {
  /// The chosen folder already is a data store: only the settings change.
  case pointAtExisting(root: String)
  /// The new place is on the same drive: one atomic rename of the whole data store.
  case rename(from: String, to: String)
  /// The new place is on another drive: a copy, only after the user confirms. The source stays.
  case copy(from: String, to: String, requiredBytes: Int64, entries: Int, freeBytes: Int64)
  case refused(DataStoreRefusal)
}

/// Progress of a copy.
package struct DataStoreCopyProgress: Equatable, Sendable {
  package var entriesDone: Int
  package var entriesTotal: Int
  package var bytesDone: Int64
  package var bytesTotal: Int64

  /// 0...1, by bytes (by entries when the data store holds no bytes).
  package var fraction: Double {
    if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
    return entriesTotal > 0 ? min(1, Double(entriesDone) / Double(entriesTotal)) : 1
  }
}

/// What a finished relocation changed.
package struct DataStoreRelocationResult: Equatable, Sendable {
  /// The settings now saved: they name the new data store.
  package var settings: HubSettings
  /// A summary for the user, ending with the warning about Windows-side records.
  package var summary: String
}

/// How a relocation ended.
package enum DataStoreRelocationOutcome: Equatable, Sendable {
  case done(DataStoreRelocationResult)
  /// The user cancelled a copy; the staging folder was removed and nothing else changed.
  case cancelled
}

/// Plans and performs moving the data store: pointing the settings at another data store, renaming
/// it on the same drive, or (confirmed) copying it to another drive.
///
/// The Hub never moves data without being told to, never deletes the source of a copy, and
/// renames only with `RENAME_EXCL`, so an existing folder is never replaced.
package struct DataStoreRelocation: Sendable {
  /// Room to leave free on the target of a copy, beyond the data store's size.
  package static let defaultSafetyMargin: Int64 = 2 * 1024 * 1024 * 1024

  /// Windows records inside the data store name the old place; moving it needs them repointed.
  package static let windowsRecordsWarning =
    "Records written by Windows programs (the Steam library list, the Wine drive E:, "
    + "Z:\\Volumes\\...) still name the old location. Repoint them after the move; moving to "
    + "another drive makes that necessary."

  /// Failures a test can inject.
  package struct Faults: Sendable {
    /// Fail the copy after this many entries were copied.
    package var failCopyAfterEntries: Int?
    package init(failCopyAfterEntries: Int? = nil) {
      self.failCopyAfterEntries = failCopyAfterEntries
    }
  }

  package var capabilities: any DataStoreCapabilities
  package var fileSystem: any DatastoreFileSystem
  package var probe: any DatastoreProbe
  package var checkEnvironment: DatastoreCheckEnvironment
  package var home: URL
  package var safetyMargin: Int64
  package var processID: Int32
  package var faults: Faults

  package init(
    home: URL,
    capabilities: any DataStoreCapabilities = LiveDataStoreCapabilities(),
    fileSystem: any DatastoreFileSystem = RealDatastoreFileSystem(),
    probe: any DatastoreProbe = LiveDatastoreProbe(),
    checkEnvironment: DatastoreCheckEnvironment = .live,
    safetyMargin: Int64 = DataStoreRelocation.defaultSafetyMargin,
    processID: Int32 = getpid(),
    faults: Faults = Faults()
  ) {
    self.home = home
    self.capabilities = capabilities
    self.fileSystem = fileSystem
    self.probe = probe
    self.checkEnvironment = checkEnvironment
    self.safetyMargin = safetyMargin
    self.processID = processID
    self.faults = faults
  }

  // MARK: - Planning

  /// What choosing `chosen` would do to the data store at `current`.
  ///
  /// A chosen folder that holds `Hub/hub.json` is a data store to point at. Any other existing
  /// folder receives the data store as a new folder named like the current one; a path that does
  /// not exist yet is used as it is.
  /// - Throws: `.io` when the filesystem cannot be read.
  /// - Complexity: O(1) for pointing and renaming; O(n) in the data store's entries for a copy,
  ///   which is measured.
  package func plan(current: String, chosen: String) throws(HubError) -> DataStoreRelocationPlan {
    // Lexical clean-up only: `standardizedFileURL` would also rewrite /private/var to /var.
    let chosen = DatastorePath.resolve(chosen, in: "/")
    let current = DatastorePath.resolve(current, in: "/")
    let target: String
    switch try fileSystem.statNode(chosen) {
    case nil:
      target = chosen
    case let node? where node.kind == .directory:
      let config = HubPaths(root: URL(fileURLWithPath: chosen, isDirectory: true)).config.path
      if try fileSystem.lstatNode(config) != nil {
        let currentCanonical = try fileSystem.canonicalDirectory(current) ?? current
        if try (fileSystem.canonicalDirectory(chosen) ?? chosen) == currentCanonical {
          return .refused(.sameLocation)
        }
        let report = DataStoreStatus.check(
          root: chosen, capabilities: capabilities, fileSystem: fileSystem)
        return report.status.isUsable
          ? .pointAtExisting(root: chosen) : .refused(.targetUnusable(report.status))
      }
      target = DatastorePath.join(chosen, DatastorePath.name(of: current))
    default:
      return .refused(.notAFolder(chosen))
    }

    // The store being moved must itself be a real folder: a link would be renamed or copied as
    // the link, or lead the copy somewhere else.
    switch try fileSystem.lstatNode(current)?.kind {
    case nil: return .refused(.currentUnusable(.missing))
    case .directory?: break
    default: return .refused(.currentUnusable(.notADirectory))
    }
    let currentCanonical = try fileSystem.canonicalDirectory(current) ?? current

    if target == current { return .refused(.sameLocation) }
    let parent = DatastorePath.parent(of: target)
    if let volume = HubPaths.volumeRoot(of: target), !capabilities.isMounted(volumeRoot: volume) {
      return .refused(.targetUnusable(.driveNotConnected(volume: volume)))
    }
    guard try fileSystem.statNode(parent)?.kind == .directory else {
      return .refused(.parentMissing(parent))
    }
    guard try fileSystem.lstatNode(target) == nil else { return .refused(.targetExists(target)) }
    // Every existing ancestor of the target is looked at with lstat: one that is a link into the
    // current store would put the new store inside the old one, however the path is written.
    let targetCanonical = DatastorePath.join(
      try fileSystem.canonicalDirectory(parent) ?? parent, DatastorePath.name(of: target))
    if DatastorePath.isWithin(targetCanonical, currentCanonical) {
      return .refused(.insideCurrentStore)
    }
    var ancestor = parent
    while ancestor != "/" {
      if try fileSystem.lstatNode(ancestor)?.kind == .symlink,
        let resolved = try fileSystem.canonicalDirectory(ancestor),
        DatastorePath.isWithin(resolved, currentCanonical)
      {
        return .refused(.insideCurrentStore)
      }
      ancestor = DatastorePath.parent(of: ancestor)
    }

    let currentReport = DataStoreStatus.check(
      root: current, capabilities: capabilities, fileSystem: fileSystem)
    switch currentReport.status {
    case .ok, .notInitialised: break
    default: return .refused(.currentUnusable(currentReport.status))
    }
    guard capabilities.isCaseSensitive(at: parent) else {
      return .refused(.targetUnusable(.notCaseSensitive))
    }
    guard capabilities.isWritable(at: parent) else {
      return .refused(.targetUnusable(.notWritable))
    }

    let sameDrive = capabilities.device(of: parent) == capabilities.device(of: current)
    if sameDrive {
      let links = try compatibilityLinks(into: current)
      if !links.isEmpty { return .refused(.compatibilityLinks(links)) }
      return .rename(from: current, to: target)
    }

    guard let measured = try fileSystem.measure(current) else {
      return .refused(.currentUnusable(.missing))
    }
    let free = capabilities.capacity(at: parent)?.free ?? 0
    guard free >= measured.bytes + safetyMargin else {
      return .refused(
        .insufficientSpace(required: measured.bytes, free: free, margin: safetyMargin))
    }
    return .copy(
      from: current, to: target, requiredBytes: measured.bytes, entries: measured.entries,
      freeBytes: free)
  }

  /// The symlinks directly beside `root` (in the volume's top folder) that point into `root`.
  private func compatibilityLinks(into root: String) throws(HubError) -> [String] {
    let folder = HubPaths.volumeRoot(of: root) ?? DatastorePath.parent(of: root)
    var names: [String] = []
    for name in try fileSystem.childNames(of: folder) ?? [] {
      let path = DatastorePath.join(folder, name)
      guard let target = try fileSystem.linkTarget(path) else { continue }
      if DatastorePath.isWithin(DatastorePath.resolve(target, in: folder), root) {
        names.append(name)
      }
    }
    return names.sorted()
  }

  // MARK: - Performing

  /// Carries out `plan`, saves the settings that name the new place, and reports how it ended.
  ///
  /// Blocks until done: call it off the main actor. A copy reports progress and stops between
  /// entries (and inside a large file) when `isCancelled` answers true.
  /// - Parameters:
  ///   - confirmedCopy: Whether the user confirmed a copy. A copy without it is refused.
  ///   - progress: Called after each entry of a copy.
  /// - Throws: `.blocked` when something uses the data store, a refused plan, or a copy that was
  ///   not confirmed; `.io` when a step fails (a failed copy removes its staging folder).
  package func perform(
    _ plan: DataStoreRelocationPlan,
    confirmedCopy: Bool = false,
    progress: @escaping @Sendable (DataStoreCopyProgress) -> Void = { _ in },
    isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
  ) throws(HubError) -> DataStoreRelocationOutcome {
    switch plan {
    case .refused(let refusal):
      throw .blocked(refusal.message)

    case .pointAtExisting(let root):
      let report = DataStoreStatus.check(
        root: root, capabilities: capabilities, fileSystem: fileSystem)
      guard report.status.isUsable else { throw .blocked(report.status.message) }
      let saved = try HubSettings.updateDataStore(home: home, to: root)
      return .done(
        DataStoreRelocationResult(
          settings: saved.settings,
          summary: "The Hub now uses the data store at \(root). Nothing was moved."
            + DataStoreRelocation.warningSuffix(saved.warning)))

    case .rename(let from, let to):
      return .done(try rename(from: from, to: to))

    case .copy(let from, let to, let requiredBytes, let entries, _):
      guard confirmedCopy else {
        throw .blocked("A copy to another drive needs the user's confirmation.")
      }
      return try copy(
        from: from, to: to, requiredBytes: requiredBytes, entries: entries,
        progress: progress, isCancelled: isCancelled)
    }
  }

  // MARK: Rename

  private func rename(from: String, to: String) throws(HubError) -> DataStoreRelocationResult {
    let parent = DatastorePath.parent(of: to)
    try requireRealDirectory(from)
    guard capabilities.device(of: parent) == capabilities.device(of: from) else {
      throw .blocked("\(to) is on another drive; a rename cannot move the data store there.")
    }
    guard try fileSystem.lstatNode(to) == nil else {
      throw .blocked("\(to) already exists; refusing to replace it.")
    }
    try requireIdle(root: from)
    guard let before = try fileSystem.measure(from) else {
      throw .invalid("Cannot move \(from): it does not exist.")
    }
    guard Darwin.renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 else {
      throw posixFailure("renamex_np(RENAME_EXCL)", "\(from) -> \(to)")
    }
    // Up to and including the settings write, a failure puts the store back. Once the settings
    // file names the new place (its own rename happened), the store stays where it is.
    let saved: HubSettings.Saved
    do throws(HubError) {
      guard let after = try fileSystem.measure(to), after.device == before.device,
        after.inode == before.inode, after.sameContent(as: before)
      else {
        throw .io("The data store at \(to) is not what was at \(from) (the measurement differs).")
      }
      try DatastoreIO.syncDirectory(DatastorePath.parent(of: from))
      try DatastoreIO.syncDirectory(parent)
      saved = try HubSettings.updateDataStore(home: home, to: to)
    } catch {
      throw moveBack(from: from, to: to, because: error)
    }
    return DataStoreRelocationResult(
      settings: saved.settings,
      summary: "Renamed \(from) to \(to) in one step; \(before.entries) entries, "
        + "\(before.bytes.formatted(.byteCount(style: .binary))) were not copied. "
        + DataStoreRelocation.windowsRecordsWarning
        + DataStoreRelocation.warningSuffix(saved.warning))
  }

  /// Puts a renamed data store back; the error says whether that worked.
  private func moveBack(from: String, to: String, because error: HubError) -> HubError {
    if Darwin.renamex_np(to, from, UInt32(RENAME_EXCL)) == 0 {
      return .io("\(text(of: error)) The data store was moved back to \(from).")
    }
    return .io(
      "\(text(of: error)) The data store could not be moved back and is now at \(to); "
        + "set that folder in the settings.")
  }

  // MARK: Copy

  private func copy(
    from: String, to: String, requiredBytes: Int64, entries: Int,
    progress: @escaping @Sendable (DataStoreCopyProgress) -> Void,
    isCancelled: @escaping @Sendable () -> Bool
  ) throws(HubError) -> DataStoreRelocationOutcome {
    let parent = DatastorePath.parent(of: to)
    try requireRealDirectory(from)
    guard try fileSystem.lstatNode(to) == nil else {
      throw .blocked("\(to) already exists; refusing to replace it.")
    }
    let free = capabilities.capacity(at: parent)?.free ?? 0
    guard free >= requiredBytes + safetyMargin else {
      throw .blocked(
        DataStoreRefusal.insufficientSpace(
          required: requiredBytes, free: free, margin: safetyMargin
        ).message)
    }
    try requireIdle(root: from)

    let staging = "\(to).staging-\(processID)"
    guard Darwin.mkdir(staging, 0o700) == 0 else { throw posixFailure("mkdir", staging) }
    do throws(HubError) {
      let walker = TreeCopier(
        fileSystem: fileSystem, entriesTotal: entries, bytesTotal: requiredBytes,
        failAfterEntries: faults.failCopyAfterEntries, progress: progress,
        isCancelled: isCancelled)
      let finished = try walker.copy(from: from, into: staging)
      guard finished else {
        try removeStaging(staging, for: to)
        return .cancelled
      }
      guard let source = try fileSystem.measure(from), let copied = try fileSystem.measure(staging),
        source.sameContent(as: copied)
      else {
        throw .io(
          "The copy does not match the data store (entries, bytes or links differ); it was discarded."
        )
      }
      try walker.applyDirectoryMetadata()
      try DatastoreIO.syncDirectory(staging)
      guard Darwin.renamex_np(staging, to, UInt32(RENAME_EXCL)) == 0 else {
        throw posixFailure("renamex_np(RENAME_EXCL)", "\(staging) -> \(to)")
      }
      do throws(HubError) {
        try DatastoreIO.syncDirectory(parent)
      } catch {
        throw .io(
          "The copy already exists at \(to), but its folder could not be flushed: "
            + "\(text(of: error)) The settings were not changed and the original at \(from) "
            + "is untouched. Choose \(to) in the settings to use the copy.")
      }
      let saved: HubSettings.Saved
      do throws(HubError) {
        saved = try HubSettings.updateDataStore(home: home, to: to)
      } catch {
        throw .io(
          "The copy is complete at \(to), but the settings could not be saved: \(text(of: error)) "
            + "Choose \(to) in the settings to use it. The original at \(from) is untouched.")
      }
      return .done(
        DataStoreRelocationResult(
          settings: saved.settings,
          summary: "Copied \(copied.entries) entries, "
            + "\(copied.bytes.formatted(.byteCount(style: .binary))) to \(to). "
            + "The original at \(from) was kept; delete it yourself when you are sure. "
            + DataStoreRelocation.windowsRecordsWarning
            + DataStoreRelocation.warningSuffix(saved.warning)))
    } catch {
      do throws(HubError) {
        try removeStaging(staging, for: to)
      } catch let cleanup {
        throw .io("\(text(of: error)) Also: \(text(of: cleanup))")
      }
      throw error
    }
  }

  /// Removes the staging folder this run made, and nothing else.
  private func removeStaging(_ staging: String, for target: String) throws(HubError) {
    guard staging == "\(target).staging-\(processID)", try fileSystem.lstatNode(staging) != nil
    else { return }
    do {
      try FileManager.default.removeItem(atPath: staging)
    } catch {
      throw .io("Could not remove the staging folder \(staging); remove it by hand.")
    }
  }

  // MARK: Checks

  /// Fails unless `path` is a real folder, not a link to one.
  private func requireRealDirectory(_ path: String) throws(HubError) {
    guard try fileSystem.lstatNode(path)?.kind == .directory else {
      throw .blocked("\(path) is not a real folder (missing, or a link); refusing to move it.")
    }
  }

  private static func warningSuffix(_ warning: String?) -> String {
    warning.map { " " + $0 } ?? ""
  }

  /// Fails with `.blocked` unless nothing has a file open in the data store and its shared prefix
  /// is not in use.
  private func requireIdle(root: String) throws(HubError) {
    let snapshot = DatastoreProbeSnapshot(probe: probe, processes: true, files: true)
    let evaluator = DatastoreCheckEvaluator(
      fileSystem: fileSystem, snapshot: snapshot, environment: checkEnvironment)
    var outcomes = [evaluator.evaluate(.noOpenFiles(path: root))]
    let prefix: String
    do throws(HubError) {
      prefix = try HubPaths(root: URL(fileURLWithPath: root, isDirectory: true))
        .configuredPrefix().path
    } catch {
      throw .blocked(
        "Hub/hub.json cannot be used, so the shared prefix cannot be checked: \(text(of: error))")
    }
    if try fileSystem.lstatNode(prefix) != nil {
      outcomes.append(evaluator.evaluate(.prefixNotInUse(path: prefix, aliases: [])))
    }
    let failed = outcomes.filter { $0.status == .fail }
    guard failed.isEmpty else {
      throw .blocked(
        "The data store is in use. Quit the games and the EA, Steam and Epic apps first.\n"
          + failed.map { "\($0.name): \($0.detail)" }.joined(separator: "\n"))
    }
  }
}

// MARK: - Tree copy

/// Copies a tree without following symlinks: directories are made first and given their
/// permissions and times last; files and symlinks go through `copyfile(3)`.
private final class TreeCopier {
  private let fileSystem: any DatastoreFileSystem
  private let failAfterEntries: Int?
  private let progress: @Sendable (DataStoreCopyProgress) -> Void
  private let isCancelled: @Sendable () -> Bool
  private var state: DataStoreCopyProgress
  /// Directories made, parents before children: their metadata is applied in reverse.
  private var directories: [(source: String, copy: String)] = []

  init(
    fileSystem: any DatastoreFileSystem, entriesTotal: Int, bytesTotal: Int64,
    failAfterEntries: Int?, progress: @escaping @Sendable (DataStoreCopyProgress) -> Void,
    isCancelled: @escaping @Sendable () -> Bool
  ) {
    self.fileSystem = fileSystem
    self.failAfterEntries = failAfterEntries
    self.progress = progress
    self.isCancelled = isCancelled
    self.state = DataStoreCopyProgress(
      entriesDone: 0, entriesTotal: entriesTotal, bytesDone: 0, bytesTotal: bytesTotal)
  }

  /// Copies the contents of `source` into the existing, empty folder `copy`.
  /// - Returns: false when cancelled.
  /// - Complexity: O(n) in the entries; iterative with an explicit stack.
  func copy(from source: String, into copy: String) throws(HubError) -> Bool {
    directories.append((source, copy))
    var pending: [(source: String, copy: String)] = [(source, copy)]
    while let (folder, target) = pending.popLast() {
      for name in try fileSystem.childNames(of: folder) ?? [] {
        if isCancelled() { return false }
        let from = DatastorePath.join(folder, name)
        let to = DatastorePath.join(target, name)
        var info = stat()
        guard Darwin.lstat(from, &info) == 0 else {
          if errno == ENOENT { continue }
          throw posixFailure("lstat", from)
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
          guard Darwin.mkdir(to, mode_t(info.st_mode & 0o777) | 0o700) == 0 else {
            throw posixFailure("mkdir", to)
          }
          directories.append((from, to))
          pending.append((from, to))
        case S_IFREG, S_IFLNK:
          guard try copyEntry(from, to) else { return false }
          state.bytesDone += (info.st_mode & S_IFMT) == S_IFREG ? Int64(info.st_size) : 0
        default:
          throw .unsafePath(
            "\(from) is a special file (socket, pipe or device); it cannot be copied.")
        }
        state.entriesDone += 1
        if let failAfterEntries, state.entriesDone >= failAfterEntries {
          throw .io("Injected copy failure after \(state.entriesDone) entries.")
        }
        progress(state)
      }
    }
    return true
  }

  /// Gives every copied directory the permissions, ownership data and times of its source,
  /// children before parents so a read-only folder is sealed last.
  func applyDirectoryMetadata() throws(HubError) {
    for (source, copy) in directories.reversed() {
      guard
        Darwin.copyfile(source, copy, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
          == 0
      else {
        throw posixFailure("copyfile", copy)
      }
      var info = stat()
      guard Darwin.lstat(source, &info) == 0 else { throw posixFailure("lstat", source) }
      try restoreTimes(of: copy, from: info)
    }
  }

  /// Copies a file or symlink with its attributes, clone where the volume allows, and stops
  /// inside a large file when cancelled.
  private func copyEntry(_ from: String, _ to: String) throws(HubError) -> Bool {
    guard let copyState = copyfile_state_alloc() else { throw .io("Out of memory for copyfile.") }
    defer { copyfile_state_free(copyState) }
    let watcher = CancellationWatcher(isCancelled: isCancelled)
    let callback: copyfile_callback_t = { _, _, _, _, _, context in
      guard let context else { return COPYFILE_CONTINUE }
      let watcher = Unmanaged<CancellationWatcher>.fromOpaque(context).takeUnretainedValue()
      if watcher.isCancelled() {
        watcher.wasCancelled = true
        return COPYFILE_QUIT
      }
      return COPYFILE_CONTINUE
    }
    copyfile_state_set(
      copyState, UInt32(COPYFILE_STATE_STATUS_CB),
      unsafeBitCast(callback, to: UnsafeRawPointer.self)
    )
    let context = Unmanaged.passUnretained(watcher).toOpaque()
    copyfile_state_set(copyState, UInt32(COPYFILE_STATE_STATUS_CTX), context)
    let flags = copyfile_flags_t(
      COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_CLONE)
    let result = withExtendedLifetime(watcher) { Darwin.copyfile(from, to, copyState, flags) }
    if watcher.wasCancelled {
      _ = Darwin.unlink(to)
      return false
    }
    guard result == 0 else { throw posixFailure("copyfile", "\(from) -> \(to)") }
    var info = stat()
    guard Darwin.lstat(from, &info) == 0 else { throw posixFailure("lstat", from) }
    try restoreTimes(of: to, from: info)
    return true
  }

  private func restoreTimes(of path: String, from info: stat) throws(HubError) {
    let times = [info.st_atimespec, info.st_mtimespec]
    guard utimensat(AT_FDCWD, path, times, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw posixFailure("utimensat", path)
    }
  }
}

/// Carries the cancellation question into `copyfile`'s C callback.
private final class CancellationWatcher {
  let isCancelled: @Sendable () -> Bool
  var wasCancelled = false

  init(isCancelled: @escaping @Sendable () -> Bool) { self.isCancelled = isCancelled }
}
