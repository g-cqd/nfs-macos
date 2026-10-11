import Darwin
import Foundation

/// How an operation stands in a report.
package enum DatastoreOpStatus: String, Codable, Equatable, Sendable {
  case planned
  case applied
  case undone
  case failed
}

/// One operation in a report, with the measurements a rename carries.
package struct DatastoreOpReport: Codable, Equatable, Sendable {
  package var index: Int
  package var summary: String
  package var status: DatastoreOpStatus
  package var before: DatastoreMeasurement?
  package var after: DatastoreMeasurement?
  package var message: String?
}

/// What evaluating a step against a (simulated) state found, before anything changes.
struct DatastoreStepPreview {
  var checks: [DatastoreCheckOutcome] = []
  var operations: [DatastoreOpReport] = []

  var isAcceptable: Bool { checks.allSatisfy(\.isAcceptable) }
}

/// Evaluates a step's preconditions, explicit and implicit, against a simulated state, and lays the
/// step's operations over that state one by one, so each operation is judged on what the earlier
/// ones would have left.
struct DatastoreStepPlanner: Sendable {
  let plan: DatastorePlan
  let snapshot: DatastoreProbeSnapshot
  let processID: Int32
  let environment: DatastoreCheckEnvironment

  /// The backup file of a regular file: `<backupDir>/files/<path without the leading slash>`.
  static func backupCopyPath(backupDir: String, of path: String) -> String {
    backupDir + "/files/" + path.dropFirst()
  }

  static func temporaryPath(for path: String, processID: Int32) -> String {
    "\(path).datastore-tmp-\(processID)"
  }

  /// Whether `from` -> `to` only changes the case of one name on a case-insensitive volume, where
  /// both names reach the same object.
  static func isCaseOnlyRename(
    from: String, to: String, fromInfo: DatastoreNodeInfo?, toInfo: DatastoreNodeInfo?
  ) -> Bool {
    guard let fromInfo, let toInfo else { return false }
    return from != to && from.lowercased() == to.lowercased()
      && fromInfo.device == toInfo.device && fromInfo.inode == toInfo.inode
  }

  /// Evaluates `step` on `simulation`, which is left in the state after the step's operations.
  /// `measuring` also walks each rename source (slow on a big tree) for the report.
  func preview(
    _ step: DatastoreStep, index: Int, on simulation: inout SimulatedDatastoreFileSystem,
    measuring: Bool
  ) -> DatastoreStepPreview {
    var preview = DatastoreStepPreview()

    func add(_ name: String, _ outcome: DatastoreCheckOutcome) {
      preview.checks.append(.init(name: name, status: outcome.status, detail: outcome.detail))
    }

    // Step-level conditions.
    let volumeOutcome = volumeMounted()
    preview.checks.append(volumeOutcome)
    let evaluator = DatastoreCheckEvaluator(
      fileSystem: simulation, snapshot: snapshot, environment: environment)
    if index > 0 {
      add(
        "journal directory exists",
        evaluator.evaluate(.exists(path: DatastorePath.parent(of: plan.journal), kind: .directory)))
    }
    if step.requiresNoWine {
      add("no Wine process is running", evaluator.evaluate(.noWineProcess))
    }
    for check in step.preconditions {
      preview.checks.append(evaluator.evaluate(check))
    }

    // Operations, each judged on the state the earlier ones leave.
    for (offset, op) in step.operations.enumerated() {
      let number = offset + 1
      var report = DatastoreOpReport(
        index: number, summary: op.summary, status: .planned, before: nil, after: nil,
        message: nil)
      let label = "op #\(number) \(op.summary)"
      do throws(HubError) {
        let facts = try implicitChecks(for: op, simulation: simulation, measuring: measuring)
        for fact in facts.checks {
          preview.checks.append(
            .init(name: "\(label): \(fact.name)", status: fact.status, detail: fact.detail))
        }
        report.before = facts.before
        try simulate(op, on: &simulation)
      } catch {
        preview.checks.append(
          .init(name: "\(label): can be evaluated", status: .fail, detail: text(of: error)))
      }
      preview.operations.append(report)
    }
    return preview
  }

