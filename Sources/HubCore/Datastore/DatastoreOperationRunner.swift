import Darwin
import Foundation

/// An operation that changed the disk, with what its undo needs to know.
package struct DatastoreAppliedOp: Equatable, Sendable {
  /// The 1-based position in the step.
  package var index: Int
  package var op: DatastoreOp
  /// Hashes and locations recorded for the undo, as plain strings.
  package var detail: [String: String]
  package var before: DatastoreMeasurement?
  package var after: DatastoreMeasurement?
}

/// A failed operation. `applied` is set when the disk had already changed, so the caller undoes it.
struct DatastoreOpFailure: Error {
  var error: HubError
  var applied: DatastoreAppliedOp?
}

/// Performs and undoes a plan's operations on the real filesystem. It assumes the caller already
/// evaluated the preconditions; it still re-reads what it is about to change, immediately before
/// changing it.
struct DatastoreOperationRunner: Sendable {
  let plan: DatastorePlan
  let processID: Int32
  let faults: DatastoreFaults
  private let fs = RealDatastoreFileSystem()

  init(plan: DatastorePlan, processID: Int32, faults: DatastoreFaults = DatastoreFaults()) {
    self.plan = plan
    self.processID = processID
    self.faults = faults
  }

  // MARK: - Apply

  /// What the operation must record before it runs: for a rename, the measured source (a read-only
  /// walk, so it may take long); nil for the other operations.
  /// - Throws: `.invalid` when a rename source does not exist.
  func begin(_ op: DatastoreOp) throws(HubError) -> DatastoreMeasurement? {
    guard case .rename(let from, _) = op else { return nil }
    guard let measured = try fs.measure(from) else {
      throw .invalid("Cannot move \(from): it does not exist.")
    }
    return measured
  }

  /// Performs `op`, then flushes the directories it changed. A rename returns as soon as that is
  /// done, without measuring the destination: the caller records the move, then calls
  /// ``measureAfter(_:)``.
  ///
  /// The change and its durability are separate steps. A failure of the change itself reports
  /// `applied: nil`; a failure to flush a directory after the change happened reports the
  /// operation as `applied`, so the caller journals it and undoes it with the rest of the step.
  func apply(
    _ op: DatastoreOp, index: Int, before: DatastoreMeasurement?
  ) throws(DatastoreOpFailure) -> DatastoreAppliedOp {
    let done: DatastoreAppliedOp
    do throws(HubError) {
      done = try applyOperation(op, index: index, before: before)
    } catch {
      throw DatastoreOpFailure(error: error, applied: nil)
    }
    do throws(HubError) {
      try persist(done, afterUndo: false)
    } catch {
      throw DatastoreOpFailure(error: error, applied: done)
    }
    return done
  }

  /// Flushes the directories that `applied` changed (or, after an undo, that its reversal
  /// changed), so the change survives a power cut.
  /// - Throws: `.io` when a directory cannot be flushed.
  func persist(_ applied: DatastoreAppliedOp, afterUndo: Bool) throws(HubError) {
    let injected = afterUndo ? faults.failSyncAfterUndo : faults.failSyncAfterOperation
    if injected == applied.index {
      throw .io("Injected directory sync failure after operation #\(applied.index).")
    }
    switch applied.op {
    case .mkdir(let path, _), .symlink(let path, _), .replaceSymlink(let path, _, _),
      .rewriteText(let path, _, _, _):
      try DatastoreIO.syncDirectory(DatastorePath.parent(of: path))
    case .rename(let from, let to):
      try DatastoreIO.syncDirectory(DatastorePath.parent(of: from))
      try DatastoreIO.syncDirectory(DatastorePath.parent(of: to))
    case .writeHubConfig(let spec):
      try DatastoreIO.syncDirectory(DatastorePath.parent(of: spec.path))
    case .backup:
      if !afterUndo, let copy = applied.detail["backupFile"] {
        try DatastoreIO.syncDirectory(DatastorePath.parent(of: copy))
      }
    }
  }

