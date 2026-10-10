import Darwin
import Foundation
import LauncherCore

// MARK: - Planner

/// Decides what an instance would contain and what it would cost, without writing anything.
package enum InstancePlanner {
  /// Walks `prefix` and classifies every path by `recipe`: real, placeholder, omitted, symlink,
  /// directory. Paths are relative to the prefix with their exact case, and every parent folder
  /// is listed before its children. Nothing is followed: symlinks are recorded, not entered.
  ///
  /// - Every name is visited, dotfiles included; only `.DS_Store` is skipped.
  /// - A path under an omit root is recorded once as `.omitted` (the root itself, not each file
  ///   inside it) and is not walked. An omit root wins over a real root.
  /// - A symlink whose absolute target lies inside the prefix is rewritten to a relative link, so
  ///   the instance never points back at the source. A target outside the prefix (absolute, or
  ///   relative and climbing above the prefix root) is kept as it is and listed in `externalLinks`.
  /// - Pipes, sockets and devices are skipped and counted in `skippedSpecialCount`.
  /// - Recipe paths are matched by whole components; empty components are ignored.
  ///
  /// - Throws: `.invalid` when a recipe path is absolute, holds a `.` or `..` component or a NUL,
  ///   when no entry of the prefix lies under a real root or boot path, or when two names in one
  ///   folder differ only by case (they would collide on a case-insensitive volume);
  ///   `.io` when a folder cannot be listed or a path cannot be inspected.
  /// - Complexity: O(n log n) in the number of entries n (each folder's names are sorted).
  package static func plan(prefix: URL, recipe: InstanceRecipe) throws(HubError) -> InstancePlan {
    var walker = try PlanWalker(prefix: prefix, recipe: recipe)
    try walker.run()
    return try walker.finish(recipe: recipe)
  }
}

/// The state of one planner run.
private struct PlanWalker {
  private let root: String
  private let rootComponents: [String]
  private let realRootComponents: [String]
  private let realRoots: [[String]]
  private let omitRoots: [[String]]

  private var entries: [InstanceEntry] = []
  private var realBytes: Int64 = 0
  private var allocatedBytes: Int64 = 0
  private var placeholderCount = 0
  private var omittedCount = 0
  private var skippedSpecialCount = 0
  private var externalLinks: [String] = []
  private var matchedRealRoot = false

  init(prefix: URL, recipe: InstanceRecipe) throws(HubError) {
    var real: [[String]] = []
    for path in recipe.realRoots + recipe.bootPaths {
      real.append(try InstancePaths.components(path, subject: "Recipe path", dropEmpty: true))
    }
    var omit: [[String]] = []
    for path in recipe.omitRoots {
      omit.append(try InstancePaths.components(path, subject: "Recipe path", dropEmpty: true))
    }
    realRoots = real
    omitRoots = omit
    root = prefix.standardizedFileURL.path
    rootComponents = InstancePaths.lexical(root)
    realRootComponents = InstancePaths.realPath(root).map(InstancePaths.lexical) ?? rootComponents
  }

