import Foundation

/// Lexical rules for the absolute paths a plan names.
package enum DatastorePath {
  /// Whether `path` is absolute and normalised: no `.` or `..` component, no `//`, no trailing
  /// `/` (the root `/` itself is accepted) and no NUL.
  package static func isNormalised(_ path: String) -> Bool {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
    if path == "/" { return true }
    for component in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
      if component.isEmpty || component == "." || component == ".." { return false }
    }
    return true
  }

  /// Whether `path` equals `root` or lies below it, by whole components.
  package static func isWithin(_ path: String, _ root: String) -> Bool {
    if root == "/" { return path.hasPrefix("/") }
    return path == root || path.hasPrefix(root + "/")
  }

  /// The directory part of an absolute path (`/` for a top-level name).
  package static func parent(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
    return String(path[path.startIndex..<slash])
  }

  /// The last component of an absolute path.
  package static func name(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
  }

  /// `directory` and `name` joined with one `/`.
  package static func join(_ directory: String, _ name: String) -> String {
    directory == "/" ? "/" + name : directory + "/" + name
  }

  /// `target` resolved against `directory` when relative, with `.` and `..` collapsed lexically.
  package static func resolve(_ target: String, in directory: String) -> String {
    let joined = target.hasPrefix("/") ? target : join(directory, target)
    var parts: [Substring] = []
    for component in joined.split(separator: "/", omittingEmptySubsequences: true) {
      if component == "." { continue }
      if component == ".." {
        _ = parts.popLast()
      } else {
        parts.append(component)
      }
    }
    return "/" + parts.joined(separator: "/")
  }
}

extension DatastorePlan {
  /// The paths an operation changes on disk (not the paths it only reads).
  package static func mutatedPaths(of op: DatastoreOp) -> [String] {
    switch op {
    case .mkdir(let path, _), .symlink(let path, _), .replaceSymlink(let path, _, _),
      .rewriteText(let path, _, _, _):
      return [path]
    case .rename(let from, let to):
      return [from, to]
    case .writeHubConfig(let spec):
      return [spec.path]
    case .backup:
      return []
    }
  }

  /// Every reason this plan is not acceptable, in plan order; empty when it is valid.
  ///
  /// The rules: schema version 1; absolute, normalised paths only; `protected` holds
  /// `<volume>/Bundles`; every path an operation changes lies under an allowed root and never in a
  /// protected path; step ids are unique and match `^S[0-9]{2}-[a-z0-9-]+$`; `rewriteText` follows
  /// a `backup` of its file in the same step; the first step creates `backupDir`, and no later step
  /// moves it or touches what it holds.
  package func validationErrors() -> [String] {
    var errors: [String] = []

    if schemaVersion != 1 { errors.append("schemaVersion must be 1, got \(schemaVersion).") }
    if !Self.isValidIdentifier(id, maxLength: 64) {
      errors.append("id must be 1 to 64 characters of a-z, 0-9 and '-'.")
    }
    if !DatastorePath.isNormalised(volume) || volume == "/" {
      errors.append("volume must be an absolute, normalised path other than /: \(volume)")
    }
    for path in protected where !DatastorePath.isNormalised(path) {
      errors.append("protected path is not absolute and normalised: \(path)")
    }
    if !protected.contains(volume + "/Bundles") {
      errors.append("protected must contain \(volume)/Bundles.")
    }
    if allowedRoots.isEmpty { errors.append("allowedRoots must not be empty.") }
    for root in allowedRoots {
      if !DatastorePath.isNormalised(root) || root == "/" {
        errors.append("allowed root must be an absolute, normalised path other than /: \(root)")
      } else if let hit = protectedHit(root) {
        errors.append("allowed root \(root) is inside the protected path \(hit).")
      }
    }
    validateMutable(backupDir, label: "backupDir", errors: &errors)
    if !DatastorePath.isNormalised(journal) {
      errors.append("journal must be an absolute, normalised path: \(journal)")
    } else if journal == backupDir || !DatastorePath.isWithin(journal, backupDir) {
      errors.append("journal must be a file under backupDir: \(journal)")
    }

    if steps.isEmpty { errors.append("The plan has no steps.") }
    var seen = Set<String>()
    for (stepIndex, step) in steps.enumerated() {
      if !seen.insert(step.id).inserted { errors.append("Duplicate step id \(step.id).") }
      validate(step, index: stepIndex, errors: &errors)
    }
    if let first = steps.first {
      let createsBackupDir = first.operations.contains {
        if case .mkdir(let path, _) = $0 { return path == backupDir }
        return false
      }
      if !createsBackupDir {
        errors.append(
          "The first step (\(first.id)) must create backupDir with a mkdir; "
            + "every later step needs it for the journal.")
      }
    }
    return errors
  }

