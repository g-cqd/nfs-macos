import Darwin
import Foundation

/// Which command produced a report.
package enum DatastoreRunMode: String, Codable, Equatable, Sendable {
  case dryRun, apply, verify, rollback
}

/// How a step came out.
package enum DatastoreStepResult: String, Codable, Equatable, Sendable {
  /// Dry run: the step would run as planned.
  case planned
  /// Dry run: the journal says the step is already applied, so the real disk shows its effect.
  case alreadyApplied
  case applied
  case verified
  case rolledBack
  /// The command was refused before it looked at the disk (order, journal state). Nothing changed.
  case refused
  /// A precondition failed. Nothing changed.
  case preconditionFailed
  /// An operation failed; every earlier operation of the step was undone.
  case opFailed
  /// A verify check failed; the whole step was undone (apply) or nothing was changed (verify).
  case verifyFailed
  /// An undo failed: the disk is half-changed and the report names its exact state.
  case undoFailed
  /// The step ran, but its journal could not be completed: the disk and the journal disagree.
  case journalFailed

  /// The process exit code of a command whose last step ended this way.
  package var exitCode: Int32 {
    switch self {
    case .planned, .alreadyApplied, .applied, .verified, .rolledBack: 0
    case .refused, .preconditionFailed: 2
    case .opFailed: 3
    case .verifyFailed: 4
    case .undoFailed, .journalFailed: 5
    }
  }
}

/// What happened to one step.
package struct DatastoreStepReport: Codable, Equatable, Sendable {
  package var step: String
  package var title: String
  package var result: DatastoreStepResult
  /// Step-level conditions, the step's preconditions and the implicit checks of its operations.
  package var preconditions: [DatastoreCheckOutcome]
  package var operations: [DatastoreOpReport]
  /// The implicit post-checks of the operations, then the step's verify checks.
  package var verification: [DatastoreCheckOutcome]
  package var message: String?

  /// Whether any check of the step failed.
  package var hasFailedCheck: Bool {
    (preconditions + verification).contains { $0.status == .fail }
  }
}

/// What a command did, step by step.
package struct DatastoreRunReport: Codable, Equatable, Sendable {
  package var plan: String
  package var mode: DatastoreRunMode
  package var generated: String
  package var steps: [DatastoreStepReport]

  /// 0 when everything passed; for a dry run 2 when any check failed; otherwise the worst step's
  /// code (2 precondition, 3 operation, 4 verify, 5 undo).
  package var exitCode: Int32 {
    if mode == .dryRun { return steps.contains { $0.hasFailedCheck } ? 2 : 0 }
    return steps.map(\.result.exitCode).max() ?? 0
  }
}

/// Faults a test can inject to stop a run where a crash could: the executor throws, leaving the
/// disk and the journal as they are at that point.
package struct DatastoreFaults: Sendable {
  /// Stop right after a rename's system call returned, before its `opApplied` is journaled.
  package var interruptAfterRenameSyscall = false
  /// Stop after a rename's `opApplied` is journaled, before the destination is measured.
  package var interruptBeforeMeasure = false
  /// Make the directory flush that follows operation #N fail (the operation itself has happened).
  package var failSyncAfterOperation: Int?
  /// Make the directory flush that follows the undo of operation #N fail.
  package var failSyncAfterUndo: Int?

  package init(
    interruptAfterRenameSyscall: Bool = false, interruptBeforeMeasure: Bool = false,
    failSyncAfterOperation: Int? = nil, failSyncAfterUndo: Int? = nil
  ) {
    self.interruptAfterRenameSyscall = interruptAfterRenameSyscall
    self.interruptBeforeMeasure = interruptBeforeMeasure
    self.failSyncAfterOperation = failSyncAfterOperation
    self.failSyncAfterUndo = failSyncAfterUndo
  }
}