  // MARK: - Step-level

  func volumeMounted() -> DatastoreCheckOutcome {
    let name = "volume \(plan.volume) is mounted"
    var info = stat()
    guard stat(plan.volume, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
      return .init(name: name, status: .fail, detail: "is not a directory")
    }
    if let root = HubPaths.volumeRoot(of: plan.volume), !HubPaths.isMounted(root) {
      return .init(name: name, status: .fail, detail: "\(root) is not a mounted volume")
    }
    return .init(name: name, status: .pass)
  }

  // MARK: - Implicit preconditions

  private struct Facts {
    var checks: [DatastoreCheckOutcome] = []
    var before: DatastoreMeasurement?

    mutating func add(_ name: String, _ ok: Bool, _ detail: String = "") {
      checks.append(.init(name: name, status: ok ? .pass : .fail, detail: ok ? "" : detail))
    }
  }

  /// The protected path that `path` conflicts with, as written or once the symlinks of its
  /// directory are resolved: `path` is inside it, or contains it (moving a folder moves what is
  /// inside). Each protected path is also tried in its resolved form.
  private func protectedViolation(
    _ path: String, simulation: SimulatedDatastoreFileSystem
  ) throws(HubError) -> String? {
    var candidates = [path]
    if let canonical = try simulation.canonicalDirectory(DatastorePath.parent(of: path)) {
      candidates.append(DatastorePath.join(canonical, DatastorePath.name(of: path)))
    }
    let real = RealDatastoreFileSystem()
    for protectedPath in plan.protected {
      var forms = [protectedPath]
      if let resolved = try real.canonicalDirectory(protectedPath), resolved != protectedPath {
        forms.append(resolved)
      }
      for form in forms {
        for candidate in candidates
        where DatastorePath.isWithin(candidate, form) || DatastorePath.isWithin(form, candidate) {
          return "\(form) (via \(candidate))"
        }
      }
    }
    return nil
  }

  /// Whether `path`, with the symlinks of its directory resolved, lies in an allowed root (each
  /// tried as written and resolved). Nil when it does; otherwise where it landed.
  private func rootViolation(
    _ path: String, simulation: SimulatedDatastoreFileSystem
  ) throws(HubError) -> String? {
    guard let canonical = try simulation.canonicalDirectory(DatastorePath.parent(of: path)) else {
      return nil
    }
    let landing = DatastorePath.join(canonical, DatastorePath.name(of: path))
    let real = RealDatastoreFileSystem()
    for root in plan.allowedRoots {
      var forms = [root]
      if let resolved = try real.canonicalDirectory(root), resolved != root {
        forms.append(resolved)
      }
      if forms.contains(where: { DatastorePath.isWithin(landing, $0) }) { return nil }
    }
    return landing
  }

  private func siblingCollision(
    of path: String, ignoring ignored: String?, simulation: SimulatedDatastoreFileSystem
  ) throws(HubError) -> String? {
    let parent = DatastorePath.parent(of: path)
    let name = DatastorePath.name(of: path)
    for sibling in try simulation.childNames(of: parent) ?? [] {
      if sibling == name || DatastorePath.join(parent, sibling) == ignored { continue }
      if sibling.lowercased() == name.lowercased() { return sibling }
    }
    return nil
  }

