import Darwin
import Foundation

/// How one check came out.
package enum DatastoreCheckStatus: String, Codable, Equatable, Sendable {
  case pass
  case fail
  /// The check cannot be decided without the real filesystem (only in a simulation).
  case skip
}

/// The result of one check or implicit condition.
package struct DatastoreCheckOutcome: Codable, Equatable, Sendable {
  package var name: String
  package var status: DatastoreCheckStatus
  package var detail: String

  package init(name: String, status: DatastoreCheckStatus, detail: String = "") {
    self.name = name
    self.status = status
    self.detail = detail
  }

  /// False only for a failure; a skipped check does not block a step.
  package var isAcceptable: Bool { status != .fail }
}

/// `text` in double quotes, exactly as its bytes read (a backslash stays one backslash); text
/// with a control character falls back to Swift's escaped form so it stays on one line.
private func quoted(_ text: String) -> String {
  text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    ? text.debugDescription : "\"" + text + "\""
}

extension DatastoreCheck {
  /// A one-line description for reports.
  package var summary: String {
    switch self {
    case .exists(let path, let kind): "exists \(kind.rawValue) \(path)"
    case .absent(let path): "absent \(path)"
    case .notSymlink(let path): "notSymlink \(path)"
    case .symlinkTarget(let path, let target): "symlinkTarget \(path) == \(target)"
    case .sameFile(let a, let b): "sameFile \(a) and \(b)"
    case .textContains(let path, let text, let count):
      "textContains \(path) \(quoted(text)) x\(count)"
    case .vdfParses(let path): "vdfParses \(path)"
    case .shellSyntax(let path): "shellSyntax \(path)"
    case .hubConfigValid(let path, let prefix): "hubConfigValid \(path) prefix \(prefix)"
    case .prefixLocates(let path, _, let resolved): "prefixLocates \(path) -> \(resolved)"
    case .noWineProcess: "noWineProcess"
    case .noOpenFiles(let path): "noOpenFiles \(path)"
    case .prefixNotInUse(let path, _): "prefixNotInUse \(path)"
    case .quietFor(let path, let minutes): "quietFor \(path) \(minutes) min"
    }
  }
}

extension DatastoreOp {
  /// A one-line description for reports and the journal.
  package var summary: String {
    switch self {
    case .mkdir(let path, let mode): "mkdir \(path) mode 0\(String(mode, radix: 8))"
    case .rename(let from, let to): "rename \(from) -> \(to)"
    case .symlink(let path, let target): "symlink \(path) -> \(target)"
    case .replaceSymlink(let path, let target, let expected):
      "replaceSymlink \(path) -> \(target) (now \(expected))"
    case .backup(let path): "backup \(path)"
    case .rewriteText(let path, let find, let replace, let count):
      "rewriteText \(path): \(quoted(find)) -> \(quoted(replace)) x\(count)"
    case .writeHubConfig(let spec): "writeHubConfig \(spec.path) prefix \(spec.prefix)"
    }
  }
}

/// Where Wine keeps the socket of a prefix's server.
package enum DatastoreWineSocket {
  /// `server-<dev>-<ino>` with both numbers in hex, `st_dev` sign-extended to 64 bits exactly as
  /// Wine's `(unsigned long long)st.st_dev` does (a device number with the top bit set prints as
  /// `ffffffff...`). `device` is the sign-extended value `DatastoreNodeInfo` holds.
  package static func serverDirectoryName(device: Int64, inode: UInt64) -> String {
    "server-\(String(UInt64(bitPattern: device), radix: 16))-\(String(inode, radix: 16))"
  }
}

/// The parts of the machine a check reads besides the filesystem and the probe: the clock, the
/// user id and the folders Wine keeps its server sockets in. Injected so tests control them.
package struct DatastoreCheckEnvironment: Sendable {
  package var now: Date
  package var userID: UInt32
  /// The folders that hold `.wine-<uid>/server-<dev>-<ino>/socket` directories.
  package var socketRoots: [String]

  package init(now: Date, userID: UInt32, socketRoots: [String]) {
    self.now = now
    self.userID = userID
    self.socketRoots = socketRoots
  }

  /// The real clock, user and temporary folders.
  package static var live: DatastoreCheckEnvironment {
    DatastoreCheckEnvironment(
      now: Date(), userID: UInt32(getuid()), socketRoots: ["/tmp", "/private/tmp"])
  }
}