/// Appends a step's journal events, each flushed as it is recorded. The first step runs before
/// `backupDir` (which holds the journal) exists: its events wait in memory and are all written
/// the moment the directory is there.
private struct DatastoreJournalWriter {
  let path: String
  /// False for the first step, whose events may precede the journal's directory.
  let requiresDirectory: Bool
  private var pending: [DatastoreJournalEvent] = []
  private var problems: [String] = []
  /// Events dropped because the directory never appeared (the first step was undone entirely).
  private(set) var droppedForMissingDirectory = false

  init(path: String, requiresDirectory: Bool) {
    self.path = path
    self.requiresDirectory = requiresDirectory
  }

  mutating func record(_ event: DatastoreJournalEvent) {
    pending.append(event)
    flush()
  }

  private mutating func flush() {
    guard !pending.isEmpty else { return }
    let directory = DatastorePath.parent(of: path)
    var info = stat()
    guard Darwin.lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
      if requiresDirectory {
        problems.append("the journal directory \(directory) is missing")
        pending.removeAll()
      }
      return
    }
    defer { pending.removeAll() }
    do {
      try DatastoreJournal.append(pending, to: path)
    } catch {
      problems.append("journal write failed: \(text(of: error))")
    }
  }

  /// The journal problems since the last call, joined; nil when there were none.
  mutating func takeProblems() -> String? {
    guard !problems.isEmpty else { return nil }
    defer { problems.removeAll() }
    return problems.joined(separator: "; ")
  }

  /// Writes what is pending and returns the outstanding problems. Events still waiting for the
  /// directory are a problem unless `allowMissingDirectory`, in which case they are dropped.
  mutating func finish(allowMissingDirectory: Bool) -> String? {
    flush()
    if !pending.isEmpty {
      if allowMissingDirectory {
        droppedForMissingDirectory = true
      } else {
        problems.append("the journal directory \(DatastorePath.parent(of: path)) never appeared")
      }
      pending.removeAll()
    }
    return takeProblems()
  }
}