  // MARK: - Pieces

  private static func isValidIdentifier(_ text: String, maxLength: Int) -> Bool {
    let bytes = text.utf8
    guard !bytes.isEmpty, bytes.count <= maxLength else { return false }
    return bytes.allSatisfy {
      ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D
    }
  }

  /// `^S[0-9]{2}-[a-z0-9-]+$`
  private static func isValidStepID(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard bytes.count >= 5, bytes.count <= 64, bytes[0] == 0x53, bytes[3] == 0x2D else {
      return false
    }
    guard bytes[1...2].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return false }
    return bytes[4...].allSatisfy {
      ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D
    }
  }

  /// The protected path that contains `path`, if any.
  private func protectedHit(_ path: String) -> String? {
    protected.first { DatastorePath.isWithin(path, $0) }
  }

  private func validateMutable(_ path: String, label: String, errors: inout [String]) {
    guard DatastorePath.isNormalised(path) else {
      errors.append("\(label) is not an absolute, normalised path: \(path)")
      return
    }
    if let hit = protectedHit(path) {
      errors.append("\(label) \(path) is inside the protected path \(hit); refusing.")
    } else if let hit = protected.first(where: { DatastorePath.isWithin($0, path) }) {
      errors.append(
        "\(label) \(path) contains the protected path \(hit); changing it would change that; "
          + "refusing.")
    }
    if !allowedRoots.contains(where: { DatastorePath.isWithin(path, $0) }) {
      errors.append("\(label) \(path) is outside every allowed root.")
    }
  }

  private func validateReadable(_ path: String, label: String, errors: inout [String]) {
    if !DatastorePath.isNormalised(path) {
      errors.append("\(label) is not an absolute, normalised path: \(path)")
    }
  }

  private func validate(_ step: DatastoreStep, index: Int, errors: inout [String]) {
    let scope = "step \(step.id)"
    if !Self.isValidStepID(step.id) {
      errors.append("\(scope): id must match ^S[0-9]{2}-[a-z0-9-]+$.")
    }
    if step.title.isEmpty { errors.append("\(scope): title must not be empty.") }
    if step.operations.isEmpty { errors.append("\(scope): the step has no operations.") }

    var backedUp = Set<String>()
    for (opIndex, op) in step.operations.enumerated() {
      let label = "\(scope) op #\(opIndex + 1)"
      validate(op, label: label, backedUp: backedUp, errors: &errors)
      if case .backup(let path) = op { backedUp.insert(path) }

      for path in Self.mutatedPaths(of: op) where DatastorePath.isNormalised(path) {
        let isBackupDirCreation: Bool = {
          if index == 0, case .mkdir(let made, _) = op { return made == backupDir }
          return false
        }()
        if DatastorePath.isWithin(path, backupDir) && !isBackupDirCreation {
          errors.append(
            "\(label): \(path) is inside backupDir; only the executor writes there.")
        } else if index > 0, DatastorePath.isWithin(backupDir, path) {
          errors.append(
            "\(label): \(path) contains backupDir; only the first step may create or move it.")
        }
      }
    }
    for (checkIndex, check) in step.preconditions.enumerated() {
      validate(check, label: "\(scope) precondition #\(checkIndex + 1)", errors: &errors)
    }
    for (checkIndex, check) in step.verify.enumerated() {
      validate(check, label: "\(scope) verify #\(checkIndex + 1)", errors: &errors)
    }
  }

  private func validate(
    _ op: DatastoreOp, label: String, backedUp: Set<String>, errors: inout [String]
  ) {
    func target(_ text: String, _ name: String) {
      if text.isEmpty || text.utf8.contains(0) || text.utf8.count >= 1024 {
        errors.append("\(label): \(name) must be 1 to 1023 bytes with no NUL.")
      }
    }
    switch op {
    case .mkdir(let path, let mode):
      validateMutable(path, label: "\(label) mkdir path", errors: &errors)
      if mode < 0 || mode > 0o777 {
        errors.append("\(label): mode must be 0 to 511 (octal 0 to 0777), got \(mode).")
      }
    case .rename(let from, let to):
      validateMutable(from, label: "\(label) rename from", errors: &errors)
      validateMutable(to, label: "\(label) rename to", errors: &errors)
      if from == to { errors.append("\(label): rename from and to are the same path.") }
      if from != to, DatastorePath.isWithin(to, from) {
        errors.append("\(label): rename target \(to) is inside its own source.")
      }
    case .symlink(let path, let linkTarget):
      validateMutable(path, label: "\(label) symlink path", errors: &errors)
      target(linkTarget, "target")
    case .replaceSymlink(let path, let linkTarget, let expectedTarget):
      validateMutable(path, label: "\(label) replaceSymlink path", errors: &errors)
      target(linkTarget, "target")
      target(expectedTarget, "expectedTarget")
    case .backup(let path):
      validateReadable(path, label: "\(label) backup path", errors: &errors)
    case .rewriteText(let path, let find, let replace, let expectedCount):
      validateMutable(path, label: "\(label) rewriteText path", errors: &errors)
      if find.isEmpty { errors.append("\(label): find must not be empty.") }
      if expectedCount < 1 { errors.append("\(label): expectedCount must be at least 1.") }
      if find == replace { errors.append("\(label): find and replace are identical.") }
      if !backedUp.contains(path) {
        errors.append(
          "\(label): rewriteText of \(path) needs an earlier backup of it in this step.")
      }
    case .writeHubConfig(let spec):
      validateMutable(spec.path, label: "\(label) writeHubConfig path", errors: &errors)
      validateReadable(
        spec.runtimeManifest, label: "\(label) runtimeManifest", errors: &errors)
      do {
        try spec.config.validate()
      } catch {
        errors.append("\(label): \(text(of: error))")
      }
    }
  }

  private func validate(_ check: DatastoreCheck, label: String, errors: inout [String]) {
    func path(_ value: String) { validateReadable(value, label: "\(label) path", errors: &errors) }
    switch check {
    case .exists(let value, _), .absent(let value), .notSymlink(let value), .vdfParses(let value),
      .shellSyntax(let value), .noOpenFiles(let value):
      path(value)
    case .symlinkTarget(let value, let target):
      path(value)
      if target.isEmpty { errors.append("\(label): target must not be empty.") }
    case .sameFile(let a, let b):
      path(a)
      path(b)
    case .textContains(let value, let text, let count):
      path(value)
      if text.isEmpty { errors.append("\(label): text must not be empty.") }
      if count < 0 { errors.append("\(label): count must not be negative.") }
    case .hubConfigValid(let value, let prefix):
      path(value)
      if !DatastorePath.isNormalised(prefix) {
        errors.append("\(label): prefix must be absolute and normalised.")
      }
    case .prefixLocates(let value, let roots, let resolved):
      path(value)
      if roots.isEmpty { errors.append("\(label): allowedRoots must not be empty.") }
      for root in roots where !DatastorePath.isNormalised(root) {
        errors.append("\(label): allowed root is not absolute and normalised: \(root)")
      }
      if !DatastorePath.isNormalised(resolved) {
        errors.append("\(label): resolved must be absolute and normalised.")
      }
    case .prefixNotInUse(let value, let aliases):
      path(value)
      for alias in aliases where !DatastorePath.isNormalised(alias) {
        errors.append("\(label): alias is not absolute and normalised: \(alias)")
      }
    case .quietFor(let value, let minutes):
      path(value)
      if minutes < 1 { errors.append("\(label): minutes must be at least 1.") }
    case .noWineProcess:
      break
    }
  }
}