  private func implicitChecks(
    for op: DatastoreOp, simulation fs: SimulatedDatastoreFileSystem, measuring: Bool
  ) throws(HubError) -> Facts {
    var facts = Facts()

    func parentIsDirectory(_ path: String) throws(HubError) {
      let parent = DatastorePath.parent(of: path)
      let info = try fs.statNode(parent)
      facts.add("parent directory exists", info?.kind == .directory, "\(parent) is missing")
    }
    func safe(_ path: String) throws(HubError) {
      let hit = try protectedViolation(path, simulation: fs)
      facts.add(
        "\(path) is not inside or around a protected path", hit == nil,
        "it conflicts with the protected path \(hit ?? "")")
      let landing = try rootViolation(path, simulation: fs)
      facts.add(
        "\(path) lies in an allowed root", landing == nil,
        "it resolves to \(landing ?? ""), outside every allowed root")
    }
    func noLeftovers(_ path: String) throws(HubError) {
      let leftovers = try fs.leftoverTemporaries(for: path)
      facts.add(
        "no leftover temporary file beside \(DatastorePath.name(of: path))", leftovers.isEmpty,
        "\(leftovers.joined(separator: ", ")) left by an earlier run; remove by hand")
    }
    func fresh(_ path: String, ignoring ignored: String? = nil) throws(HubError) {
      let existing = try fs.lstatNode(path)
      facts.add("\(path) is absent", existing == nil, "it already exists")
      let sibling = try siblingCollision(of: path, ignoring: ignored, simulation: fs)
      facts.add(
        "no case-insensitive sibling of \(DatastorePath.name(of: path))", sibling == nil,
        "\(sibling ?? "") differs only by case")
    }

    switch op {
    case .mkdir(let path, _):
      try fresh(path)
      try parentIsDirectory(path)
      try safe(path)

    case .symlink(let path, _):
      try fresh(path)
      try parentIsDirectory(path)
      try safe(path)

    case .rename(let from, let to):
      let fromInfo = try fs.lstatNode(from)
      let toInfo = try fs.lstatNode(to)
      facts.add(
        "source is a real directory or file, not a symlink",
        fromInfo?.kind == .directory || fromInfo?.kind == .file,
        fromInfo.map { "it is a \($0.kind.rawValue)" } ?? "it does not exist")
      let caseOnly = Self.isCaseOnlyRename(from: from, to: to, fromInfo: fromInfo, toInfo: toInfo)
      facts.add("destination \(to) is absent", toInfo == nil || caseOnly, "it already exists")
      let sibling = try siblingCollision(of: to, ignoring: from, simulation: fs)
      facts.add(
        "no case-insensitive sibling of \(DatastorePath.name(of: to))", sibling == nil,
        "\(sibling ?? "") differs only by case")
      let parent = DatastorePath.parent(of: to)
      let parentInfo = try fs.statNode(parent)
      facts.add("destination parent exists", parentInfo?.kind == .directory, "\(parent) is missing")
      if let fromInfo, let parentInfo {
        facts.add(
          "source and destination parent are on one device (a rename, never a copy)",
          fromInfo.device == parentInfo.device,
          "device \(fromInfo.device) vs \(parentInfo.device)")
      }
      var forms = [from]
      if let canonical = try fs.canonicalDirectory(from), canonical != from {
        forms.append(canonical)
      }
      do throws(HubError) {
        let open = try snapshot.openFiles(under: forms)
        facts.add(
          "no open file under the source", open.isEmpty,
          "\(open.count) open: \(open.prefix(3).joined(separator: "; "))")
      } catch {
        facts.add("no open file under the source", false, text(of: error))
      }
      try safe(from)
      try safe(to)
      if measuring, fromInfo != nil { facts.before = try fs.measure(from) }

    case .replaceSymlink(let path, _, let expectedTarget):
      let actual = try fs.linkTarget(path)
      facts.add(
        "\(path) is a symlink to \(expectedTarget)", actual == expectedTarget,
        actual.map { "it points to \($0)" } ?? "it is not a symlink")
      try noLeftovers(path)
      try safe(path)

    case .backup(let path):
      try backupFacts(path, simulation: fs, facts: &facts)

    case .rewriteText(let path, let find, _, let expectedCount):
      let info = try fs.lstatNode(path)
      facts.add(
        "\(path) is a regular file", info?.kind == .file,
        info.map { "it is a \($0.kind.rawValue)" } ?? "it does not exist")
      if info?.kind == .file, let data = try fs.contents(of: path, limit: DatastoreIO.contentLimit)
      {
        let found = DatastoreIO.occurrences(of: Data(find.utf8), in: data)
        facts.add(
          "text occurs \(expectedCount) time(s)", found == expectedCount,
          "found \(found) occurrence(s)")
      }
      try noLeftovers(path)
      try safe(path)

    case .writeHubConfig(let spec):
      try fresh(spec.path)
      try parentIsDirectory(spec.path)
      try safe(spec.path)
      try noLeftovers(spec.path)
      if let manifest = try fs.contents(of: spec.runtimeManifest, limit: DatastoreIO.contentLimit) {
        let actual = DatastoreIO.sha256Hex(manifest)
        facts.add(
          "runtime manifest hash matches", actual == spec.runtimeManifestSHA256,
          "sha256 is \(actual), the plan expects \(spec.runtimeManifestSHA256)")
      } else {
        facts.add("runtime manifest exists", false, "\(spec.runtimeManifest) does not exist")
      }
    }
    return facts
  }