  mutating func run() throws(HubError) {
    var rootInfo = stat()
    guard stat(root, &rootInfo) == 0 else { throw posixFailure("Inspecting the prefix", root) }
    guard rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw .io("The prefix \(root) is not a folder.")
    }
    var pending: [[String]] = [[]]
    while let directory = pending.popLast() {
      let subdirectories = try visit(directory)
      pending.append(contentsOf: subdirectories.reversed())
    }
  }

  func finish(recipe: InstanceRecipe) throws(HubError) -> InstancePlan {
    guard matchedRealRoot else {
      throw .invalid("No path of the prefix lies under the recipe's real roots or boot paths.")
    }
    return InstancePlan(
      recipe: recipe, entries: entries, realBytes: realBytes, placeholderCount: placeholderCount,
      omittedCount: omittedCount, externalLinks: externalLinks, allocatedBytes: allocatedBytes,
      skippedSpecialCount: skippedSpecialCount)
  }

  /// Classifies the children of one folder and returns the folders to visit next.
  private mutating func visit(_ directory: [String]) throws(HubError) -> [[String]] {
    let directoryPath = directory.isEmpty ? root : root + "/" + directory.joined(separator: "/")
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directoryPath).sorted()
    } catch {
      throw .io("Could not list \(directoryPath): \(error.localizedDescription)")
    }
    var subdirectories: [[String]] = []
    var keysSeen: [String: String] = [:]
    for name in names where name != ".DS_Store" {
      let components = directory + [name]
      let path = directoryPath + "/" + name
      var info = stat()
      guard lstat(path, &info) == 0 else { throw posixFailure("Inspecting", path) }
      let relative = components.joined(separator: "/")
      let type = info.st_mode & mode_t(S_IFMT)

      if InstancePaths.isUnder(components, roots: omitRoots) {
        omittedCount += 1
        entries.append(makeEntry(relative, .omitted, info))
        continue
      }
      guard type == mode_t(S_IFDIR) || type == mode_t(S_IFLNK) || type == mode_t(S_IFREG) else {
        skippedSpecialCount += 1
        continue
      }
      try noteCaseCollision(name, in: directory, keys: &keysSeen)
      let isReal = InstancePaths.isUnder(components, roots: realRoots)
      matchedRealRoot = matchedRealRoot || isReal

      switch type {
      case mode_t(S_IFDIR):
        entries.append(makeEntry(relative, .directory, info))
        subdirectories.append(components)
      case mode_t(S_IFLNK):
        try addSymlink(components, path: path, info: info)
      default:
        addFile(relative, isReal: isReal, info: info)
      }
    }
    return subdirectories
  }

  private mutating func addFile(_ relative: String, isReal: Bool, info: stat) {
    if isReal {
      realBytes += Int64(info.st_size)
      allocatedBytes += Int64(info.st_blocks) * 512
      entries.append(makeEntry(relative, .real, info))
    } else {
      placeholderCount += 1
      entries.append(makeEntry(relative, .placeholder, info))
    }
  }

  private mutating func addSymlink(_ components: [String], path: String, info: stat)
    throws(HubError)
  {
    let target: String
    do {
      target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
    } catch {
      throw .io("Could not read the link \(path): \(error.localizedDescription)")
    }
    let relative = components.joined(separator: "/")
    let (instanceTarget, isExternal) = rewrite(target, linkAt: components)
    if isExternal { externalLinks.append(relative) }
    entries.append(makeEntry(relative, .symlink, info, linkTarget: instanceTarget))
  }

  /// The target the instance's copy of a link will hold, and whether it leaves the prefix.
  private func rewrite(_ target: String, linkAt components: [String]) -> (String, Bool) {
    let linkDirectory = Array(components.dropLast())
    if target.utf8.first == 0x2F {
      let resolved = InstancePaths.lexical(target)
      for base in [rootComponents, realRootComponents] where resolved.starts(with: base) {
        let inside = Array(resolved.dropFirst(base.count))
        var shared = 0
        while shared < linkDirectory.count, shared < inside.count,
          linkDirectory[shared] == inside[shared]
        {
          shared += 1
        }
        let parts =
          Array(repeating: "..", count: linkDirectory.count - shared) + inside.dropFirst(shared)
        return (parts.isEmpty ? "." : parts.joined(separator: "/"), false)
      }
      return (target, true)
    }
    var depth = linkDirectory.count
    for part in target.utf8.split(separator: 0x2F) {
      switch String(decoding: part, as: UTF8.self) {
      case ".": continue
      case "..":
        guard depth > 0 else { return (target, true) }
        depth -= 1
      default: depth += 1
      }
    }
    return (target, false)
  }

  /// Throws when `name` and an earlier name of the same folder differ only by case or Unicode form.
  private func noteCaseCollision(
    _ name: String, in directory: [String], keys: inout [String: String]
  ) throws(HubError) {
    let key = name.precomposedStringWithCanonicalMapping.lowercased()
    if let earlier = keys[key] {
      let folder = directory.isEmpty ? "the prefix root" : directory.joined(separator: "/")
      throw .invalid("The names '\(earlier)' and '\(name)' in \(folder) differ only by case.")
    }
    keys[key] = name
  }

  private func makeEntry(
    _ relative: String, _ kind: EntryKind, _ info: stat, linkTarget: String? = nil
  ) -> InstanceEntry {
    InstanceEntry(
      path: relative, kind: kind, size: kind == .directory ? 0 : Int64(info.st_size),
      mode: UInt16(info.st_mode & 0o7777), mtimeSeconds: Int64(info.st_mtimespec.tv_sec),
      mtimeNanos: Int32(info.st_mtimespec.tv_nsec), linkTarget: linkTarget)
  }
}

