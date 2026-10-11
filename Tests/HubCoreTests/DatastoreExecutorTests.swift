import Darwin
import Foundation
import Testing

@testable import HubCore

/// A probe that answers from fixed lists, or fails.
private struct FakeProbe: DatastoreProbe {
  var commands: [String] = []
  var openFiles: [String] = []
  var failure: HubError?

  func processCommandLines() throws(HubError) -> [String] {
    if let failure { throw failure }
    return commands
  }

  func openFilePaths() throws(HubError) -> [String] {
    if let failure { throw failure }
    return openFiles
  }
}

/// A temporary volume laid out like the real one: a protected `Bundles` folder and a `Backups`
/// folder that will hold the plan's backup directory.
private final class Sandbox {
  let root: String
  var backupDir: String { root + "/Backups/run" }
  var journal: String { backupDir + "/journal.jsonl" }
  private let fileManager = FileManager.default

  init() throws {
    let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(resolved) }
    root = String(cString: resolved) + "/ds-\(UUID().uuidString)"
    for directory in [root, root + "/Bundles", root + "/Backups"] {
      try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
  }

  deinit { try? fileManager.removeItem(atPath: root) }

  func path(_ relative: String) -> String { root + "/" + relative }

  func write(_ relative: String, _ text: String, mode: Int = 0o644) throws {
    let full = path(relative)
    try fileManager.createDirectory(
      atPath: DatastorePath.parent(of: full), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: full))
    try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: full)
  }

  func makeDirectory(_ relative: String) throws {
    try fileManager.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
  }

  func symlink(_ relative: String, to target: String) throws {
    try fileManager.createSymbolicLink(atPath: path(relative), withDestinationPath: target)
  }

  func read(_ relative: String) throws -> String {
    String(decoding: try Data(contentsOf: URL(fileURLWithPath: path(relative))), as: UTF8.self)
  }

  func inode(_ relative: String) -> UInt64 {
    var info = stat()
    return lstat(path(relative), &info) == 0 ? UInt64(info.st_ino) : 0
  }

  func exists(_ relative: String) -> Bool {
    var info = stat()
    return lstat(path(relative), &info) == 0
  }

  func names(_ relative: String = "") -> [String] {
    ((try? fileManager.contentsOfDirectory(atPath: relative.isEmpty ? root : path(relative))) ?? [])
      .sorted()
  }

  /// Every node under the root with its kind, permissions and content hash or link target.
  func tree(excludingBackups: Bool = false) -> [String: String] {
    var result: [String: String] = [:]
    var pending = [root]
    while let directory = pending.popLast() {
      for name in (try? fileManager.contentsOfDirectory(atPath: directory)) ?? [] {
        let full = directory + "/" + name
        if excludingBackups && full == backupDir { continue }
        guard let attributes = try? fileManager.attributesOfItem(atPath: full) else { continue }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory:
          result[full] = "d \(mode)"
          pending.append(full)
        case .typeSymbolicLink:
          let target = (try? fileManager.destinationOfSymbolicLink(atPath: full)) ?? "?"
          result[full] = "l \(target)"
        default:
          let hash = (try? DatastoreIO.sha256Hex(fileAt: full)) ?? nil
          result[full] = "f \(mode) \(hash ?? "?")"
        }
      }
    }
    return result
  }

  /// The plan: a first step that creates the backup directory, then `steps`.
  func plan(protecting extra: [String] = [], _ steps: DatastoreStep...) -> DatastorePlan {
    let plan = DatastorePlan(
      id: "test-plan", volume: root, protected: [root + "/Bundles"] + extra, allowedRoots: [root],
      backupDir: backupDir, journal: journal,
      steps: [
        DatastoreStep(
          id: "S01-backup", title: "Create the backup folder",
          operations: [.mkdir(path: backupDir, mode: 0o755)])
      ] + steps)
    #expect(plan.validationErrors() == [])
    return plan
  }

  func executor(
    _ plan: DatastorePlan, probe: FakeProbe = FakeProbe(), now: Date = Date(),
    faults: DatastoreFaults = DatastoreFaults()
  ) -> DatastoreExecutor {
    DatastoreExecutor(
      plan: plan, probe: probe,
      environment: DatastoreCheckEnvironment(
        now: now, userID: 501, socketRoots: [root + "/sock"]),
      processID: 4242, faults: faults)
  }
}

private func step(
  _ operations: [DatastoreOp], id: String = "S02-test", noWine: Bool = false,
  pre: [DatastoreCheck] = [], verify: [DatastoreCheck] = []
) -> DatastoreStep {
  DatastoreStep(
    id: id, title: "Test step \(id)", requiresNoWine: noWine, preconditions: pre,
    operations: operations, verify: verify)
}

@Suite struct DatastoreExecutorTests {
  // MARK: - Rename