  /// Measures the destination of an applied rename and compares it with the source measured
  /// before: same device and inode, same entries, bytes and symlinks.
  /// - Throws: `.io` when the destination is missing or differs.
  func measureAfter(_ applied: DatastoreAppliedOp) throws(HubError) -> DatastoreMeasurement {
    guard case .rename(let from, let to) = applied.op, let before = applied.before else {
      throw .invalid("Only an applied rename with a recorded source is measured.")
    }
    guard let after = try fs.measure(to) else {
      throw .io("\(to) is missing right after the rename.")
    }
    guard after.device == before.device, after.inode == before.inode else {
      throw .io("\(to) is not the same directory entry as \(from) was (dev/ino changed).")
    }
    guard after.sameContent(as: before) else {
      throw .io(
        "Measurement differs after the rename: before \(before.entries) entries, "
          + "\(before.bytes) bytes, \(before.symlinks) symlinks; after \(after.entries), "
          + "\(after.bytes), \(after.symlinks).")
    }
    return after
  }

  private func applyOperation(
    _ op: DatastoreOp, index: Int, before: DatastoreMeasurement?
  ) throws(HubError) -> DatastoreAppliedOp {
    var applied = DatastoreAppliedOp(index: index, op: op, detail: [:], before: before, after: nil)
    switch op {
    case .mkdir(let path, let mode):
      guard Darwin.mkdir(path, mode_t(mode)) == 0 else { throw posixFailure("mkdir", path) }
      guard Darwin.chmod(path, mode_t(mode)) == 0 else {
        let failure = posixFailure("chmod", path)
        _ = Darwin.rmdir(path)
        throw failure
      }

    case .rename(let from, let to):
      let caseOnly = DatastoreStepPlanner.isCaseOnlyRename(
        from: from, to: to, fromInfo: try fs.lstatNode(from), toInfo: try fs.lstatNode(to))
      if caseOnly {
        // A case-insensitive volume: both names reach the same object, and rename(2) is the only
        // call that renames it. The destination is the source itself, so nothing is overwritten.
        guard Darwin.rename(from, to) == 0 else { throw posixFailure("rename", "\(from) -> \(to)") }
      } else {
        try renameExclusive(from, to)
      }

    case .symlink(let path, let target):
      guard Darwin.symlink(target, path) == 0 else { throw posixFailure("symlink", path) }

    case .replaceSymlink(let path, let target, let expectedTarget):
      guard try fs.linkTarget(path) == expectedTarget else {
        throw .blocked("\(path) no longer points to \(expectedTarget).")
      }
      try replaceSymlinkAtomically(path, target: target)

    case .backup(let path):
      applied.detail = try backUp(path)

    case .rewriteText(let path, let find, let replace, let expectedCount):
      applied.detail = try rewrite(
        path, find: find, replace: replace, expectedCount: expectedCount)

    case .writeHubConfig(let spec):
      applied.detail = try writeConfig(spec)
    }
    return applied
  }

  // MARK: - Pieces

  private func renameExclusive(_ from: String, _ to: String) throws(HubError) {
    guard Darwin.renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 else {
      throw posixFailure("renamex_np(RENAME_EXCL)", "\(from) -> \(to)")
    }
  }

  /// Fails when an earlier crash left a `<name>.datastore-tmp-*` sibling of `path`.
  private func requireNoLeftovers(for path: String) throws(HubError) {
    let leftovers = try fs.leftoverTemporaries(for: path)
    guard leftovers.isEmpty else {
      throw .blocked(
        "Leftover temporary file(s) from an earlier run: \(leftovers.joined(separator: ", ")); "
          + "remove them by hand.")
    }
  }

  private func replaceSymlinkAtomically(_ path: String, target: String) throws(HubError) {
    try requireNoLeftovers(for: path)
    let temporary = DatastoreStepPlanner.temporaryPath(for: path, processID: processID)
    guard Darwin.symlink(target, temporary) == 0 else { throw posixFailure("symlink", temporary) }
    guard Darwin.rename(temporary, path) == 0 else {
      let failure = posixFailure("rename", "\(temporary) -> \(path)")
      _ = Darwin.unlink(temporary)
      throw failure
    }
  }