/// Runs a plan: dry-run, apply, verify, rollback and status. Every command but `apply` and
/// `rollback` only reads.
package struct DatastoreExecutor: Sendable {
  package let plan: DatastorePlan
  package let probe: any DatastoreProbe
  package let environment: DatastoreCheckEnvironment
  package let processID: Int32
  package let faults: DatastoreFaults

  package init(
    plan: DatastorePlan, probe: any DatastoreProbe = LiveDatastoreProbe(),
    environment: DatastoreCheckEnvironment = .live, processID: Int32 = getpid(),
    faults: DatastoreFaults = DatastoreFaults()
  ) {
    self.plan = plan
    self.probe = probe
    self.environment = environment
    self.processID = processID
    self.faults = faults
  }

  // MARK: - Status

  /// Where every step stands according to the journal.
  /// - Throws: `.invalid` when the journal does not decode or does not belong to this plan.
  package func status() throws(HubError) -> [DatastoreStepStatus] {
    try DatastoreJournal.statuses(plan: plan, events: try journalEvents())
  }

  private func journalEvents() throws(HubError) -> [DatastoreJournalEvent] {
    try DatastoreJournal.read(plan.journal, planID: plan.id)
  }

  private func index(of stepID: String) throws(HubError) -> Int {
    guard let index = plan.steps.firstIndex(where: { $0.id == stepID }) else {
      throw .invalid("The plan has no step \(stepID).")
    }
    return index
  }

  // MARK: - Dry run

  /// Evaluates the steps up to `stepID` (all steps when nil) against a simulation of the disk in
  /// which each earlier step has been applied. Nothing is written. A step the journal records as
  /// applied is not simulated: the real disk already shows it.
  /// - Throws: `.invalid` for an unknown step or an unreadable journal.
  package func dryRun(stepID: String? = nil) throws(HubError) -> DatastoreRunReport {
    var last = plan.steps.count - 1
    if let stepID { last = try index(of: stepID) }
    let statuses = try status()
    var needsProcesses = false
    var needsFiles = false
    for step in plan.steps[0...last] {
      let needs = Self.probeNeeds(step)
      needsProcesses = needsProcesses || needs.processes
      needsFiles = needsFiles || needs.files
    }
    let snapshot = DatastoreProbeSnapshot(
      probe: probe, processes: needsProcesses, files: needsFiles)
    let planner = DatastoreStepPlanner(
      plan: plan, snapshot: snapshot, processID: processID, environment: environment)
    var simulation = SimulatedDatastoreFileSystem(over: RealDatastoreFileSystem())
    var reports: [DatastoreStepReport] = []
    var failedEarlier: [String] = []

    for position in 0...last {
      let step = plan.steps[position]
      let isReported = stepID == nil || position == last
      switch statuses[position].state {
      case .applied:
        if isReported {
          reports.append(
            report(
              step, .alreadyApplied,
              message: "The journal records this step as applied; the disk already shows it."))
        }
        continue
      case .interrupted:
        reports.append(
          report(
            step, .refused,
            message: "The journal shows this step started and did not finish; resolve it first."))
        return DatastoreRunReport(
          plan: plan.id, mode: .dryRun, generated: timestamp(), steps: reports)
      case .pending, .rolledBack:
        break
      }
      let preview = planner.preview(
        step, index: position, on: &simulation, measuring: isReported)
      let evaluator = DatastoreCheckEvaluator(
        fileSystem: simulation, snapshot: snapshot, environment: environment)
      let verification = step.verify.map { evaluator.evaluate($0) }
      var stepReport = report(
        step, .planned, preconditions: preview.checks, operations: preview.operations,
        verification: verification)
      if stepReport.hasFailedCheck {
        stepReport.result = .preconditionFailed
        failedEarlier.append(step.id)
      }
      if isReported {
        let earlier = failedEarlier.filter { $0 != step.id }
        if !earlier.isEmpty {
          stepReport.message =
            "Assumes the earlier step(s) \(earlier.joined(separator: ", ")) succeed; "
            + "they have failing checks in this simulation."
        }
        reports.append(stepReport)
      }
    }
    return DatastoreRunReport(plan: plan.id, mode: .dryRun, generated: timestamp(), steps: reports)
  }

  // MARK: - Apply

  /// Applies exactly one step to the real disk.
  ///
  /// The step runs only when every earlier step is applied, none after it is, and it is not
  /// applied itself. Preconditions are all judged before the first change. Each operation is
  /// journaled as started (and flushed) before it runs, and as applied as soon as it has; a
  /// rename's measurement of its destination follows as a third record. An operation that fails,
  /// or a verify check that fails, undoes the whole step.
  /// - Throws: `.invalid` for an unknown step or an unreadable journal.
  package func apply(stepID: String) throws(HubError) -> DatastoreRunReport {
    let position = try index(of: stepID)
    let step = plan.steps[position]
    let statuses = try status()

    func finished(_ stepReport: DatastoreStepReport) -> DatastoreRunReport {
      DatastoreRunReport(
        plan: plan.id, mode: .apply, generated: timestamp(), steps: [stepReport])
    }
    if let refusal = applyRefusal(position, statuses) {
      return finished(report(step, .refused, message: refusal))
    }

    let needs = Self.probeNeeds(step)
    let snapshot = DatastoreProbeSnapshot(
      probe: probe, processes: needs.processes, files: needs.files)
    let planner = DatastoreStepPlanner(
      plan: plan, snapshot: snapshot, processID: processID, environment: environment)
    var simulation = SimulatedDatastoreFileSystem(over: RealDatastoreFileSystem())
    let preview = planner.preview(step, index: position, on: &simulation, measuring: false)

    var writer = DatastoreJournalWriter(path: plan.journal, requiresDirectory: position > 0)
    if !preview.isAcceptable {
      let failed = preview.checks.filter { $0.status == .fail }
      writer.record(
        event(
          .preconditionFailed, step,
          message: failed.map { "\($0.name): \($0.detail)" }.joined(separator: "; ")))
      _ = writer.finish(allowMissingDirectory: true)
      return finished(
        report(
          step, .preconditionFailed, preconditions: preview.checks,
          operations: preview.operations,
          message: "A precondition failed; nothing was changed."))
    }

    writer.record(event(.stepStarted, step, message: step.title))
    if let problem = writer.takeProblems() {
      return finished(
        report(
          step, .preconditionFailed, preconditions: preview.checks,
          operations: preview.operations,
          message: "The journal cannot be written (\(problem)); nothing was changed."))
    }
    let runner = DatastoreOperationRunner(plan: plan, processID: processID, faults: faults)
    var operationReports = preview.operations
    var applied: [DatastoreAppliedOp] = []
    var failure: String?
    var failureResult = DatastoreStepResult.opFailed

    for (offset, op) in step.operations.enumerated() {
      let number = offset + 1
      let label = "Operation #\(number) (\(op.summary))"

      let before: DatastoreMeasurement?
      do throws(HubError) {
        before = try runner.begin(op)
      } catch {
        operationReports[offset].status = .failed
        operationReports[offset].message = text(of: error)
        writer.record(
          event(.opFailed, step, op: number, summary: op.summary, message: text(of: error)))
        failure = "\(label) could not start: \(text(of: error))"
        break
      }
      operationReports[offset].before = before

      writer.record(event(.opStarted, step, op: number, summary: op.summary, before: before))
      if let problem = writer.takeProblems() {
        operationReports[offset].status = .failed
        operationReports[offset].message = "not run: the journal could not be written"
        failure = "\(label) was not run, because the journal could not be written: \(problem)"
        break
      }

      let done: DatastoreAppliedOp
      do throws(DatastoreOpFailure) {
        done = try runner.apply(op, index: number, before: before)
      } catch {
        operationReports[offset].message = text(of: error.error)
        var reason = "\(label) failed: \(text(of: error.error))"
        if let happened = error.applied {
          // The change was made and only its durability failed: record it as applied, so the
          // undo below reverses it with the rest of the step.
          applied.append(happened)
          operationReports[offset].status = .applied
          writer.record(appliedEvent(happened, step))
          reason =
            "\(label) happened, but a directory could not be flushed: "
            + "\(text(of: error.error))"
        } else {
          operationReports[offset].status = .failed
        }
        writer.record(
          event(
            .opFailed, step, op: number, summary: op.summary, message: text(of: error.error)))
        if let problem = writer.takeProblems() { reason += " Journal problem: \(problem)" }
        failure = reason
        break
      }
      applied.append(done)
      operationReports[offset].status = .applied
      if faults.interruptAfterRenameSyscall, case .rename = op {
        throw .io("Interrupted (fault injection) right after the rename system call returned.")
      }
      writer.record(appliedEvent(done, step))
      if let problem = writer.takeProblems() {
        failure = "Stopped after \(label) because the journal could not be written: \(problem)"
        break
      }

      guard case .rename = op else { continue }
      if faults.interruptBeforeMeasure {
        throw .io("Interrupted (fault injection) before the rename was measured.")
      }
      do throws(HubError) {
        let after = try runner.measureAfter(done)
        applied[applied.count - 1].after = after
        operationReports[offset].after = after
        writer.record(
          DatastoreJournalEvent(
            plan: plan.id, event: .opMeasured, step: step.id, op: number, summary: op.summary,
            after: after))
      } catch {
        operationReports[offset].status = .failed
        operationReports[offset].message = text(of: error)
        writer.record(
          event(.opFailed, step, op: number, summary: op.summary, message: text(of: error)))
        failure = "\(label) failed: \(text(of: error))"
        break
      }
      if let problem = writer.takeProblems() {
        failure = "Stopped after \(label) because the journal could not be written: \(problem)"
        break
      }
    }

    var verification: [DatastoreCheckOutcome] = []
    if failure == nil {
      let verifyNeeds = Self.probeNeeds(of: step.verify)
      let after = DatastoreProbeSnapshot(
        probe: probe, processes: verifyNeeds.processes, files: verifyNeeds.files)
      let evaluator = DatastoreCheckEvaluator(
        fileSystem: RealDatastoreFileSystem(), snapshot: after, environment: environment)
      verification = runner.postChecks(for: applied) + step.verify.map { evaluator.evaluate($0) }
      let failed = verification.filter { $0.status == .fail }
      if !failed.isEmpty {
        failureResult = .verifyFailed
        failure =
          "Verification failed: "
          + failed.map { "\($0.name): \($0.detail)" }.joined(separator: "; ")
        writer.record(event(.verifyFailed, step, message: failure))
      }
    }

    guard let failure else {
      writer.record(event(.stepApplied, step, message: step.title))
      if let problem = writer.finish(allowMissingDirectory: false) {
        return finished(
          report(
            step, .journalFailed, preconditions: preview.checks, operations: operationReports,
            verification: verification,
            message: "The step IS APPLIED on the disk, but its journal is incomplete: \(problem). "
              + "Run verify, and record the state by hand before going on."))
      }
      return finished(
        report(
          step, .applied, preconditions: preview.checks, operations: operationReports,
          verification: verification))
    }

    // Undo everything this run did, newest first.
    var undoWarnings: [String] = []
    let remaining = undo(
      applied, step: step, writer: &writer, operationReports: &operationReports,
      warnings: &undoWarnings)
    var message = failure
    if !undoWarnings.isEmpty { message += " Warning: " + undoWarnings.joined(separator: " ") }
    var result = failureResult
    if remaining.isEmpty {
      writer.record(event(.stepRolledBack, step, message: "undone after a failure"))
      message += " The step was undone; the disk is as it was."
    } else {
      result = .undoFailed
      message += " UNDO FAILED. " + Self.describeRemaining(remaining)
    }
    let journalProblem = writer.finish(allowMissingDirectory: position == 0 && remaining.isEmpty)
    if writer.droppedForMissingDirectory {
      message += " (The first step left no journal, because it removed the directory.)"
    }
    if let journalProblem { message += " Journal problem: \(journalProblem)" }
    return finished(
      report(
        step, result, preconditions: preview.checks, operations: operationReports,
        verification: verification, message: message))
  }

  private func applyRefusal(_ position: Int, _ statuses: [DatastoreStepStatus]) -> String? {
    let step = plan.steps[position]
    switch statuses[position].state {
    case .applied: return "\(step.id) is already applied."
    case .interrupted:
      return "\(step.id) was started and did not finish; inspect the journal and roll it back."
    case .pending, .rolledBack: break
    }
    if let earlier = statuses[..<position].first(where: { $0.state != .applied }) {
      return
        "Steps run in listed order: \(earlier.step) is not applied (\(earlier.state.rawValue))."
    }
    if let later = statuses[(position + 1)...].first(where: {
      $0.state != .pending && $0.state != .rolledBack
    }) {
      return "\(later.step), after \(step.id), is \(later.state.rawValue)."
    }
    return nil
  }

  // MARK: - Verify

  /// Re-checks an applied step on the real disk: the implicit post-checks of its operations, from
  /// the journal's record, then its verify checks. Changes nothing.
  /// - Throws: `.invalid` for an unknown step or an unreadable journal.
  package func verify(stepID: String) throws(HubError) -> DatastoreRunReport {
    let position = try index(of: stepID)
    let step = plan.steps[position]
    let events = try journalEvents()
    let statuses = try DatastoreJournal.statuses(plan: plan, events: events)

    func finished(_ stepReport: DatastoreStepReport) -> DatastoreRunReport {
      DatastoreRunReport(
        plan: plan.id, mode: .verify, generated: timestamp(), steps: [stepReport])
    }
    guard statuses[position].state == .applied else {
      return finished(
        report(
          step, .refused,
          message: "\(step.id) is \(statuses[position].state.rawValue), not applied."))
    }
    let outstanding = DatastoreJournal.latestRun(step: step.id, events: events).outstanding
    var applied: [DatastoreAppliedOp] = []
    for event in outstanding { applied.append(try appliedOperation(event, in: step)) }
    let needs = Self.probeNeeds(of: step.verify)
    let snapshot = DatastoreProbeSnapshot(
      probe: probe, processes: needs.processes, files: needs.files)
    let evaluator = DatastoreCheckEvaluator(
      fileSystem: RealDatastoreFileSystem(), snapshot: snapshot, environment: environment)
    let runner = DatastoreOperationRunner(plan: plan, processID: processID, faults: faults)
    let verification =
      runner.postChecks(for: applied) + step.verify.map { evaluator.evaluate($0) }
    let failed = verification.contains { $0.status == .fail }
    return finished(
      report(
        step, failed ? .verifyFailed : .verified, verification: verification,
        message: failed ? "Nothing was changed." : nil))
  }

  // MARK: - Rollback

  /// Undoes an applied step, newest operation first, each only if the thing it changed is still
  /// what the operation left. Refuses the first step (it creates the backup directory and the
  /// journal) and any step with a later step still applied.
  /// - Throws: `.invalid` for an unknown step or an unreadable journal.
  package func rollback(stepID: String) throws(HubError) -> DatastoreRunReport {
    let position = try index(of: stepID)
    let step = plan.steps[position]
    let events = try journalEvents()
    let statuses = try DatastoreJournal.statuses(plan: plan, events: events)

    func finished(_ stepReport: DatastoreStepReport) -> DatastoreRunReport {
      DatastoreRunReport(
        plan: plan.id, mode: .rollback, generated: timestamp(), steps: [stepReport])
    }
    func refused(_ message: String) -> DatastoreRunReport {
      finished(report(step, .refused, message: message))
    }
    guard position > 0 else {
      return refused(
        "\(step.id) is the first step: it creates the backup directory and the journal, "
          + "so it is never rolled back. Remove its directory by hand if you must.")
    }
    let state = statuses[position].state
    guard state == .applied || state == .interrupted else {
      return refused("\(step.id) is \(state.rawValue); there is nothing to roll back.")
    }
    if let later = statuses[(position + 1)...].first(where: {
      $0.state == .applied || $0.state == .interrupted
    }) {
      return refused("\(later.step) is \(later.state.rawValue); roll it back first.")
    }

    let run = DatastoreJournal.latestRun(step: step.id, events: events)
    var applied: [DatastoreAppliedOp] = []
    for event in run.outstanding { applied.append(try appliedOperation(event, in: step)) }
    // An operation that started and has no recorded outcome: only a rename can be decided from
    // the disk; anything else needs a human.
    var recovered: [DatastoreAppliedOp] = []
    var notApplied: [DatastoreJournalEvent] = []
    for event in run.unresolved {
      let number = event.op ?? 0
      guard number >= 1, number <= step.operations.count else {
        throw .invalid("The journal names operation \(number) of \(step.id), which does not exist.")
      }
      let op = step.operations[number - 1]
      switch try resolveUnrecordedRename(op, number: number, started: event) {
      case .applied(let found):
        recovered.append(found)
      case .notApplied:
        notApplied.append(event)
      case .ambiguous:
        return refused(
          "op #\(number) (\(op.summary)) started with no recorded outcome; "
            + "inspect the disk by hand.")
      }
    }
    applied = (applied + recovered).sorted { $0.index < $1.index }
    var renamed: [String] = []
    for done in applied {
      if case .rename(_, let to) = done.op { renamed.append(to) }
    }
    let snapshot = DatastoreProbeSnapshot(
      probe: probe, processes: step.requiresNoWine, files: !renamed.isEmpty)
    let planner = DatastoreStepPlanner(
      plan: plan, snapshot: snapshot, processID: processID, environment: environment)
    let evaluator = DatastoreCheckEvaluator(
      fileSystem: RealDatastoreFileSystem(), snapshot: snapshot, environment: environment)
    var checks = [planner.volumeMounted()]
    if step.requiresNoWine {
      let outcome = evaluator.evaluate(.noWineProcess)
      checks.append(
        .init(name: "no Wine process is running", status: outcome.status, detail: outcome.detail))
    }
    for path in renamed { checks.append(evaluator.evaluate(.noOpenFiles(path: path))) }
    var operationReports = applied.reversed().map {
      DatastoreOpReport(
        index: $0.index, summary: $0.op.summary, status: .applied, before: $0.before,
        after: $0.after, message: nil)
    }
    guard checks.allSatisfy(\.isAcceptable) else {
      return finished(
        report(
          step, .preconditionFailed, preconditions: checks, operations: operationReports,
          message: "A condition for the rollback failed; nothing was changed."))
    }

    var writer = DatastoreJournalWriter(path: plan.journal, requiresDirectory: true)
    writer.record(event(.rollbackStarted, step, message: "rollback requested"))
    if let problem = writer.takeProblems() {
      return finished(
        report(
          step, .preconditionFailed, preconditions: checks, operations: operationReports,
          message: "The journal cannot be written (\(problem)); nothing was changed."))
    }
    for found in recovered {
      var recorded = appliedEvent(found, step)
      recorded.message = "decided from the disk at rollback: the rename had happened"
      writer.record(recorded)
    }
    for event in notApplied {
      var recorded = event
      recorded.event = .opFailed
      recorded.message = "decided from the disk at rollback: the rename had not happened"
      recorded.before = nil
      writer.record(recorded)
    }
    var undoWarnings: [String] = []
    let remaining = undo(
      applied, step: step, writer: &writer, operationReports: &operationReports,
      warnings: &undoWarnings)
    var message: String? =
      undoWarnings.isEmpty ? nil : "Warning: " + undoWarnings.joined(separator: " ")

    var result = DatastoreStepResult.rolledBack
    if remaining.isEmpty {
      writer.record(event(.stepRolledBack, step, message: "rolled back"))
    } else {
      result = .undoFailed
      message =
        (message.map { $0 + " " } ?? "") + "UNDO FAILED. "
        + Self.describeRemaining(remaining)
    }
    if let problem = writer.takeProblems() { message = (message.map { $0 + " " } ?? "") + problem }
    return finished(
      report(
        step, result, preconditions: checks, operations: operationReports, message: message))
  }

  // MARK: - Shared pieces

  private enum UnrecordedOutcome {
    case applied(DatastoreAppliedOp)
    case notApplied
    case ambiguous
  }

  /// Decides, from the disk, whether a rename that started with no recorded outcome happened:
  /// by the names the directories list (so a case-only rename is told apart on a case-insensitive
  /// volume) and the device and inode recorded before the move. Any other operation, and a
  /// rename the disk does not settle, is ambiguous.
  private func resolveUnrecordedRename(
    _ op: DatastoreOp, number: Int, started: DatastoreJournalEvent
  ) throws(HubError) -> UnrecordedOutcome {
    guard case .rename(let from, let to) = op, let before = started.before else {
      return .ambiguous
    }
    let fileSystem = RealDatastoreFileSystem()
    func isListed(_ path: String) throws(HubError) -> Bool {
      try fileSystem.childNames(of: DatastorePath.parent(of: path))?.contains(
        DatastorePath.name(of: path)) ?? false
    }
    func isTheSource(_ path: String) throws(HubError) -> Bool {
      guard let info = try fileSystem.lstatNode(path) else { return false }
      return info.device == before.device && info.inode == before.inode
    }
    let fromListed = try isListed(from)
    let toListed = try isListed(to)
    if !fromListed, toListed, try isTheSource(to) {
      return .applied(
        DatastoreAppliedOp(index: number, op: op, detail: [:], before: before, after: nil))
    }
    if fromListed, !toListed, try isTheSource(from) { return .notApplied }
    return .ambiguous
  }

  /// Undoes `applied`, newest first, stopping at the first undo that fails.
  /// - Returns: the operations still applied, newest first (empty when all were undone).
  private func undo(
    _ applied: [DatastoreAppliedOp], step: DatastoreStep, writer: inout DatastoreJournalWriter,
    operationReports: inout [DatastoreOpReport], warnings: inout [String]
  ) -> [DatastoreAppliedOp] {
    let runner = DatastoreOperationRunner(plan: plan, processID: processID, faults: faults)
    var remaining = Array(applied.reversed())
    while let next = remaining.first {
      do throws(HubError) {
        if let warning = try runner.undo(next) { warnings.append(warning) }
        writer.record(
          event(.opUndone, step, op: next.index, summary: next.op.summary))
        if let slot = operationReports.firstIndex(where: { $0.index == next.index }) {
          operationReports[slot].status = .undone
        }
        remaining.removeFirst()
      } catch {
        let reason = text(of: error)
        writer.record(
          event(.undoFailed, step, op: next.index, summary: next.op.summary, message: reason))
        if let slot = operationReports.firstIndex(where: { $0.index == next.index }) {
          operationReports[slot].message = "undo failed: \(reason)"
        }
        break
      }
    }
    return remaining
  }

  private static func describeRemaining(_ remaining: [DatastoreAppliedOp]) -> String {
    guard let first = remaining.first else { return "" }
    var text = "Still applied, newest first: "
    text += remaining.map { "#\($0.index) \($0.op.summary)" }.joined(separator: "; ")
    text += ". The first undo that failed is #\(first.index). "
    text += "Inspect the disk and the journal; nothing further was attempted."
    return text
  }

  private func appliedOperation(
    _ event: DatastoreJournalEvent, in step: DatastoreStep
  ) throws(HubError) -> DatastoreAppliedOp {
    guard let number = event.op, number >= 1, number <= step.operations.count else {
      throw .invalid(
        "The journal names operation \(event.op ?? 0) of \(step.id), which does not exist.")
    }
    return DatastoreAppliedOp(
      index: number, op: step.operations[number - 1], detail: event.detail ?? [:],
      before: event.before, after: event.after)
  }

  /// What a step needs the probe to read, from its operations, conditions and checks.
  private static func probeNeeds(_ step: DatastoreStep) -> (processes: Bool, files: Bool) {
    var needs = probeNeeds(of: step.preconditions + step.verify)
    needs.processes = needs.processes || step.requiresNoWine
    needs.files =
      needs.files
      || step.operations.contains {
        if case .rename = $0 { return true }
        return false
      }
    return needs
  }

  /// What a list of checks needs the probe to read.
  private static func probeNeeds(of checks: [DatastoreCheck]) -> (processes: Bool, files: Bool) {
    var processes = false
    var files = false
    for check in checks {
      switch check {
      case .noWineProcess: processes = true
      case .noOpenFiles: files = true
      case .prefixNotInUse:
        processes = true
        files = true
      default: break
      }
    }
    return (processes, files)
  }

  private func timestamp() -> String {
    ISO8601DateFormatter().string(from: environment.now)
  }

  private func report(
    _ step: DatastoreStep, _ result: DatastoreStepResult,
    preconditions: [DatastoreCheckOutcome] = [], operations: [DatastoreOpReport] = [],
    verification: [DatastoreCheckOutcome] = [], message: String? = nil
  ) -> DatastoreStepReport {
    DatastoreStepReport(
      step: step.id, title: step.title, result: result, preconditions: preconditions,
      operations: operations, verification: verification, message: message)
  }

  private func event(
    _ kind: DatastoreJournalKind, _ step: DatastoreStep, op: Int? = nil, summary: String? = nil,
    before: DatastoreMeasurement? = nil, message: String? = nil
  ) -> DatastoreJournalEvent {
    DatastoreJournalEvent(
      plan: plan.id, event: kind, step: step.id, op: op, summary: summary, before: before,
      message: message)
  }

  private func appliedEvent(_ done: DatastoreAppliedOp, _ step: DatastoreStep)
    -> DatastoreJournalEvent
  {
    DatastoreJournalEvent(
      plan: plan.id, event: .opApplied, step: step.id, op: done.index, summary: done.op.summary,
      detail: done.detail, before: done.before, after: done.after)
  }
}