// MARK: - Builder

/// Writes an instance: real files copied, placeholders created, links recreated.
package enum InstanceBuilder {
  /// Builds `<instances>/<instanceID>/Prefix` and `instance.json` in a uniquely named hidden
  /// staging folder and renames it into place when complete, so a visible instance is always whole.
  ///
  /// The whole build runs under an `flock` on `<instances>/.lock`; a second build or a removal at
  /// the same time is refused with `.io`. Only while holding that lock are stale `.staging-*` and
  /// `.trash-*` folders of crashed runs deleted. A failed build deletes only its own staging folder.
  /// Nothing is written, not even the lock, before the budget check passes.
  ///
  /// - Parameters:
  ///   - plan: The plan from ``InstancePlanner/plan(prefix:recipe:)``. Every entry path is
  ///     validated again here.
  ///   - budget: The space needed is the plan's allocated bytes plus a margin for folders and
  ///     metadata.
  /// - Throws: `.invalid` for a bad id; `.unsafePath` for a plan entry that escapes the prefix, has no
  ///   folder parent or whose link would resolve into the source; `.belowFloor` before any write;
  ///   `.io` for a duplicate id, a held lock, or any failed file operation.
  /// - Complexity: O(n) in the number of entries; copying the real files dominates.
  package static func build(
    plan: InstancePlan, prefix: URL, instances: URL, instanceID: String, budget: SpaceBudget,
    now: Date
  ) throws(HubError) -> InstanceManifest {
    let id = try InstanceID(instanceID)
    var componentsOfEntry: [[String]] = []
    componentsOfEntry.reserveCapacity(plan.entries.count)
    for entry in plan.entries {
      componentsOfEntry.append(
        try InstancePaths.components(
          entry.path, subject: "Plan entry", dropEmpty: false, escapeIsUnsafe: true))
    }
    let needed = requiredBytes(plan)
    guard budget.allows(adding: needed) else {
      throw .belowFloor(needed: needed, free: budget.free, floor: budget.floor)
    }

    let instancesPath = instances.standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: instancesPath, withIntermediateDirectories: true)
    } catch {
      throw .io("Could not create \(instancesPath): \(error.localizedDescription)")
    }
    let lock = try InstanceLock.acquire(instancesPath: instancesPath)
    defer { lock.release() }
    try sweepStaleFolders(instancesPath: instancesPath)

    let targetPath = instancesPath + "/" + id.rawValue
    var existing = stat()
    guard lstat(targetPath, &existing) != 0, errno == ENOENT else {
      throw .io("Instance \(id) already exists.")
    }

    let suffix = UUID().uuidString.prefix(8).lowercased()
    let stagingPath = instancesPath + "/.staging-\(id.rawValue)-\(suffix)"
    do throws(HubError) {
      guard mkdir(stagingPath, 0o700) == 0 else {
        throw posixFailure("Creating the staging folder", stagingPath)
      }
      let manifest = try populate(
        stagingPath: stagingPath, plan: plan, components: componentsOfEntry,
        sourceRoot: prefix.standardizedFileURL.path, id: id, now: now)
      guard renamex_np(stagingPath, targetPath, UInt32(RENAME_EXCL)) == 0 else {
        throw posixFailure("Moving the finished instance into place", targetPath)
      }
      return manifest
    } catch {
      do {
        try TreeDeleter.remove(path: stagingPath)
      } catch let cleanup {
        throw .io(
          "\(text(of: error)) The staging folder \(stagingPath) was left behind: \(text(of: cleanup))"
        )
      }
      throw error
    }
  }

  /// The bytes the budget must cover: allocated bytes of the real files plus 1 MiB and 1 KiB per
  /// entry for folders, links, placeholders and the manifest. Saturates instead of overflowing.
  private static func requiredBytes(_ plan: InstancePlan) -> Int64 {
    let margin = Int64(1_048_576) + Int64(plan.entries.count) * 1024
    let (sum, overflow) = plan.allocatedBytes.addingReportingOverflow(margin)
    return overflow ? Int64.max : sum
  }

  /// Deletes `.staging-*` and `.trash-*` folders. The caller holds the instances lock, so each is a
  /// leftover of a run that no longer exists.
  private static func sweepStaleFolders(instancesPath: String) throws(HubError) {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: instancesPath)
    } catch {
      throw .io("Could not list \(instancesPath): \(error.localizedDescription)")
    }
    for name in names where name.hasPrefix(".staging-") || name.hasPrefix(".trash-") {
      try TreeDeleter.remove(path: instancesPath + "/" + name)
    }
  }

  private static func populate(
    stagingPath: String, plan: InstancePlan, components: [[String]], sourceRoot: String,
    id: InstanceID, now: Date
  ) throws(HubError) -> InstanceManifest {
    let prefixPath = stagingPath + "/Prefix"
    guard mkdir(prefixPath, 0o700) == 0 else {
      throw posixFailure("Creating the instance prefix", prefixPath)
    }
    var writer = StagingWriter(sourceRoot: sourceRoot, prefixRoot: prefixPath)
    for (entry, parts) in zip(plan.entries, components) {
      try writer.write(entry, components: parts)
    }
    try writer.finishDirectories()
    try writer.verifyLinksLeaveSourceAlone()

    let manifest = InstanceManifest(
      instanceID: id.rawValue, gameID: plan.recipe.gameID, createdAt: now,
      sourcePrefix: sourceRoot, realBytes: plan.realBytes, entries: plan.entries)
    let manifestPath = stagingPath + "/instance.json"
    do {
      let data = try InstanceManifest.encoder().encode(manifest)
      try data.write(to: URL(fileURLWithPath: manifestPath), options: [.withoutOverwriting])
    } catch {
      throw .io("Could not write instance.json: \(error.localizedDescription)")
    }
    return manifest
  }
}