  /// Writes `data` beside `path`, flushes it to the platter, and renames it onto `path`, so a
  /// reader sees the old file or the new one, never half of either. With `exclusive`, an existing
  /// `path` is never replaced (`RENAME_EXCL`).
  private func writeAtomically(
    _ data: Data, to path: String, mode: UInt16, exclusive: Bool = false
  ) throws(HubError) {
    try requireNoLeftovers(for: path)
    let temporary = DatastoreStepPlanner.temporaryPath(for: path, processID: processID)
    let fd = Darwin.open(
      temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
    guard fd >= 0 else { throw posixFailure("open", temporary) }
    var failure: HubError?
    var offset = 0
    while offset < data.count && failure == nil {
      let written = data.withUnsafeBytes { buffer in
        Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
      }
      if written < 0 {
        if errno != EINTR { failure = posixFailure("write", temporary) }
      } else {
        offset += written
      }
    }
    if failure == nil, fchmod(fd, mode_t(mode)) != 0 { failure = posixFailure("fchmod", temporary) }
    if failure == nil {
      do throws(HubError) {
        try DatastoreIO.syncFile(fd, temporary)
      } catch {
        failure = error
      }
    }
    Darwin.close(fd)
    if failure == nil {
      if exclusive {
        if Darwin.renamex_np(temporary, path, UInt32(RENAME_EXCL)) != 0 {
          failure = posixFailure("renamex_np(RENAME_EXCL)", "\(temporary) -> \(path)")
        }
      } else if Darwin.rename(temporary, path) != 0 {
        failure = posixFailure("rename", "\(temporary) -> \(path)")
      }
    }
    if let failure {
      _ = Darwin.unlink(temporary)
      throw failure
    }
  }

  /// Creates `directory` and any missing directories between `plan.backupDir` and it.
  private func ensureDirectories(_ directory: String) throws(HubError) {
    guard DatastorePath.isWithin(directory, plan.backupDir) else {
      throw .unsafePath("\(directory) is outside the backup directory.")
    }
    var current = plan.backupDir
    let relative = directory.dropFirst(plan.backupDir.count)
    for component in relative.split(separator: "/") {
      current = DatastorePath.join(current, String(component))
      if let info = try fs.lstatNode(current) {
        guard info.kind == .directory else {
          throw .unsafePath("\(current) exists and is not a directory.")
        }
      } else {
        guard Darwin.mkdir(current, 0o755) == 0 else { throw posixFailure("mkdir", current) }
        guard Darwin.chmod(current, 0o755) == 0 else { throw posixFailure("chmod", current) }
        try DatastoreIO.syncDirectory(DatastorePath.parent(of: current))
      }
    }
  }

  private func appendLine(_ line: String, to path: String) throws(HubError) {
    let existing = try DatastoreIO.readBounded(path, limit: DatastoreJournal.maxFileBytes)
    let lines = existing.map { String(decoding: $0, as: UTF8.self).split(separator: "\n") } ?? []
    if lines.contains(where: { $0 == line }) { return }
    var bytes = Data()
    if let existing, let last = existing.last, last != UInt8(ascii: "\n") {
      bytes.append(UInt8(ascii: "\n"))
    }
    bytes.append(Data((line + "\n").utf8))
    try DatastoreIO.append(bytes, to: path)
  }

  private func backUp(_ path: String) throws(HubError) -> [String: String] {
    guard let info = try fs.lstatNode(path) else {
      throw .invalid("Cannot back up \(path): it does not exist.")
    }
    switch info.kind {
    case .symlink:
      guard let target = try fs.linkTarget(path) else {
        throw .io("Cannot read the symlink \(path).")
      }
      let table = plan.backupDir + "/symlinks.tsv"
      if let existing = try DatastoreIO.readBounded(table, limit: DatastoreJournal.maxFileBytes) {
        let conflict = String(decoding: existing, as: UTF8.self).split(separator: "\n").first {
          $0.hasPrefix(path + "\t") && $0 != "\(path)\t\(target)"
        }
        if let conflict {
          throw .blocked("A different symlink record already exists: \(conflict)")
        }
      }
      try appendLine("\(path)\t\(target)", to: table)
      return ["kind": "symlink", "target": target]

    case .file:
      guard let data = try DatastoreIO.readBounded(path, limit: DatastoreIO.contentLimit) else {
        throw .invalid("Cannot back up \(path): it does not exist.")
      }
      let sha = DatastoreIO.sha256Hex(data)
      let copy = DatastoreStepPlanner.backupCopyPath(backupDir: plan.backupDir, of: path)
      if let existing = try DatastoreIO.sha256Hex(fileAt: copy) {
        guard existing == sha else {
          throw .blocked("A different backup of \(path) already exists at \(copy).")
        }
      } else {
        try ensureDirectories(DatastorePath.parent(of: copy))
        try writeAtomically(data, to: copy, mode: info.mode)
      }
      try appendLine("\(sha)  \(path)", to: plan.backupDir + "/SHA256SUMS")
      return ["kind": "file", "sha256": sha, "backupFile": copy]

    case .directory, .other:
      throw .invalid("Cannot back up \(path): it is a \(info.kind.rawValue).")
    }
  }

  private func rewrite(
    _ path: String, find: String, replace: String, expectedCount: Int
  ) throws(HubError) -> [String: String] {
    guard let info = try fs.lstatNode(path), info.kind == .file,
      let data = try DatastoreIO.readBounded(path, limit: DatastoreIO.contentLimit)
    else {
      throw .invalid("Cannot rewrite \(path): it is not a regular file.")
    }
    let needle = Data(find.utf8)
    let found = DatastoreIO.occurrences(of: needle, in: data)
    guard found == expectedCount else {
      throw .invalid("\(path) holds \(found) occurrence(s) of the text, expected \(expectedCount).")
    }
    let copy = DatastoreStepPlanner.backupCopyPath(backupDir: plan.backupDir, of: path)
    guard let backupSHA = try DatastoreIO.sha256Hex(fileAt: copy) else {
      throw .blocked("There is no backup of \(path) at \(copy); refusing to rewrite it.")
    }
    let rewritten = DatastoreIO.replacing(needle, with: Data(replace.utf8), in: data)
    try writeAtomically(rewritten, to: path, mode: info.mode)
    return [
      "shaBefore": DatastoreIO.sha256Hex(data),
      "shaAfter": DatastoreIO.sha256Hex(rewritten),
      "backupFile": copy,
      "backupSHA": backupSHA,
    ]
  }

  private func writeConfig(_ spec: DatastoreHubConfigSpec) throws(HubError) -> [String: String] {
    guard
      let manifest = try DatastoreIO.readBounded(
        spec.runtimeManifest, limit: DatastoreIO.contentLimit)
    else {
      throw .invalid("The runtime manifest \(spec.runtimeManifest) does not exist.")
    }
    let actual = DatastoreIO.sha256Hex(manifest)
    guard actual == spec.runtimeManifestSHA256 else {
      throw .blocked(
        "The runtime manifest hash is \(actual), the plan expects \(spec.runtimeManifestSHA256).")
    }
    guard try fs.lstatNode(spec.path) == nil else {
      throw .blocked("\(spec.path) already exists; refusing to overwrite it.")
    }
    let encoded = try encode(spec.config)
    try writeAtomically(encoded, to: spec.path, mode: 0o644, exclusive: true)
    guard let written = try DatastoreIO.sha256Hex(fileAt: spec.path) else {
      throw .io("\(spec.path) is missing right after it was written.")
    }
    return ["shaWritten": written]
  }

  /// The bytes `HubConfig.write` produces: validated, pretty-printed with sorted keys.
  private func encode(_ config: HubConfig) throws(HubError) -> Data {
    try config.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      return try encoder.encode(config)
    } catch {
      throw .io("Cannot encode hub.json: \(error)")
    }
  }