  @Test func renameKeepsTheInodeAndMeasuresBothSides() throws {
    let box = try Sandbox()
    try box.write("src/a.txt", "hello")
    try box.write("src/sub/b.txt", "abc")
    try box.symlink("src/link", to: "a.txt")
    let inode = box.inode("src")
    let plan = box.plan(step([.rename(from: box.path("src"), to: box.path("dst"))]))
    let executor = box.executor(plan)

    #expect(try executor.apply(stepID: "S01-backup").exitCode == 0)
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .applied)
    let operation = report.steps[0].operations[0]
    #expect(operation.before?.entries == 4)
    #expect(operation.before?.bytes == 8)
    #expect(operation.before?.symlinks == 1)
    let before = try #require(operation.before)
    #expect(operation.after?.sameContent(as: before) == true)
    #expect(operation.after?.inode == before.inode)
    #expect(box.inode("dst") == inode)
    // The journal records the start (with the measured source), the move, then the measurement.
    let events = try DatastoreJournal.read(box.journal, planID: plan.id).filter {
      $0.step == "S02-test"
    }
    #expect(
      events.map(\.event) == [.stepStarted, .opStarted, .opApplied, .opMeasured, .stepApplied])
    #expect(events[1].before == operation.before)
    #expect(events[2].after == nil)
    #expect(events[3].after == operation.after)
    #expect(!box.exists("src"))
    #expect(try box.read("dst/sub/b.txt") == "abc")
  }

  @Test func renameRefusesAnExistingDestinationASymlinkSourceAndOpenFiles() throws {
    let box = try Sandbox()
    try box.write("src/a.txt", "1")
    try box.write("taken/b.txt", "2")
    try box.makeDirectory("real")
    try box.symlink("linked", to: "real")
    let first = box.executor(box.plan(step([.mkdir(path: box.path("unused"), mode: 0o755)])))
    _ = try first.apply(stepID: "S01-backup")
    let before = box.tree(excludingBackups: true)

    let taken = box.plan(step([.rename(from: box.path("src"), to: box.path("taken"))]))
    let report = try box.executor(taken).apply(stepID: "S02-test")
    #expect(report.steps[0].result == .preconditionFailed)
    #expect(report.exitCode == 2)
    #expect(box.tree(excludingBackups: true) == before)

    let link = box.plan(
      step([.rename(from: box.path("linked"), to: box.path("moved"))]))
    let linkReport = try box.executor(link).apply(stepID: "S02-test")
    #expect(linkReport.steps[0].result == .preconditionFailed)
    #expect(
      linkReport.steps[0].preconditions.contains {
        $0.status == .fail && $0.name.contains("not a symlink")
      })

    let open = box.plan(
      step([.rename(from: box.path("src"), to: box.path("elsewhere"))]))
    let openReport = try box.executor(
      open, probe: FakeProbe(openFiles: [box.path("src/a.txt")])
    ).apply(stepID: "S02-test")
    #expect(openReport.steps[0].result == .preconditionFailed)
    #expect(
      openReport.steps[0].preconditions.contains {
        $0.status == .fail && $0.name.contains("no open file")
      })
    #expect(box.tree(excludingBackups: true) == before)
  }

  @Test func requiresNoWineRefusesAWineProcessAndIgnoresOthers() throws {
    let box = try Sandbox()
    let plan = box.plan(
      step([.mkdir(path: box.path("made"), mode: 0o755)], noWine: true))
    for line in [
      "/Applications/Wine/bin/wine64 something", "wineserver -p", "/x/wine-preloader /y",
      "/opt/app/Game.EXE --flag",
    ] {
      let executor = box.executor(plan, probe: FakeProbe(commands: [line]))
      _ = try executor.apply(stepID: "S01-backup")
      let report = try executor.apply(stepID: "S02-test")
      #expect(report.steps[0].result == .preconditionFailed, "\(line)")
      #expect(!box.exists("made"))
      try FileManager.default.removeItem(atPath: box.backupDir)
    }
    let quiet = box.executor(plan, probe: FakeProbe(commands: ["/usr/bin/ssh host", "vim x"]))
    _ = try quiet.apply(stepID: "S01-backup")
    #expect(try quiet.apply(stepID: "S02-test").steps[0].result == .applied)
    #expect(box.exists("made"))
  }

  @Test func aCaseOnlyRenameIsAllowedAndACollidingMkdirIsRefused() throws {
    let box = try Sandbox()
    try box.write("stuff/a.txt", "x")
    try box.makeDirectory("foo")
    let renamePlan = box.plan(
      step([.rename(from: box.path("stuff"), to: box.path("Stuff"))]))
    let executor = box.executor(renamePlan)
    _ = try executor.apply(stepID: "S01-backup")
    #expect(try executor.apply(stepID: "S02-test").steps[0].result == .applied)
    #expect(box.names().contains("Stuff"))
    #expect(!box.names().contains("stuff"))
    #expect(try box.read("Stuff/a.txt") == "x")

    let collide = box.plan(step([.mkdir(path: box.path("Foo"), mode: 0o755)]))
    let colliding = box.executor(collide)
    try FileManager.default.removeItem(atPath: box.backupDir)
    _ = try colliding.apply(stepID: "S01-backup")
    let report = try colliding.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .preconditionFailed)
    #expect(box.names().filter { $0.lowercased() == "foo" } == ["foo"])
  }

  // MARK: - Symlinks

  @Test func aRelativeSymlinkResolvesAndADanglingOneIsUndone() throws {
    let box = try Sandbox()
    try box.makeDirectory("real")
    let good = box.plan(
      step(
        [.symlink(path: box.path("link"), target: "real")],
        verify: [
          .symlinkTarget(path: box.path("link"), target: "real"),
          .exists(path: box.path("link"), kind: .directory),
        ]))
    let executor = box.executor(good)
    _ = try executor.apply(stepID: "S01-backup")
    #expect(try executor.apply(stepID: "S02-test").steps[0].result == .applied)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.path("link")) == "real")

    let dangling = box.plan(step([.symlink(path: box.path("bad"), target: "missing")]))
    let danglingExecutor = box.executor(dangling)
    try FileManager.default.removeItem(atPath: box.backupDir)
    _ = try danglingExecutor.apply(stepID: "S01-backup")
    let report = try danglingExecutor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .verifyFailed)
    #expect(report.exitCode == 4)
    #expect(!box.exists("bad"))
  }

  @Test func replaceSymlinkChecksTheExpectedTargetAndLeavesNoTemporaryLink() throws {
    let box = try Sandbox()
    try box.makeDirectory("one")
    try box.makeDirectory("two")
    try box.symlink("l", to: "one")
    let wrong = box.plan(
      step([.replaceSymlink(path: box.path("l"), target: "two", expectedTarget: "other")]))
    let wrongExecutor = box.executor(wrong)
    _ = try wrongExecutor.apply(stepID: "S01-backup")
    let refused = try wrongExecutor.apply(stepID: "S02-test")
    #expect(refused.steps[0].result == .preconditionFailed)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.path("l")) == "one")

    let right = box.plan(
      step([.replaceSymlink(path: box.path("l"), target: "two", expectedTarget: "one")]))
    let rightExecutor = box.executor(right)
    try FileManager.default.removeItem(atPath: box.backupDir)
    _ = try rightExecutor.apply(stepID: "S01-backup")
    #expect(try rightExecutor.apply(stepID: "S02-test").steps[0].result == .applied)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.path("l")) == "two")
    #expect(!box.names().contains { $0.contains("datastore-tmp") })
  }

  // MARK: - Backup and rewrite

  @Test func backupWritesTheSumsFileAndIsIdempotent() throws {
    let box = try Sandbox()
    try box.write("f.txt", "data")
    try box.symlink("s", to: "f.txt")
    let backups: [DatastoreOp] = [.backup(path: box.path("f.txt")), .backup(path: box.path("s"))]
    let plan = box.plan(step(backups, id: "S02-first"), step(backups, id: "S03-again"))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    #expect(try executor.apply(stepID: "S02-first").steps[0].result == .applied)

    let sha = DatastoreIO.sha256Hex(Data("data".utf8))
    let sums = try String(contentsOfFile: box.backupDir + "/SHA256SUMS", encoding: .utf8)
    #expect(sums == "\(sha)  \(box.path("f.txt"))\n")
    let copy = box.backupDir + "/files" + box.path("f.txt")
    #expect(try String(contentsOfFile: copy, encoding: .utf8) == "data")
    let table = try String(contentsOfFile: box.backupDir + "/symlinks.tsv", encoding: .utf8)
    #expect(table == "\(box.path("s"))\tf.txt\n")

    #expect(try executor.apply(stepID: "S03-again").steps[0].result == .applied)
    #expect(try String(contentsOfFile: box.backupDir + "/SHA256SUMS", encoding: .utf8) == sums)
    #expect(try String(contentsOfFile: box.backupDir + "/symlinks.tsv", encoding: .utf8) == table)
  }

  @Test func backupRefusesWhenADifferentBackupExists() throws {
    let box = try Sandbox()
    try box.write("f.txt", "data")
    let backup: [DatastoreOp] = [.backup(path: box.path("f.txt"))]
    let plan = box.plan(step(backup, id: "S02-first"), step(backup, id: "S03-again"))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    _ = try executor.apply(stepID: "S02-first")
    try box.write("f.txt", "changed")
    let report = try executor.apply(stepID: "S03-again")
    #expect(report.steps[0].result == .preconditionFailed)
    #expect(
      try String(contentsOfFile: box.backupDir + "/files" + box.path("f.txt"), encoding: .utf8)
        == "data")
  }

  @Test func rewriteTextReplacesLiteralBytesAndKeepsTheMode() throws {
    let box = try Sandbox()
    try box.write("run.sh", "a=1\nb=1\n$HOME \\\\n\n", mode: 0o755)
    let path = box.path("run.sh")
    let plan = box.plan(
      step(
        [
          .backup(path: path),
          .rewriteText(path: path, find: "=1", replace: "=2", expectedCount: 2),
          .rewriteText(path: path, find: "$HOME \\\\n", replace: "$HOME/x", expectedCount: 1),
        ],
        verify: [.textContains(path: path, text: "=2", count: 2), .shellSyntax(path: path)]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .applied)
    #expect(try box.read("run.sh") == "a=2\nb=2\n$HOME/x\n")
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
  }

  @Test func aRewriteCountMismatchChangesNothing() throws {
    let box = try Sandbox()
    try box.write("f.txt", "x y x")
    let path = box.path("f.txt")
    let plan = box.plan(
      step(
        [
          .backup(path: path),
          .rewriteText(path: path, find: "x", replace: "z", expectedCount: 3),
        ]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    let before = box.tree(excludingBackups: true)
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .preconditionFailed)
    #expect(box.tree(excludingBackups: true) == before)
    #expect(!FileManager.default.fileExists(atPath: box.backupDir + "/SHA256SUMS"))
  }

  // MARK: - Undo, rollback and order

  private func bigStep(_ box: Sandbox, verify: [DatastoreCheck]) -> DatastoreStep {
    let file = box.path("f.txt")
    return step(
      [
        .mkdir(path: box.path("made"), mode: 0o700),
        .rename(from: box.path("src"), to: box.path("dst")),
        .symlink(path: box.path("lnk"), target: "dst"),
        .backup(path: file),
        .rewriteText(path: file, find: "old", replace: "new", expectedCount: 1),
      ], verify: verify)
  }

  private func prepareBigTree(_ box: Sandbox) throws {
    try box.write("src/a.txt", "payload")
    try box.write("src/sub/b.bin", "0123456789")
    try box.write("f.txt", "old text\n", mode: 0o640)
  }

  @Test func aFailingVerifyUndoesEveryOperationByteForByte() throws {
    let box = try Sandbox()
    try prepareBigTree(box)
    let plan = box.plan(
      bigStep(box, verify: [.exists(path: box.path("missing"), kind: .file)]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    let before = box.tree(excludingBackups: true)
    let inode = box.inode("src")

    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .verifyFailed)
    #expect(report.exitCode == 4)
    #expect(box.tree(excludingBackups: true) == before)
    #expect(box.inode("src") == inode)
    #expect(report.steps[0].operations.map(\.status).filter { $0 == .undone }.count == 5)

    let events = try DatastoreJournal.read(box.journal, planID: plan.id)
    let kinds = events.filter { $0.step == "S02-test" }.map(\.event)
    #expect(kinds.contains(.verifyFailed))
    #expect(kinds.last == .stepRolledBack)
    #expect(try executor.status().map(\.state) == [.applied, .rolledBack])
  }

  @Test func rollbackRestoresTheDiskAndTheFirstStepCannotBeRolledBack() throws {
    let box = try Sandbox()
    try prepareBigTree(box)
    let plan = box.plan(
      bigStep(box, verify: [.textContains(path: box.path("f.txt"), text: "new", count: 1)]),
      step([.mkdir(path: box.path("later"), mode: 0o755)], id: "S03-later"))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    let before = box.tree(excludingBackups: true)

    #expect(try executor.apply(stepID: "S02-test").steps[0].result == .applied)
    #expect(try box.read("f.txt") == "new text\n")
    #expect(try executor.verify(stepID: "S02-test").steps[0].result == .verified)

    #expect(try executor.apply(stepID: "S03-later").steps[0].result == .applied)
    let blocked = try executor.rollback(stepID: "S02-test")
    #expect(blocked.steps[0].result == .refused)
    #expect(blocked.exitCode == 2)
    #expect(try executor.rollback(stepID: "S01-backup").steps[0].result == .refused)

    #expect(try executor.rollback(stepID: "S03-later").steps[0].result == .rolledBack)
    let rolled = try executor.rollback(stepID: "S02-test")
    #expect(rolled.steps[0].result == .rolledBack)
    #expect(rolled.exitCode == 0)
    #expect(box.tree(excludingBackups: true) == before)
    #expect(try executor.status().map(\.state) == [.applied, .rolledBack, .rolledBack])

    // A rolled-back step can be applied again.
    #expect(try executor.apply(stepID: "S02-test").steps[0].result == .applied)
  }

  @Test func stepsRunOnlyInListedOrder() throws {
    let box = try Sandbox()
    let plan = box.plan(
      step([.mkdir(path: box.path("a"), mode: 0o755)], id: "S02-a"),
      step([.mkdir(path: box.path("b"), mode: 0o755)], id: "S03-b"))
    let executor = box.executor(plan)
    let early = try executor.apply(stepID: "S03-b")
    #expect(early.steps[0].result == .refused)
    #expect(early.steps[0].message?.contains("S01-backup") == true)
    #expect(!box.exists("b"))
    _ = try executor.apply(stepID: "S01-backup")
    #expect(try executor.apply(stepID: "S01-backup").steps[0].result == .refused)
    #expect(throws: HubError.self) { try executor.apply(stepID: "S99-none") }
  }

  @Test func theJournalHoldsDecodableLines() throws {
    let box = try Sandbox()
    let plan = box.plan(step([.mkdir(path: box.path("a"), mode: 0o755)]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    _ = try executor.apply(stepID: "S02-test")

    let raw = try String(contentsOfFile: box.journal, encoding: .utf8)
    let lines = raw.split(separator: "\n")
    #expect(lines.count == 8)
    let decoder = JSONDecoder()
    let events = try lines.map {
      try decoder.decode(DatastoreJournalEvent.self, from: Data($0.utf8))
    }
    #expect(
      events.map(\.event) == [
        .stepStarted, .opStarted, .opApplied, .stepApplied,
        .stepStarted, .opStarted, .opApplied, .stepApplied,
      ])
    #expect(
      events.map(\.step) == Array(repeating: "S01-backup", count: 4)
        + Array(repeating: "S02-test", count: 4))
    #expect(events[5].op == 1)
    #expect(events[5].summary?.hasPrefix("mkdir") == true)
    #expect(try DatastoreJournal.read(box.journal, planID: plan.id).count == 8)
    #expect(throws: HubError.self) { try DatastoreJournal.read(box.journal, planID: "another") }
  }

  @Test func aMutationThatResolvesIntoAProtectedPathIsRefused() throws {
    let box = try Sandbox()
    try box.symlink("alias", to: "Bundles")
    let plan = box.plan(step([.mkdir(path: box.path("alias/new"), mode: 0o755)]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .preconditionFailed)
    #expect(box.names("Bundles").isEmpty)
  }

  // MARK: - Interruptions, protected paths, leftovers

  private func interruptedBox(
    faults: DatastoreFaults
  ) throws -> (Sandbox, DatastorePlan, [String: String]) {
    let box = try Sandbox()
    try box.write("src/a.txt", "payload")
    let plan = box.plan(
      step([
        .mkdir(path: box.path("made"), mode: 0o755),
        .rename(from: box.path("src"), to: box.path("dst")),
      ]))
    _ = try box.executor(plan).apply(stepID: "S01-backup")
    let before = box.tree(excludingBackups: true)
    #expect(throws: HubError.self) {
      try box.executor(plan, faults: faults).apply(stepID: "S02-test")
    }
    #expect(!box.exists("src"))
    #expect(box.exists("dst"))
    return (box, plan, before)
  }

  @Test func aRunInterruptedBeforeTheRenameWasMeasuredIsRolledBack() throws {
    let (box, plan, before) = try interruptedBox(
      faults: DatastoreFaults(interruptBeforeMeasure: true))
    let executor = box.executor(plan)
    #expect(try executor.status().map(\.state) == [.applied, .interrupted])
    let events = try DatastoreJournal.read(box.journal, planID: plan.id)
    let run = DatastoreJournal.latestRun(step: "S02-test", events: events)
    #expect(run.outstanding.map(\.op) == [1, 2])
    #expect(run.unresolved.isEmpty)

    let report = try executor.rollback(stepID: "S02-test")
    #expect(report.steps[0].result == .rolledBack)
    #expect(box.tree(excludingBackups: true) == before)
    #expect(try executor.status().map(\.state) == [.applied, .rolledBack])
  }

  @Test func aRenameInterruptedBeforeItWasJournaledIsDecidedFromTheDisk() throws {
    let (box, plan, before) = try interruptedBox(
      faults: DatastoreFaults(interruptAfterRenameSyscall: true))
    let executor = box.executor(plan)
    let events = try DatastoreJournal.read(box.journal, planID: plan.id)
    let run = DatastoreJournal.latestRun(step: "S02-test", events: events)
    #expect(run.outstanding.map(\.op) == [1])
    #expect(run.unresolved.map(\.op) == [2])

    let report = try executor.rollback(stepID: "S02-test")
    #expect(report.steps[0].result == .rolledBack, "\(DatastoreReportRenderer.text(report))")
    #expect(box.tree(excludingBackups: true) == before)
  }

  @Test func aRenameThatNeverHappenedIsNotUndoneAndAnAmbiguousOneIsRefused() throws {
    let box = try Sandbox()
    try box.write("src/a.txt", "payload")
    let rename = DatastoreOp.rename(from: box.path("src"), to: box.path("dst"))
    let plan = box.plan(
      step([rename]), step([.mkdir(path: box.path("m"), mode: 0o755)], id: "S03-m"))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    let measured = try #require(try RealDatastoreFileSystem().measure(box.path("src")))

    func journalStart(_ step: String, op: Int, summary: String, before: DatastoreMeasurement?)
      throws
    {
      try DatastoreJournal.append(
        [
          DatastoreJournalEvent(plan: plan.id, event: .stepStarted, step: step),
          DatastoreJournalEvent(
            plan: plan.id, event: .opStarted, step: step, op: op, summary: summary, before: before),
        ], to: box.journal)
    }
    // Started, and the source is still there: it did not happen.
    try journalStart("S02-test", op: 1, summary: rename.summary, before: measured)
    let before = box.tree(excludingBackups: true)
    let undone = try executor.rollback(stepID: "S02-test")
    #expect(undone.steps[0].result == .rolledBack)
    #expect(box.tree(excludingBackups: true) == before)

    // Started, with the source and the destination both present: the disk cannot settle it.
    try box.write("dst/other.txt", "x")
    try journalStart("S02-test", op: 1, summary: rename.summary, before: measured)
    let refused = try executor.rollback(stepID: "S02-test")
    #expect(refused.steps[0].result == .refused)
    #expect(refused.steps[0].message?.contains("started with no recorded outcome") == true)
    #expect(refused.steps[0].message?.contains("op #1") == true)
  }

  @Test func aStartedOperationOtherThanARenameIsAlwaysRefused() throws {
    let box = try Sandbox()
    let make = DatastoreOp.mkdir(path: box.path("made"), mode: 0o755)
    let plan = box.plan(step([make]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    try DatastoreJournal.append(
      [
        DatastoreJournalEvent(plan: plan.id, event: .stepStarted, step: "S02-test"),
        DatastoreJournalEvent(
          plan: plan.id, event: .opStarted, step: "S02-test", op: 1, summary: make.summary),
      ], to: box.journal)
    let report = try executor.rollback(stepID: "S02-test")
    #expect(report.steps[0].result == .refused)
    #expect(
      report.steps[0].message
        == "op #1 (\(make.summary)) started with no recorded outcome; inspect the disk by hand.")
  }

  @Test func aJournalThatCannotBeWrittenStopsTheStepBeforeItsFirstOperation() throws {
    let box = try Sandbox()
    let plan = box.plan(step([.mkdir(path: box.path("made"), mode: 0o755)]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.journal)
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .preconditionFailed)
    #expect(report.steps[0].message?.contains("journal cannot be written") == true)
    #expect(!box.exists("made"))
  }

  @Test func theFirstStepReportsAJournalItCouldNotWrite() throws {
    let box = try Sandbox()
    var plan = box.plan(step([.mkdir(path: box.path("made"), mode: 0o755)]))
    plan.journal = box.backupDir + "/missing-folder/journal.jsonl"
    #expect(plan.validationErrors() == [])
    let report = try box.executor(plan).apply(stepID: "S01-backup")
    #expect(report.steps[0].result == .journalFailed)
    #expect(report.exitCode == 5)
    #expect(report.steps[0].message?.contains("IS APPLIED") == true)
    #expect(box.exists("Backups/run"))
  }

  @Test func aMutationThatContainsAProtectedPathIsRefusedEvenThroughASymlink() throws {
    let box = try Sandbox()
    try box.makeDirectory("box/inner/deep")
    try box.symlink("alias", to: "box")
    let plan = box.plan(
      protecting: [box.path("box/inner/deep")],
      step([.mkdir(path: box.path("alias/inner2"), mode: 0o755)]),
      step([.rename(from: box.path("alias/inner"), to: box.path("moved"))], id: "S03-move"))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    // The first step is harmless; the second moves a folder that holds a protected path.
    #expect(try executor.apply(stepID: "S02-test").steps[0].result == .applied)
    let report = try executor.apply(stepID: "S03-move")
    #expect(report.steps[0].result == .preconditionFailed)
    #expect(
      report.steps[0].preconditions.contains {
        $0.status == .fail && $0.detail.contains("protected path")
      })
    #expect(box.exists("box/inner/deep"))
  }

  @Test func aMutationThatResolvesOutsideTheAllowedRootsIsRefused() throws {
    let box = try Sandbox()
    let outside = box.root + "-outside"
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: outside) }
    try box.symlink("out", to: outside)
    let plan = box.plan(step([.mkdir(path: box.path("out/x"), mode: 0o755)]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .preconditionFailed)
    #expect(
      report.steps[0].preconditions.contains {
        $0.status == .fail && $0.name.contains("allowed root")
      })
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
  }

  @Test func aCaseOnlyRenameCanBeRolledBack() throws {
    let box = try Sandbox()
    try box.write("stuff/a.txt", "x")
    let plan = box.plan(step([.rename(from: box.path("stuff"), to: box.path("Stuff"))]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    #expect(try executor.apply(stepID: "S02-test").steps[0].result == .applied)
    #expect(box.names().contains("Stuff"))
    let report = try executor.rollback(stepID: "S02-test")
    #expect(report.steps[0].result == .rolledBack, "\(DatastoreReportRenderer.text(report))")
    #expect(box.names().contains("stuff"))
    #expect(!box.names().contains("Stuff"))
  }

  @Test func aLeftoverTemporaryFileStopsTheStepThatWouldReuseItsName() throws {
    let box = try Sandbox()
    try box.write("f.txt", "old")
    try box.symlink("l", to: "f.txt")
    try box.write("f.txt.datastore-tmp-999", "left behind")
    try box.write("l.datastore-tmp-1", "left behind")
    let file = box.path("f.txt")
    let plan = box.plan(
      step(
        [
          .backup(path: file),
          .rewriteText(path: file, find: "old", replace: "new", expectedCount: 1),
        ]),
      step(
        [.replaceSymlink(path: box.path("l"), target: "g", expectedTarget: "f.txt")],
        id: "S03-link"))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    let rewrite = try executor.apply(stepID: "S02-test")
    #expect(rewrite.steps[0].result == .preconditionFailed)
    #expect(
      rewrite.steps[0].preconditions.contains {
        $0.status == .fail && $0.detail.contains("f.txt.datastore-tmp-999")
      })
    #expect(try box.read("f.txt") == "old")

    try FileManager.default.removeItem(atPath: box.path("f.txt.datastore-tmp-999"))
    #expect(try executor.apply(stepID: "S02-test").steps[0].result == .applied)
    let link = try executor.apply(stepID: "S03-link")
    #expect(link.steps[0].result == .preconditionFailed)
    #expect(try box.read("f.txt") == "new")
  }

  /// The S02 events of the latest run, as kinds.
  private func s02Kinds(_ box: Sandbox, _ plan: DatastorePlan) throws -> [DatastoreJournalKind] {
    try DatastoreJournal.read(box.journal, planID: plan.id).filter { $0.step == "S02-test" }
      .map(\.event)
  }

  @Test func aDirectorySyncFailingAfterARenameStillJournalsItAndUndoesTheStep() throws {
    let box = try Sandbox()
    try box.write("src/a.txt", "payload")
    let plan = box.plan(step([.rename(from: box.path("src"), to: box.path("dst"))]))
    _ = try box.executor(plan).apply(stepID: "S01-backup")
    let before = box.tree(excludingBackups: true)
    let inode = box.inode("src")

    let executor = box.executor(plan, faults: DatastoreFaults(failSyncAfterOperation: 1))
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .opFailed)
    #expect(report.exitCode == 3)
    #expect(
      report.steps[0].message?.contains("happened, but a directory could not be flushed") == true)
    #expect(report.steps[0].operations[0].status == .undone)
    #expect(box.tree(excludingBackups: true) == before)
    #expect(box.inode("src") == inode)
    // The journal says the move happened, then that it was undone: it never claims otherwise.
    #expect(
      try s02Kinds(box, plan) == [
        .stepStarted, .opStarted, .opApplied, .opFailed, .opUndone, .stepRolledBack,
      ])
    let run = DatastoreJournal.latestRun(
      step: "S02-test", events: try DatastoreJournal.read(box.journal, planID: plan.id))
    #expect(run.outstanding.isEmpty)
    #expect(run.unresolved.isEmpty)
    #expect(try executor.status().map(\.state) == [.applied, .rolledBack])
  }

  @Test func aDirectorySyncFailingAfterARewriteStillUndoesTheStepAndKeepsTheBackup() throws {
    let box = try Sandbox()
    try box.write("f.txt", "old text\n", mode: 0o640)
    let file = box.path("f.txt")
    let plan = box.plan(
      step([
        .backup(path: file),
        .rewriteText(path: file, find: "old", replace: "new", expectedCount: 1),
      ]))
    _ = try box.executor(plan).apply(stepID: "S01-backup")
    let before = box.tree(excludingBackups: true)

    let executor = box.executor(plan, faults: DatastoreFaults(failSyncAfterOperation: 2))
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .opFailed)
    #expect(try box.read("f.txt") == "old text\n")
    #expect(box.tree(excludingBackups: true) == before)
    #expect(report.steps[0].operations.map(\.status) == [.undone, .undone])
    #expect(
      try s02Kinds(box, plan) == [
        .stepStarted, .opStarted, .opApplied, .opStarted, .opApplied, .opFailed, .opUndone,
        .opUndone, .stepRolledBack,
      ])
    #expect(
      try String(contentsOfFile: box.backupDir + "/files" + file, encoding: .utf8) == "old text\n")
  }

  @Test func aDirectorySyncFailingAfterAnUndoIsAWarningNotAFailure() throws {
    let box = try Sandbox()
    let plan = box.plan(
      step(
        [.mkdir(path: box.path("made"), mode: 0o755)],
        verify: [.exists(path: box.path("missing"), kind: .file)]))
    _ = try box.executor(plan).apply(stepID: "S01-backup")
    let before = box.tree(excludingBackups: true)

    let executor = box.executor(plan, faults: DatastoreFaults(failSyncAfterUndo: 1))
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .verifyFailed)
    #expect(report.steps[0].message?.contains("Warning:") == true)
    #expect(report.steps[0].message?.contains("could not be flushed afterwards") == true)
    #expect(box.tree(excludingBackups: true) == before)
    #expect(try executor.status().map(\.state) == [.applied, .rolledBack])

    // The same for a rollback command.
    let second = box.plan(step([.mkdir(path: box.path("made"), mode: 0o755)]))
    let again = box.executor(second, faults: DatastoreFaults(failSyncAfterUndo: 1))
    #expect(try again.apply(stepID: "S02-test").steps[0].result == .applied)
    let rolled = try again.rollback(stepID: "S02-test")
    #expect(rolled.steps[0].result == .rolledBack)
    #expect(rolled.exitCode == 0)
    #expect(rolled.steps[0].message?.contains("Warning:") == true)
    #expect(box.tree(excludingBackups: true) == before)
  }

  @Test func theWineSocketNameSignExtendsTheDeviceAndSyncingWorks() throws {
    #expect(
      DatastoreWineSocket.serverDirectoryName(device: 16_777_260, inode: 0x114cbb)
        == "server-100002c-114cbb")
    #expect(
      DatastoreWineSocket.serverDirectoryName(device: Int64(Int32(-1)), inode: 16)
        == "server-ffffffffffffffff-10")
    let box = try Sandbox()
    try DatastoreIO.syncDirectory(box.root)
    #expect(throws: HubError.self) { try DatastoreIO.syncDirectory(box.path("missing")) }
  }

  // MARK: - Dry run

  @Test func aDryRunLeavesTheTreeByteIdenticalAndSimulatesEarlierSteps() throws {
    let box = try Sandbox()
    try prepareBigTree(box)
    let file = box.path("f.txt")
    let plan = box.plan(
      step(
        [
          .mkdir(path: box.path("Hub"), mode: 0o755),
          .rename(from: box.path("src"), to: box.path("Hub/moved")),
          .backup(path: file),
          .rewriteText(path: file, find: "old", replace: "new", expectedCount: 1),
        ], id: "S02-hub"),
      step(
        [
          .mkdir(path: box.path("Hub/State"), mode: 0o700),
          .symlink(path: box.path("Hub/lnk"), target: "moved"),
        ],
        id: "S03-use",
        verify: [
          .exists(path: box.path("Hub/moved/a.txt"), kind: .file),
          .symlinkTarget(path: box.path("Hub/lnk"), target: "moved"),
          .textContains(path: file, text: "new", count: 1),
          .exists(path: box.path("Hub/lnk/sub/b.bin"), kind: .file),
          .hubConfigValid(path: box.path("Hub/hub.json"), prefix: "/x"),
        ]))
    let executor = box.executor(plan)
    let before = box.tree()

    let report = try executor.dryRun()
    #expect(box.tree() == before)
    #expect(!box.exists("Backups/run"))
    #expect(report.mode == .dryRun)
    #expect(report.steps.map(\.step) == ["S01-backup", "S02-hub", "S03-use"])
    #expect(report.exitCode == 0, "\(DatastoreReportRenderer.text(report))")
    let rename = report.steps[1].operations[1]
    #expect(rename.before?.entries == 3)
    #expect(rename.before?.bytes == 17)
    let skipped = report.steps[2].verification.filter { $0.status == .skip }
    #expect(skipped.count == 1)
    #expect(skipped[0].name.hasPrefix("hubConfigValid"))

    let single = try executor.dryRun(stepID: "S03-use")
    #expect(single.steps.map(\.step) == ["S03-use"])
    #expect(box.tree() == before)
    #expect(try executor.dryRun().steps.count == 3)
  }

  @Test func aDryRunReportsAFailingCheckWithExitCodeTwo() throws {
    let box = try Sandbox()
    try box.write("src/a.txt", "1")
    try box.write("taken/b.txt", "2")
    let plan = box.plan(step([.rename(from: box.path("src"), to: box.path("taken"))]))
    let before = box.tree()
    let report = try box.executor(plan).dryRun()
    #expect(report.exitCode == 2)
    #expect(report.steps[1].result == .preconditionFailed)
    #expect(report.steps[1].preconditions.contains { $0.status == .fail })
    #expect(box.tree() == before)
  }

  @Test func aDryRunSkipsAStepTheJournalSaysIsApplied() throws {
    let box = try Sandbox()
    let plan = box.plan(step([.mkdir(path: box.path("a"), mode: 0o755)]))
    let executor = box.executor(plan)
    _ = try executor.apply(stepID: "S01-backup")
    let before = box.tree()
    let report = try executor.dryRun()
    #expect(report.steps.map(\.result) == [.alreadyApplied, .planned])
    #expect(box.tree() == before)
  }

  // MARK: - writeHubConfig

  @Test func writeHubConfigRoundTripsAndChecksTheManifestHash() throws {
    let box = try Sandbox()
    try box.write("Runtimes/hub-0.manifest", "manifest bytes")
    let sha = DatastoreIO.sha256Hex(Data("manifest bytes".utf8))
    func spec(sha: String) -> DatastoreOp {
      .writeHubConfig(
        DatastoreHubConfigSpec(
          path: box.path("Hub/hub.json"), prefix: box.path("Prefix"), runtime: "hub-0",
          runtimeManifest: box.path("Runtimes/hub-0.manifest"), runtimeManifestSHA256: sha,
          generation: 0))
    }
    let good = box.plan(
      step(
        [.mkdir(path: box.path("Hub"), mode: 0o755), spec(sha: sha)],
        verify: [.hubConfigValid(path: box.path("Hub/hub.json"), prefix: box.path("Prefix"))]))
    let executor = box.executor(good)
    _ = try executor.apply(stepID: "S01-backup")
    let report = try executor.apply(stepID: "S02-test")
    #expect(report.steps[0].result == .applied, "\(DatastoreReportRenderer.text(report))")
    let config = try HubConfig.read(URL(fileURLWithPath: box.path("Hub/hub.json")))
    #expect(
      config
        == HubConfig(
          schemaVersion: 1, prefix: box.path("Prefix"), runtime: "hub-0",
          runtimeManifestSHA256: sha, generation: 0))
    // The same bytes HubConfig.write itself produces.
    try config.write(to: URL(fileURLWithPath: box.path("reference.json")))
    #expect(try box.read("Hub/hub.json") == box.read("reference.json"))
    #expect(try executor.rollback(stepID: "S02-test").steps[0].result == .rolledBack)
    #expect(!box.exists("Hub/hub.json"))

    try box.makeDirectory("Hub")
    let wrong = box.plan(step([spec(sha: String(repeating: "0", count: 64))]))
    let wrongReport = try box.executor(wrong).apply(stepID: "S02-test")
    #expect(wrongReport.steps[0].result == .preconditionFailed)
    #expect(
      wrongReport.steps[0].preconditions.contains {
        $0.status == .fail && $0.name.contains("runtime manifest hash matches")
      })
    #expect(!box.exists("Hub/hub.json"))

    try box.write("Hub/hub.json", "{}")
    let existing = box.plan(step([spec(sha: sha)]))
    let refused = try box.executor(existing).apply(stepID: "S02-test")
    #expect(refused.steps[0].result == .preconditionFailed)
    #expect(try box.read("Hub/hub.json") == "{}")
  }

  // MARK: - prefixNotInUse and quietFor

  private func evaluator(
    _ box: Sandbox, probe: FakeProbe = FakeProbe(), now: Date = Date()
  ) -> DatastoreCheckEvaluator {
    DatastoreCheckEvaluator(
      fileSystem: RealDatastoreFileSystem(),
      snapshot: DatastoreProbeSnapshot(probe: probe, processes: true, files: true),
      environment: DatastoreCheckEnvironment(
        now: now, userID: 501, socketRoots: [box.root + "/sock"]))
  }

  private func socketPath(_ box: Sandbox, prefix: String) throws -> String {
    var info = stat()
    #expect(stat(box.path(prefix), &info) == 0)
    let name =
      "server-\(String(UInt64(bitPattern: Int64(info.st_dev)), radix: 16))-\(String(UInt64(info.st_ino), radix: 16))"
    let directory = box.path("sock/.wine-501/\(name)")
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: directory + "/socket"))
    return directory + "/socket"
  }

  @Test func prefixNotInUseFailsOnAnOpenFile() throws {
    let box = try Sandbox()
    try box.write("Prefix/system.reg", "x")
    let probe = FakeProbe(openFiles: [box.path("Prefix/system.reg")])
    let outcome = evaluator(box, probe: probe).evaluate(
      .prefixNotInUse(path: box.path("Prefix"), aliases: []))
    #expect(outcome.status == .fail)
    #expect(outcome.detail.contains("system.reg"))
    let idle = evaluator(box).evaluate(.prefixNotInUse(path: box.path("Prefix"), aliases: []))
    #expect(idle.status == .pass)
  }

  @Test func prefixNotInUseFailsWhenAProcessHoldsTheWineSocket() throws {
    let box = try Sandbox()
    try box.write("Prefix/system.reg", "x")
    let socket = try socketPath(box, prefix: "Prefix")
    let check = DatastoreCheck.prefixNotInUse(path: box.path("Prefix"), aliases: [])

    let held = evaluator(box, probe: FakeProbe(openFiles: [socket])).evaluate(check)
    #expect(held.status == .fail)
    #expect(held.detail.contains("Wine server socket"))

    let stale = evaluator(box).evaluate(check)
    #expect(stale.status == .pass)
    #expect(stale.detail.contains("stale"))
  }

  @Test func prefixNotInUseFailsOnAMatchingCommandLineAndIgnoresOtherWine() throws {
    let box = try Sandbox()
    try box.write("Prefix/system.reg", "x")
    try box.symlink("Alias", to: "Prefix")
    let literal = box.path("Prefix")
    let check = DatastoreCheck.prefixNotInUse(path: literal, aliases: [box.path("Alias")])

    for line in [
      "wine64 explorer WINEPREFIX=\(literal) game.exe",
      "bash -c cd \(box.path("Alias"))/drive_c",
    ] {
      let outcome = evaluator(box, probe: FakeProbe(commands: [line])).evaluate(check)
      #expect(outcome.status == .fail, "\(line)")
      #expect(outcome.detail.contains(line))
    }
    let unrelated = FakeProbe(commands: [
      "/x/wine64 /other/prefix/app.exe", "wineserver -p", "/x/wine-preloader --foo",
    ])
    #expect(evaluator(box, probe: unrelated).evaluate(check).status == .pass)
  }

  @Test func aFailingProbeFailsTheCheck() throws {
    let box = try Sandbox()
    try box.write("Prefix/system.reg", "x")
    let probe = FakeProbe(failure: .io("lsof exploded"))
    let outcome = evaluator(box, probe: probe).evaluate(
      .prefixNotInUse(path: box.path("Prefix"), aliases: []))
    #expect(outcome.status == .fail)
    #expect(outcome.detail.contains("lsof exploded"))
    #expect(evaluator(box, probe: probe).evaluate(.noWineProcess).status == .fail)
  }

  @Test func quietForFailsOnAFreshFileAndPassesOnceItIsOldEnough() throws {
    let box = try Sandbox()
    try box.write("tree/deep/file.txt", "x")
    let check = DatastoreCheck.quietFor(path: box.path("tree"), minutes: 10)
    let now = Date()

    let fresh = evaluator(box, now: now).evaluate(check)
    #expect(fresh.status == .fail)
    #expect(fresh.detail.contains("file.txt") || fresh.detail.contains("deep"))
    #expect(evaluator(box, now: now.addingTimeInterval(5 * 60)).evaluate(check).status == .fail)
    #expect(evaluator(box, now: now.addingTimeInterval(11 * 60)).evaluate(check).status == .pass)

    // An old mtime does not help while the ctime is fresh: both count.
    let old = timeval(tv_sec: Int(now.timeIntervalSince1970) - 7200, tv_usec: 0)
    var times = [old, old]
    for relative in ["tree/deep/file.txt", "tree/deep", "tree"] {
      #expect(utimes(box.path(relative), &times) == 0)
    }
    #expect(evaluator(box, now: now).evaluate(check).status == .fail)
    #expect(evaluator(box, now: now.addingTimeInterval(11 * 60)).evaluate(check).status == .pass)

    // A modification time in the future counts as a recent change.
    let future = timeval(tv_sec: Int(now.timeIntervalSince1970) + 3600, tv_usec: 0)
    var futureTimes = [future, future]
    #expect(utimes(box.path("tree/deep/file.txt"), &futureTimes) == 0)
    #expect(evaluator(box, now: now.addingTimeInterval(11 * 60)).evaluate(check).status == .fail)
  }

  @Test func theLiveProbeParsesLsofAndListsProcesses() throws {
    let output = "p123\nfcwd\nn/tmp/x\nf3\nn->0x1234\nn/a b/c\nnrelative\n"
    #expect(LiveDatastoreProbe.parseOpenFiles(output) == ["/tmp/x", "/a b/c"])
    let lines = try LiveDatastoreProbe().processCommandLines()
    #expect(!lines.isEmpty)
  }

  // MARK: - The command line

  private func run(_ arguments: [String], probe: FakeProbe = FakeProbe()) -> (Int32, String, String)
  {
    var output = ""
    var diagnostics = ""
    let code = DatastoreCommand.run(
      arguments, probe: probe, environment: .live, output: { output += $0 },
      diagnostics: { diagnostics += $0 })
    return (code, output, diagnostics)
  }

  @Test func theCommandsReportExitCodes() throws {
    let box = try Sandbox()
    let second = """
      {"id":"S02-x","title":"Make a","preconditions":[{"check":"absent","path":"\(box.root)/a"}],
       "operations":[{"op":"mkdir","path":"\(box.root)/a","mode":493}]}
      """
    let first = """
      {"id":"S01-backup","title":"Backups","operations":[
        {"op":"mkdir","path":"\(box.backupDir)","mode":493}]}
      """
    let planPath = box.path("plan.json")
    try datastorePlanJSON(volume: box.root, backupDir: box.backupDir, steps: "[\(first),\(second)]")
      .write(to: URL(fileURLWithPath: planPath))

    let valid = run(["validate", planPath])
    #expect(valid.0 == 0)
    #expect(valid.1.hasPrefix("OK:"))
    #expect(run(["validate"]).0 == 1)
    #expect(run(["frobnicate", planPath]).0 == 1)
    #expect(run(["apply", planPath]).0 == 1)
    #expect(run(["validate", box.path("missing.json")]).0 == 1)

    try datastorePlanJSON(volume: box.root, backupDir: box.backupDir, extra: ",\"bogus\":1")
      .write(to: URL(fileURLWithPath: box.path("bad.json")))
    let invalid = run(["validate", box.path("bad.json")])
    #expect(invalid.0 == 1)
    #expect(invalid.2.contains("Unknown keys"))

    let before = box.tree()
    let dry = run(["dry-run", planPath])
    #expect(dry.0 == 0)
    #expect(dry.1.contains("S02-x"))
    #expect(box.tree() == before)
    let json = run(["dry-run", planPath, "--json", "--step", "S02-x"])
    let report = try JSONDecoder().decode(DatastoreRunReport.self, from: Data(json.1.utf8))
    #expect(report.steps.map(\.step) == ["S02-x"])

    #expect(run(["apply", planPath, "--step", "S02-x"]).0 == 2)  // S01 is not applied
    #expect(run(["apply", planPath, "--step", "S01-backup"]).0 == 0)
    #expect(run(["apply", planPath, "--step", "S02-x", "--json"]).0 == 0)
    #expect(run(["apply", planPath, "--step", "S02-x"]).0 == 2)  // already applied
    #expect(run(["status", planPath]).1.contains("applied"))
    #expect(run(["verify", planPath, "--step", "S02-x"]).0 == 0)
    #expect(run(["rollback", planPath, "--step", "S02-x"]).0 == 0)
    #expect(!box.exists("a"))
  }
}