/// Writes the entries of a plan into a staging prefix, one at a time.
private struct StagingWriter {
  private struct DirectoryFixup {
    let path: String
    let mode: UInt16
    let seconds: Int64
    let nanos: Int32
  }
  private struct LinkRecord {
    let path: String
    let target: String
  }

  private let sourceRoot: String
  private let prefixRoot: String
  private var createdDirectories: Set<String> = []
  private var fixups: [DirectoryFixup] = []
  private var links: [LinkRecord] = []

  init(sourceRoot: String, prefixRoot: String) {
    self.sourceRoot = sourceRoot
    self.prefixRoot = prefixRoot
  }

  /// Creates one entry. Its parent must be the prefix root or a folder this writer created, so an
  /// entry can never be written through a link that an earlier entry created.
  mutating func write(_ entry: InstanceEntry, components: [String]) throws(HubError) {
    if entry.kind == .omitted { return }
    let relative = components.joined(separator: "/")
    let parent = components.dropLast().joined(separator: "/")
    guard parent.isEmpty || createdDirectories.contains(parent) else {
      throw .unsafePath("Plan entry '\(relative)' has no folder entry as its parent.")
    }
    let source = sourceRoot + "/" + relative
    let destination = prefixRoot + "/" + relative

    switch entry.kind {
    case .directory:
      guard mkdir(destination, mode_t(entry.mode) | 0o700) == 0 else {
        throw posixFailure("Creating the folder", destination)
      }
      createdDirectories.insert(relative)
      fixups.append(
        DirectoryFixup(
          path: destination, mode: entry.mode, seconds: entry.mtimeSeconds,
          nanos: entry.mtimeNanos))
    case .real:
      try copyReal(from: source, to: destination)
    case .placeholder:
      try createPlaceholder(entry, at: destination)
    case .symlink:
      guard let target = entry.linkTarget, !target.isEmpty, !target.utf8.contains(0) else {
        throw .unsafePath("The link '\(relative)' has no usable target.")
      }
      guard symlink(target, destination) == 0 else {
        throw posixFailure("Creating the link", destination)
      }
      links.append(LinkRecord(path: destination, target: target))
    case .omitted:
      return
    }
  }

