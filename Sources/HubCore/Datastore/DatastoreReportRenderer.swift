import Foundation

/// Turns reports into the text and JSON the command line prints and records.
package enum DatastoreReportRenderer {
  /// The report as sorted-key, pretty-printed JSON.
  /// - Throws: `.io` when encoding fails.
  package static func json<Value: Encodable>(_ value: Value) throws(HubError) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      return String(decoding: try encoder.encode(value), as: UTF8.self)
    } catch {
      throw .io("Cannot encode the report: \(error)")
    }
  }

  /// The report as readable text: one block per step, one line per check and operation.
  package static func text(_ report: DatastoreRunReport) -> String {
    var lines = [
      "Datastore plan \(report.plan): \(report.mode.rawValue), \(report.generated)",
      "Result: exit \(report.exitCode)",
    ]
    for step in report.steps {
      lines.append("")
      lines.append("== \(step.step): \(step.title) [\(step.result.rawValue)]")
      if let message = step.message { lines.append("   \(message)") }
      if !step.preconditions.isEmpty {
        lines.append("  checks before:")
        lines += step.preconditions.map { line($0) }
      }
      if !step.operations.isEmpty {
        lines.append("  operations:")
        for operation in step.operations { lines += operationLines(operation) }
      }
      if !step.verification.isEmpty {
        lines.append("  checks after:")
        lines += step.verification.map { line($0) }
      }
    }
    let counts = report.steps.flatMap { $0.preconditions + $0.verification }
      .reduce(into: [DatastoreCheckStatus: Int]()) { $0[$1.status, default: 0] += 1 }
    lines.append("")
    lines.append(
      "Checks: \(counts[.pass, default: 0]) pass, \(counts[.fail, default: 0]) fail, "
        + "\(counts[.skip, default: 0]) skip")
    return lines.joined(separator: "\n") + "\n"
  }

  /// The step states as a table.
  package static func text(planID: String, statuses: [DatastoreStepStatus]) -> String {
    var lines = ["Datastore plan \(planID)"]
    for status in statuses {
      let since = status.since.map { "  since \($0)" } ?? ""
      lines.append(
        "  \(status.state.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(status.step): \(status.title)\(since)"
      )
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func line(_ outcome: DatastoreCheckOutcome) -> String {
    let mark: String
    switch outcome.status {
    case .pass: mark = "PASS"
    case .fail: mark = "FAIL"
    case .skip: mark = "SKIP"
    }
    guard !outcome.detail.isEmpty else { return "    \(mark)  \(outcome.name)" }
    let detail = outcome.detail.split(separator: "\n", omittingEmptySubsequences: false)
      .joined(separator: "\n          ")
    return "    \(mark)  \(outcome.name)\n          \(detail)"
  }

  private static func operationLines(_ operation: DatastoreOpReport) -> [String] {
    var result = ["    \(operation.index). [\(operation.status.rawValue)] \(operation.summary)"]
    if let before = operation.before {
      result.append("         measured before: \(measurement(before))")
    }
    if let after = operation.after {
      result.append("         measured after:  \(measurement(after))")
    }
    if let message = operation.message { result.append("         \(message)") }
    return result
  }

  private static func measurement(_ value: DatastoreMeasurement) -> String {
    "\(value.entries) entries, \(value.bytes) bytes, \(value.symlinks) symlinks, "
      + "dev \(value.device) ino \(value.inode)"
  }
}
