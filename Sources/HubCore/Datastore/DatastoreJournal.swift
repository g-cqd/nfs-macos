import Darwin
import Foundation

/// What a journal line records.
package enum DatastoreJournalKind: String, Codable, Equatable, Sendable {
  case stepStarted
  case preconditionFailed
  /// Written and flushed before an operation runs. A rename carries the source measurement.
  case opStarted
  /// Written as soon as the operation's system call has returned.
  case opApplied
  /// A rename's destination, measured after the move and found equal to the source.
  case opMeasured
  case opFailed
  case opUndone
  case undoFailed
  case verifyFailed
  case stepApplied
  case rollbackStarted
  case stepRolledBack
}

/// One line of the journal: an append-only JSON record of something that happened to a step.
package struct DatastoreJournalEvent: Codable, Equatable, Sendable {
  package var time: String
  package var plan: String
  package var event: DatastoreJournalKind
  package var step: String
  /// The 1-based position of the operation, for operation events.
  package var op: Int?
  package var summary: String?
  /// Facts a later undo needs (hashes, backup locations), as plain strings.
  package var detail: [String: String]?
  /// For a rename: the source measured before it and the destination measured after it.
  package var before: DatastoreMeasurement?
  package var after: DatastoreMeasurement?
  package var message: String?

  package init(
    plan: String, event: DatastoreJournalKind, step: String, op: Int? = nil,
    summary: String? = nil, detail: [String: String]? = nil,
    before: DatastoreMeasurement? = nil, after: DatastoreMeasurement? = nil,
    message: String? = nil, time: String? = nil
  ) {
    self.time = time ?? ISO8601DateFormatter().string(from: Date())
    self.plan = plan
    self.event = event
    self.step = step
    self.op = op
    self.summary = summary
    self.detail = detail
    self.before = before
    self.after = after
    self.message = message
  }
}

/// Where a step stands according to the journal.
package enum DatastoreStepState: String, Codable, Equatable, Sendable {
  /// Never started, or started and refused before it changed anything.
  case pending
  case applied
  case rolledBack
  /// Started and never finished, or an undo failed: the disk may be half-changed. Needs a human.
  case interrupted
}

/// One step's state, for `status`.
package struct DatastoreStepStatus: Codable, Equatable, Sendable {
  package var step: String
  package var title: String
  package var state: DatastoreStepState
  /// The time of the last event that moved the state, when there is one.
  package var since: String?
}

/// Reading and appending the journal file.
package enum DatastoreJournal {
  package static let maxFileBytes = 64 * 1024 * 1024

  /// The events in the journal, oldest first; empty when the file does not exist.
  /// - Throws: `.invalid` for a line that does not decode or belongs to another plan.
  package static func read(_ path: String, planID: String) throws(HubError)
    -> [DatastoreJournalEvent]
  {
    guard let data = try DatastoreIO.readBounded(path, limit: maxFileBytes) else { return [] }
    let decoder = JSONDecoder()
    var events: [DatastoreJournalEvent] = []
    var lineNumber = 0
    for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
      lineNumber += 1
      let event: DatastoreJournalEvent
      do {
        event = try decoder.decode(DatastoreJournalEvent.self, from: Data(line))
      } catch {
        throw .invalid("Journal line \(lineNumber) does not decode: \(error)")
      }
      guard event.plan == planID else {
        throw .invalid("Journal line \(lineNumber) belongs to plan \(event.plan), not \(planID).")
      }
      events.append(event)
    }
    return events
  }

  /// Appends `events` as JSON lines and flushes them to disk. The file is created if needed, but
  /// its directory must exist.
  package static func append(_ events: [DatastoreJournalEvent], to path: String) throws(HubError) {
    guard !events.isEmpty else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = Data()
    for event in events {
      do {
        bytes.append(try encoder.encode(event))
      } catch {
        throw .io("Cannot encode a journal event: \(error)")
      }
      bytes.append(UInt8(ascii: "\n"))
    }
    try DatastoreIO.append(bytes, to: path)
  }

  /// The state of every step of `plan` after replaying `events`.
  package static func statuses(
    plan: DatastorePlan, events: [DatastoreJournalEvent]
  ) throws(HubError) -> [DatastoreStepStatus] {
    var statuses = plan.steps.map {
      DatastoreStepStatus(step: $0.id, title: $0.title, state: .pending, since: nil)
    }
    for event in events {
      guard let index = statuses.firstIndex(where: { $0.step == event.step }) else {
        throw .invalid("The journal names step \(event.step), which the plan does not have.")
      }
      let state: DatastoreStepState
      switch event.event {
      case .stepStarted, .rollbackStarted, .undoFailed: state = .interrupted
      case .stepApplied: state = .applied
      case .stepRolledBack: state = .rolledBack
      case .preconditionFailed, .opStarted, .opApplied, .opMeasured, .opFailed, .opUndone,
        .verifyFailed:
        continue
      }
      statuses[index].state = state
      statuses[index].since = event.time
    }
    return statuses
  }

  /// What the journal says about the latest run of one step.
  package struct RunRecord: Equatable, Sendable {
    /// The operations applied and not undone, in the order applied. A rename's `after` is merged
    /// in from its `opMeasured` event.
    package var outstanding: [DatastoreJournalEvent]
    /// The operations that started and have no recorded outcome: the run stopped between the
    /// operation's start and the record of its result.
    package var unresolved: [DatastoreJournalEvent]
  }

  /// Replays the events from the last `stepStarted` of `step`.
  package static func latestRun(step: String, events: [DatastoreJournalEvent]) -> RunRecord {
    guard let start = events.lastIndex(where: { $0.step == step && $0.event == .stepStarted })
    else {
      return RunRecord(outstanding: [], unresolved: [])
    }
    var outstanding: [DatastoreJournalEvent] = []
    var started: [Int: DatastoreJournalEvent] = [:]
    for event in events[start...] where event.step == step {
      guard let number = event.op else { continue }
      switch event.event {
      case .opStarted:
        started[number] = event
      case .opApplied:
        started[number] = nil
        outstanding.append(event)
      case .opFailed:
        started[number] = nil
      case .opMeasured:
        if let slot = outstanding.lastIndex(where: { $0.op == number }) {
          outstanding[slot].after = event.after
        }
      case .opUndone:
        started[number] = nil
        outstanding.removeAll { $0.op == number }
      default:
        break
      }
    }
    return RunRecord(
      outstanding: outstanding, unresolved: started.values.sorted { ($0.op ?? 0) < ($1.op ?? 0) })
  }
}