  private func copyReal(from source: String, to destination: String) throws(HubError) {
    let flags = copyfile_flags_t(
      COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
    guard copyfile(source, destination, nil, flags) == 0 else {
      throw posixFailure("Copying", source)
    }
    var info = stat()
    guard lstat(destination, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw .io("The copy of \(source) is not a regular file.")
    }
  }

  private func createPlaceholder(_ entry: InstanceEntry, at destination: String) throws(HubError) {
    let descriptor = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw posixFailure("Creating the placeholder", destination) }
    defer { close(descriptor) }
    let nanos = String(entry.mtimeNanos)
    let value =
      "\(entry.size):\(entry.mtimeSeconds).\(String(repeating: "0", count: 9 - nanos.count))\(nanos)"
    guard fsetxattr(descriptor, "org.gamehub.placeholder", value, value.utf8.count, 0, 0) == 0
    else {
      throw posixFailure("Marking the placeholder", destination)
    }
    var times = [
      timespec(tv_sec: Int(entry.mtimeSeconds), tv_nsec: Int(entry.mtimeNanos)),
      timespec(tv_sec: Int(entry.mtimeSeconds), tv_nsec: Int(entry.mtimeNanos)),
    ]
    guard futimens(descriptor, &times) == 0 else {
      throw posixFailure("Setting the placeholder's time", destination)
    }
    guard fchmod(descriptor, mode_t(entry.mode)) == 0 else {
      throw posixFailure("Setting the placeholder's mode", destination)
    }
  }

  /// Applies each folder's original time and then its mode, deepest first, after every child
  /// exists (creating a child changes its parent's time). The owner keeps read, write and search
  /// so the instance can always be removed.
  func finishDirectories() throws(HubError) {
    for fixup in fixups.reversed() {
      var times = [
        timespec(tv_sec: Int(fixup.seconds), tv_nsec: Int(fixup.nanos)),
        timespec(tv_sec: Int(fixup.seconds), tv_nsec: Int(fixup.nanos)),
      ]
      guard utimensat(AT_FDCWD, fixup.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw posixFailure("Setting the folder's time", fixup.path)
      }
      guard fchmodat(AT_FDCWD, fixup.path, mode_t(fixup.mode) | 0o700, AT_SYMLINK_NOFOLLOW) == 0
      else { throw posixFailure("Setting the folder's mode", fixup.path) }
    }
  }