  // MARK: - Undo

  /// Reverses `applied`, then checks that the disk is back as it was. Each reversal first checks
  /// that the thing it is about to change is still what the operation left, and refuses if not.
  /// - Returns: nil, or a warning when the reversal succeeded but a directory could not be
  ///   flushed afterwards (the disk is restored; only its durability is in doubt).
  /// - Throws: `.blocked` or `.io` when the reversal itself fails.
  func undo(_ applied: DatastoreAppliedOp) throws(HubError) -> String? {
    switch applied.op {
    case .mkdir(let path, _):
      guard try fs.lstatNode(path)?.kind == .directory else {
        throw .blocked("\(path) is no longer a directory.")
      }
      if path == plan.backupDir { try removeOwnJournalIfAlone() }
      guard Darwin.rmdir(path) == 0 else {
        if errno == ENOTEMPTY { throw .blocked("\(path) is not empty; cannot remove it.") }
        throw posixFailure("rmdir", path)
      }
      guard try fs.lstatNode(path) == nil else { throw .io("\(path) is still there after rmdir.") }

    case .rename(let from, let to):
      guard let identity = applied.after ?? applied.before else {
        throw .invalid("The rename of \(from) has no recorded identity to undo against.")
      }
      guard let current = try fs.lstatNode(to),
        current.device == identity.device, current.inode == identity.inode
      else {
        throw .blocked("\(to) is no longer the directory entry the rename produced.")
      }
      let existing = try fs.lstatNode(from)
      // On a case-insensitive volume the old spelling reaches the renamed entry itself.
      let caseOnly = DatastoreStepPlanner.isCaseOnlyRename(
        from: to, to: from, fromInfo: current, toInfo: existing)
      guard existing == nil || caseOnly else {
        throw .blocked("\(from) exists again (\(existing?.kind.rawValue ?? "")); cannot move back.")
      }
      guard try fs.statNode(DatastorePath.parent(of: from))?.kind == .directory else {
        throw .blocked("The directory of \(from) is missing.")
      }
      if caseOnly {
        guard Darwin.rename(to, from) == 0 else { throw posixFailure("rename", "\(to) -> \(from)") }
      } else {
        try renameExclusive(to, from)
      }
      guard let restored = try fs.lstatNode(from), restored.inode == identity.inode,
        restored.device == identity.device
      else {
        throw .io("\(from) is not the original entry after moving back.")
      }

    case .symlink(let path, let target):
      guard try fs.linkTarget(path) == target else {
        throw .blocked("\(path) is no longer a symlink to \(target).")
      }
      guard Darwin.unlink(path) == 0 else { throw posixFailure("unlink", path) }
      guard try fs.lstatNode(path) == nil else { throw .io("\(path) is still there after unlink.") }

    case .replaceSymlink(let path, let target, let expectedTarget):
      guard try fs.linkTarget(path) == target else {
        throw .blocked("\(path) no longer points to \(target).")
      }
      try replaceSymlinkAtomically(path, target: expectedTarget)
      guard try fs.linkTarget(path) == expectedTarget else {
        throw .io("\(path) does not point to \(expectedTarget) after the undo.")
      }

    case .backup:
      break  // Backups are kept.

    case .rewriteText(let path, _, _, _):
      try undoRewrite(path, detail: applied.detail)

    case .writeHubConfig(let spec):
      guard let recorded = applied.detail["shaWritten"] else {
        throw .blocked("The hash of \(spec.path) was not recorded; cannot tell if it is unchanged.")
      }
      guard try DatastoreIO.sha256Hex(fileAt: spec.path) == recorded else {
        throw .blocked("\(spec.path) has changed since it was written; refusing to remove it.")
      }
      guard Darwin.unlink(spec.path) == 0 else { throw posixFailure("unlink", spec.path) }
      guard try fs.lstatNode(spec.path) == nil else {
        throw .io("\(spec.path) is still there after unlink.")
      }
    }
    do throws(HubError) {
      try persist(applied, afterUndo: true)
    } catch {
      return "The undo of operation #\(applied.index) succeeded, but a directory could not be "
        + "flushed afterwards: \(text(of: error))"
    }
    return nil
  }