  private func backupFacts(
    _ path: String, simulation fs: SimulatedDatastoreFileSystem, facts: inout Facts
  ) throws(HubError) {
    let found = try fs.lstatNode(path)
    guard let info = found, info.kind == .file || info.kind == .symlink else {
      facts.add(
        "\(path) is a regular file or a symlink", false,
        found.map { "it is a \($0.kind.rawValue)" } ?? "it does not exist")
      return
    }
    facts.add("\(path) is a regular file or a symlink", true)
    if info.kind == .file {
      let copy = Self.backupCopyPath(backupDir: plan.backupDir, of: path)
      let leftovers = try fs.leftoverTemporaries(for: copy)
      facts.add(
        "no leftover temporary file beside the backup copy", leftovers.isEmpty,
        "\(leftovers.joined(separator: ", ")) left by an earlier run; remove by hand")
      if let existing = try fs.contents(of: copy, limit: DatastoreIO.contentLimit) {
        let current = try fs.contents(of: path, limit: DatastoreIO.contentLimit)
        facts.add(
          "an existing backup is identical", existing == current,
          "a different backup already exists at \(copy)")
      }
    } else if let target = try fs.linkTarget(path),
      let table = try fs.contents(
        of: plan.backupDir + "/symlinks.tsv", limit: DatastoreIO.contentLimit)
    {
      let lines = String(decoding: table, as: UTF8.self).split(separator: "\n")
      let conflict = lines.first {
        $0.hasPrefix(path + "\t") && $0 != "\(path)\t\(target)"
      }
      facts.add(
        "an existing symlink record is identical", conflict == nil,
        "a different record exists: \(conflict ?? "")")
    }
  }

  // MARK: - Simulation

  private func simulate(
    _ op: DatastoreOp, on fs: inout SimulatedDatastoreFileSystem
  ) throws(HubError) {
    switch op {
    case .mkdir(let path, let mode):
      try fs.makeDirectory(path, mode: mode)
    case .symlink(let path, let target):
      try fs.placeSymlink(path, target: target)
    case .replaceSymlink(let path, let target, _):
      try fs.placeSymlink(path, target: target)
    case .rename(let from, let to):
      try fs.rename(from: from, to: to)
    case .backup:
      break
    case .rewriteText(let path, let find, let replace, _):
      guard let data = try fs.contents(of: path, limit: DatastoreIO.contentLimit),
        let info = try fs.lstatNode(path)
      else {
        throw .invalid("Cannot read \(path) to simulate the rewrite.")
      }
      let rewritten = DatastoreIO.replacing(Data(find.utf8), with: Data(replace.utf8), in: data)
      try fs.placeFile(path, data: rewritten, mode: info.mode)
    case .writeHubConfig(let spec):
      try fs.placeFile(spec.path, data: Data(), mode: 0o644)
    }
  }
}