/// Evaluates a plan's checks against a filesystem view and a probe snapshot.
///
/// Evaluation never throws and never writes: a failure to look becomes a failed check.
package struct DatastoreCheckEvaluator: Sendable {
  package let fileSystem: any DatastoreFileSystem
  package let snapshot: DatastoreProbeSnapshot
  package let environment: DatastoreCheckEnvironment

  package init(
    fileSystem: any DatastoreFileSystem, snapshot: DatastoreProbeSnapshot,
    environment: DatastoreCheckEnvironment = .live
  ) {
    self.fileSystem = fileSystem
    self.snapshot = snapshot
    self.environment = environment
  }

  private enum Verdict {
    case pass(String)
    case fail(String)
    case skip(String)
  }

  package func evaluate(_ check: DatastoreCheck) -> DatastoreCheckOutcome {
    let verdict: Verdict
    do throws(HubError) {
      verdict = try decide(check)
    } catch {
      verdict = .fail(text(of: error))
    }
    switch verdict {
    case .pass(let detail): return .init(name: check.summary, status: .pass, detail: detail)
    case .fail(let detail): return .init(name: check.summary, status: .fail, detail: detail)
    case .skip(let detail): return .init(name: check.summary, status: .skip, detail: detail)
    }
  }

  private func describe(_ info: DatastoreNodeInfo?) -> String {
    info.map { "is a \($0.kind.rawValue)" } ?? "does not exist"
  }

  private func decide(_ check: DatastoreCheck) throws(HubError) -> Verdict {
    switch check {
    case .exists(let path, let kind):
      switch kind {
      case .any:
        let info = try fileSystem.lstatNode(path)
        return info == nil ? .fail("does not exist") : .pass("")
      case .symlink:
        let info = try fileSystem.lstatNode(path)
        return info?.kind == .symlink ? .pass("") : .fail(describe(info))
      case .directory, .file:
        let info = try fileSystem.statNode(path)
        let wanted: DatastoreNodeKind = kind == .directory ? .directory : .file
        return info?.kind == wanted ? .pass("") : .fail(describe(info))
      }

    case .absent(let path):
      let info = try fileSystem.lstatNode(path)
      return info == nil ? .pass("") : .fail("exists and \(describe(info))")

    case .notSymlink(let path):
      guard let info = try fileSystem.lstatNode(path) else { return .fail("does not exist") }
      return info.kind == .symlink ? .fail("is a symlink") : .pass("is a \(info.kind.rawValue)")

    case .symlinkTarget(let path, let target):
      guard let actual = try fileSystem.linkTarget(path) else {
        return .fail("is not a symlink")
      }
      return actual == target ? .pass("") : .fail("points to \(actual)")

    case .sameFile(let a, let b):
      guard let first = try fileSystem.statNode(a) else { return .fail("\(a) does not exist") }
      guard let second = try fileSystem.statNode(b) else { return .fail("\(b) does not exist") }
      let same = first.device == second.device && first.inode == second.inode
      return same
        ? .pass("dev \(first.device) ino \(first.inode)")
        : .fail("dev/ino \(first.device)/\(first.inode) vs \(second.device)/\(second.inode)")

    case .textContains(let path, let text, let count):
      guard let data = try fileSystem.contents(of: path, limit: DatastoreIO.contentLimit) else {
        return .fail("does not exist")
      }
      let found = DatastoreIO.occurrences(of: Data(text.utf8), in: data)
      return found == count ? .pass("found \(found)") : .fail("found \(found), expected \(count)")

    case .vdfParses(let path):
      guard let data = try fileSystem.contents(of: path, limit: DatastoreIO.contentLimit) else {
        return .fail("does not exist")
      }
      guard let content = String(data: data, encoding: .utf8) else {
        return .fail("is not UTF-8")
      }
      return GameCatalog.isWellFormedValveText(content)
        ? .pass("") : .fail("is not well-formed Valve text")

    case .shellSyntax(let path):
      return try shellSyntax(path)

    case .hubConfigValid(let path, let prefix):
      guard let real = try fileSystem.realFilePath(path), try fileSystem.lstatNode(path) != nil
      else {
        return fileSystem.isPristine
          ? .fail("does not exist") : .skip("the file exists only after the step runs")
      }
      let config = try HubConfig.read(URL(fileURLWithPath: real))
      return config.prefix == prefix ? .pass("") : .fail("prefix is \(config.prefix)")

    case .prefixLocates(let path, let roots, let resolved):
      guard fileSystem.isPristine else {
        return .skip("needs the real filesystem; checked after the step runs")
      }
      let located = try SharedPrefix.locate(
        path, allowedRoots: roots.map { URL(fileURLWithPath: $0, isDirectory: true) })
      return located.resolved.path == resolved
        ? .pass("") : .fail("resolves to \(located.resolved.path)")

    case .noWineProcess:
      let lines = try snapshot.wineProcessLines()
      return lines.isEmpty ? .pass("") : .fail(Self.list(lines, noun: "Wine process"))

    case .noOpenFiles(let path):
      var paths = [path]
      if let canonical = try fileSystem.canonicalDirectory(path), canonical != path {
        paths.append(canonical)
      }
      let open = try snapshot.openFiles(under: paths)
      return open.isEmpty ? .pass("") : .fail(Self.list(open, noun: "open file"))

    case .prefixNotInUse(let path, let aliases):
      return try prefixNotInUse(path, aliases: aliases)

    case .quietFor(let path, let minutes):
      return try quietFor(path, minutes: minutes)
    }
  }

  /// The prefix is idle when nothing has a file open in it, nothing holds its Wine server socket,
  /// and no command line names it. Wine processes of other prefixes do not count.
  private func prefixNotInUse(_ path: String, aliases: [String]) throws(HubError) -> Verdict {
    guard let real = try fileSystem.canonicalDirectory(path),
      let info = try fileSystem.statNode(real)
    else {
      return .fail("\(path) does not exist")
    }
    var forms: [String] = []
    for form in [real, path] + aliases where !forms.contains(form) { forms.append(form) }
    for alias in aliases {
      if let canonical = try fileSystem.canonicalDirectory(alias), !forms.contains(canonical) {
        forms.append(canonical)
      }
    }
    var problems: [String] = []
    var notes: [String] = []

    let open = try snapshot.openFiles(under: forms)
    if !open.isEmpty { problems.append(Self.list(open, noun: "open file")) }

    // Wine's server directory is named after the prefix directory's device and inode.
    let serverName = DatastoreWineSocket.serverDirectoryName(
      device: info.device, inode: info.inode)
    var serverDirectories: [String] = []
    for root in environment.socketRoots {
      let directory = "\(root)/.wine-\(environment.userID)/\(serverName)"
      if try fileSystem.lstatNode(directory + "/socket") != nil {
        serverDirectories.append(directory)
      }
    }
    if !serverDirectories.isEmpty {
      let holders = try snapshot.openFiles(under: serverDirectories)
      if holders.isEmpty {
        notes.append(
          "stale Wine socket with no holder in \(serverDirectories.joined(separator: ", "))")
      } else {
        problems.append(Self.list(holders, noun: "open handle on the Wine server socket"))
      }
    }

    let lines = try snapshot.commandLines().filter { line in forms.contains { line.contains($0) } }
    if !lines.isEmpty { problems.append(Self.list(lines, noun: "process naming the prefix")) }

    if problems.isEmpty {
      return .pass(
        notes.isEmpty ? "dev \(info.device) ino \(info.inode)" : notes.joined(separator: "; "))
    }
    return .fail(problems.joined(separator: "\n  "))
  }

  /// Walks `path` with `lstat` (never following a symlink) for the newest mtime or ctime.
  private func quietFor(_ path: String, minutes: Int) throws(HubError) -> Verdict {
    guard let root = try fileSystem.lstatNode(path) else { return .fail("\(path) does not exist") }
    var newestPath = path
    var newest = max(root.modified, root.changed)
    var entries = 1
    var pending: [String] = root.kind == .directory ? [path] : []
    while let directory = pending.popLast() {
      for name in try fileSystem.childNames(of: directory) ?? [] {
        let child = DatastorePath.join(directory, name)
        guard let info = try fileSystem.lstatNode(child) else { continue }
        entries += 1
        let time = max(info.modified, info.changed)
        if time > newest {
          newest = time
          newestPath = child
        }
        if info.kind == .directory { pending.append(child) }
      }
    }
    let age = environment.now.timeIntervalSince1970 - newest
    let report = "newest of \(entries) entries: \(newestPath), changed \(Self.duration(age)) ago"
    return age >= Double(minutes) * 60
      ? .pass(report) : .fail("\(report); needs \(minutes) min of quiet")
  }

  private static func duration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m \(total % 60)s" }
    return "\(total / 3600)h \((total % 3600) / 60)m"
  }

  private func shellSyntax(_ path: String) throws(HubError) -> Verdict {
    guard try fileSystem.lstatNode(path) != nil else { return .fail("does not exist") }
    let arguments: [String]
    if let real = try fileSystem.realFilePath(path) {
      arguments = ["-n", real]
    } else {
      guard let data = try fileSystem.contents(of: path, limit: DatastoreIO.contentLimit),
        let script = String(data: data, encoding: .utf8)
      else {
        return .fail("is not readable text")
      }
      arguments = ["-n", "-c", script]
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = arguments
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw .io("Cannot run /bin/bash: \(error.localizedDescription)")
    }
    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return process.terminationStatus == 0
      ? .pass("") : .fail("bash -n exited \(process.terminationStatus): \(message)")
  }

  /// At most five lines of `items`, with a count.
  private static func list(_ items: [String], noun: String) -> String {
    let shown = items.prefix(5).joined(separator: "\n    ")
    let more = items.count > 5 ? "\n    ... and \(items.count - 5) more" : ""
    return "\(items.count) \(noun)\(items.count == 1 ? "" : "s"):\n    \(shown)\(more)"
  }
}