  /// The journal lives inside the backup directory this plan created. Undoing the creation of
  /// that directory first removes the journal, when it is all the directory holds: the report of
  /// the run keeps what the journal said.
  private func removeOwnJournalIfAlone() throws(HubError) {
    guard DatastorePath.parent(of: plan.journal) == plan.backupDir,
      try fs.childNames(of: plan.backupDir) == [DatastorePath.name(of: plan.journal)],
      try fs.lstatNode(plan.journal)?.kind == .file
    else { return }
    guard Darwin.unlink(plan.journal) == 0 else { throw posixFailure("unlink", plan.journal) }
  }

  private func undoRewrite(_ path: String, detail: [String: String]) throws(HubError) {
    guard let shaAfter = detail["shaAfter"], let backupFile = detail["backupFile"],
      let backupSHA = detail["backupSHA"]
    else {
      throw .blocked("The rewrite of \(path) has no recorded hashes to undo against.")
    }
    let current = try DatastoreIO.sha256Hex(fileAt: path)
    if current == backupSHA { return }  // A later undo of the same file already restored it.
    guard current == shaAfter else {
      throw .blocked("\(path) has changed since it was rewritten; refusing to overwrite it.")
    }
    guard let info = try fs.lstatNode(path), info.kind == .file else {
      throw .blocked("\(path) is no longer a regular file.")
    }
    guard let saved = try DatastoreIO.readBounded(backupFile, limit: DatastoreIO.contentLimit),
      DatastoreIO.sha256Hex(saved) == backupSHA
    else {
      throw .blocked("The backup \(backupFile) is missing or changed; cannot restore \(path).")
    }
    try writeAtomically(saved, to: path, mode: info.mode)
    guard try DatastoreIO.sha256Hex(fileAt: path) == backupSHA else {
      throw .io("\(path) does not match its backup after the restore.")
    }
  }