  /// Throws when any link of the instance resolves to a path inside the source prefix, because a
  /// write through it would change the original. A link that cannot be resolved (dangling) is
  /// judged by its text.
  func verifyLinksLeaveSourceAlone() throws(HubError) {
    let sourceComponents = InstancePaths.lexical(sourceRoot)
    let realSource = InstancePaths.realPath(sourceRoot).map(InstancePaths.lexical)
    let sources = [sourceComponents] + (realSource.map { [$0] } ?? [])
    for link in links {
      let resolved: [String]
      if let real = InstancePaths.realPath(link.path) {
        resolved = InstancePaths.lexical(real)
      } else if link.target.utf8.first == 0x2F {
        resolved = InstancePaths.lexical(link.target)
      } else {
        let directory = (link.path as NSString).deletingLastPathComponent
        resolved = InstancePaths.lexical(directory + "/" + link.target)
      }
      if InstancePaths.isUnder(resolved, roots: sources) {
        throw .unsafePath("The link \(link.path) would point into the source prefix.")
      }
    }
  }
}

// MARK: - Remover

/// Removes an instance, and only an instance.
package enum InstanceRemover {
  /// Deletes `<instances>/<instanceID>` after checking that it is a real folder (not a link) that
  /// is a direct child of `instances`, holds an `instance.json` naming the same id, and has no
  /// running Wine server. The folder is first renamed to `.trash-<id>`, so it vanishes from the
  /// list at once, then deleted without following links or crossing volumes.
  ///
  /// - Throws: `.invalid` for a bad id; `.unsafePath` when the folder is missing, is a link, or its
  ///   `instance.json` is unreadable or names another id; `.io` while the instance's Wine server is
  ///   running, while another build or removal holds the lock, or when deletion fails after the
  ///   rename (the message names the leftover `.trash-<id>` folder).
  /// - Complexity: O(n) in the number of entries of the instance.
  package static func remove(instanceID: String, instances: URL) throws(HubError) {
    let id = try InstanceID(instanceID)
    guard let instancesPath = InstancePaths.realPath(instances.path) else {
      throw .unsafePath("The instances folder was not found.")
    }
    let lock = try InstanceLock.acquire(instancesPath: instancesPath)
    defer { lock.release() }

    let targetPath = instancesPath + "/" + id.rawValue
    var info = stat()
    guard lstat(targetPath, &info) == 0 else {
      throw .unsafePath("Instance \(id) was not found.")
    }
    let type = info.st_mode & mode_t(S_IFMT)
    guard type != mode_t(S_IFLNK) else { throw .unsafePath("Instance \(id) is a link.") }
    guard type == mode_t(S_IFDIR) else { throw .unsafePath("Instance \(id) is not a folder.") }

    let manifest: InstanceManifest
    do {
      let data = try BoundedFile.read(
        URL(fileURLWithPath: targetPath + "/instance.json"), limit: InstanceManifest.maxFileBytes)
      manifest = try InstanceManifest.decoder().decode(InstanceManifest.self, from: data)
    } catch {
      throw .unsafePath("Instance \(id) has no readable instance.json.")
    }
    guard manifest.instanceID == id.rawValue else {
      throw .unsafePath("The instance.json of \(id) names a different instance.")
    }
    guard !PrefixActivity.serverIsRunning(prefix: URL(fileURLWithPath: targetPath + "/Prefix"))
    else { throw .io("Instance \(id) is in use: its Wine server is running. Quit the game first.") }

    let trashName = ".trash-\(id.rawValue)"
    let trashPath = instancesPath + "/" + trashName
    var leftover = stat()
    if lstat(trashPath, &leftover) == 0 { try TreeDeleter.remove(path: trashPath) }
    guard renamex_np(targetPath, trashPath, UInt32(RENAME_EXCL)) == 0 else {
      throw posixFailure("Moving the instance to the trash", targetPath)
    }
    do {
      try TreeDeleter.remove(path: trashPath)
    } catch {
      throw .io(
        "Instance \(id) was removed from the list but not fully deleted; delete the leftover "
          + "folder \(trashName) in \(instancesPath). \(text(of: error))"
      )
    }
  }
}