  // MARK: - Implicit post-checks

  /// The conditions every applied operation must leave true, judged from what was recorded.
  func postChecks(for appliedOps: [DatastoreAppliedOp]) -> [DatastoreCheckOutcome] {
    // For files rewritten more than once, only the last rewrite's bytes remain.
    var finalHash: [String: String] = [:]
    for applied in appliedOps {
      if case .rewriteText(let path, _, _, _) = applied.op, let sha = applied.detail["shaAfter"] {
        finalHash[path] = sha
      }
    }
    var outcomes: [DatastoreCheckOutcome] = []
    for applied in appliedOps {
      let name = "op #\(applied.index) \(applied.op.summary)"
      do throws(HubError) {
        let detail = try postCheck(applied, finalHash: finalHash)
        outcomes.append(.init(name: name, status: .pass, detail: detail))
      } catch {
        outcomes.append(.init(name: name, status: .fail, detail: text(of: error)))
      }
    }
    return outcomes
  }

  private func postCheck(
    _ applied: DatastoreAppliedOp, finalHash: [String: String]
  ) throws(HubError) -> String {
    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws(HubError) {
      if !condition { throw .io(message()) }
    }
    switch applied.op {
    case .mkdir(let path, let mode):
      let info = try fs.statNode(path)
      try require(info?.kind == .directory, "\(path) is not a directory.")
      try require(
        Int((info?.mode ?? 0) & 0o777) == mode,
        "\(path) has mode 0\(String((info?.mode ?? 0) & 0o777, radix: 8)), not 0\(String(mode, radix: 8))."
      )

    case .rename(let from, let to):
      guard let identity = applied.after ?? applied.before else {
        throw .io("No identity was recorded for \(to).")
      }
      let info = try fs.lstatNode(to)
      try require(
        info?.device == identity.device && info?.inode == identity.inode,
        "\(to) is not the entry that was moved (dev/ino differ).")
      let old = try fs.lstatNode(from)
      try require(
        old == nil || old?.kind == .symlink
          || (old?.inode == identity.inode && from.lowercased() == to.lowercased()),
        "\(from) still exists and is not a symlink left by a later operation.")

    case .symlink(let path, let target), .replaceSymlink(let path, let target, _):
      try require(try fs.linkTarget(path) == target, "\(path) does not point to \(target).")
      try require(try fs.statNode(path) != nil, "\(path) -> \(target) does not resolve.")

    case .backup(let path):
      if applied.detail["kind"] == "file" {
        guard let copy = applied.detail["backupFile"], let sha = applied.detail["sha256"] else {
          throw .io("The backup of \(path) has no recorded hash.")
        }
        try require(try DatastoreIO.sha256Hex(fileAt: copy) == sha, "\(copy) does not match.")
      } else if let target = applied.detail["target"] {
        let table = try DatastoreIO.readBounded(
          plan.backupDir + "/symlinks.tsv", limit: DatastoreJournal.maxFileBytes)
        let lines = table.map { String(decoding: $0, as: UTF8.self).split(separator: "\n") } ?? []
        try require(
          lines.contains { $0 == "\(path)\t\(target)" }, "symlinks.tsv has no record of \(path).")
      }

    case .rewriteText(let path, _, _, _):
      let expected = finalHash[path]
      try require(expected != nil, "No hash was recorded for \(path).")
      try require(
        try DatastoreIO.sha256Hex(fileAt: path) == expected,
        "\(path) does not hold the bytes the rewrite produced.")

    case .writeHubConfig(let spec):
      let expected = applied.detail["shaWritten"]
      try require(expected != nil, "No hash was recorded for \(spec.path).")
      try require(
        try DatastoreIO.sha256Hex(fileAt: spec.path) == expected,
        "\(spec.path) does not hold the bytes that were written.")
    }
    return ""
  }
}
