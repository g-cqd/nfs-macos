import Foundation

/// The `datastore` commands of `gamehub-cli`, kept in the library so tests can drive them.
///
/// Exit codes: 0 ok; 1 usage error or invalid plan; 2 a precondition failed (nothing changed);
/// 3 an operation failed (step undone); 4 a verify check failed (step undone); 5 an undo failed.
package enum DatastoreCommand {
  package static let usage = """
    usage: gamehub-cli datastore <command> <plan.json> [options]
      validate <plan>
      dry-run  <plan> [--step ID] [--json]    read-only; exit 2 if any check fails
      apply    <plan> --step ID [--json]      applies exactly one step
      verify   <plan> --step ID [--json]      re-checks an applied step
      rollback <plan> --step ID [--json]      undoes an applied step
      status   <plan> [--json]
    """

  private struct Options {
    var plan: String
    var step: String?
    var json = false
  }

  /// Runs `arguments` (everything after `datastore`) and returns the process exit code.
  ///
  /// `output` receives what a command prints on success and `diagnostics` what it prints on failure.
  package static func run(
    _ arguments: [String], probe: any DatastoreProbe = LiveDatastoreProbe(),
    environment: DatastoreCheckEnvironment = .live, output: (String) -> Void,
    diagnostics: (String) -> Void
  ) -> Int32 {
    guard let command = arguments.first,
      ["validate", "dry-run", "apply", "verify", "rollback", "status"].contains(command)
    else {
      diagnostics(usage)
      return 1
    }
    let options: Options
    do throws(HubError) {
      options = try parse(Array(arguments.dropFirst()), command: command)
    } catch {
      diagnostics(text(of: error) + "\n" + usage)
      return 1
    }

    let plan: DatastorePlan
    do throws(HubError) {
      plan = try DatastorePlan.load(path: options.plan)
    } catch {
      diagnostics("Invalid plan \(options.plan):\n\(text(of: error))")
      return 1
    }
    let executor = DatastoreExecutor(plan: plan, probe: probe, environment: environment)

    do throws(HubError) {
      switch command {
      case "validate":
        let operations = plan.steps.reduce(0) { $0 + $1.operations.count }
        let checks = plan.steps.reduce(0) { $0 + $1.preconditions.count + $1.verify.count }
        output(
          "OK: plan \(plan.id) is valid: \(plan.steps.count) steps, \(operations) operations, "
            + "\(checks) checks.\n")
        return 0
      case "status":
        let statuses = try executor.status()
        output(
          options.json
            ? try DatastoreReportRenderer.json(statuses) + "\n"
            : DatastoreReportRenderer.text(planID: plan.id, statuses: statuses))
        return 0
      default:
        let report: DatastoreRunReport
        switch command {
        case "dry-run": report = try executor.dryRun(stepID: options.step)
        case "apply": report = try executor.apply(stepID: options.step ?? "")
        case "verify": report = try executor.verify(stepID: options.step ?? "")
        default: report = try executor.rollback(stepID: options.step ?? "")
        }
        output(
          options.json
            ? try DatastoreReportRenderer.json(report) + "\n" : DatastoreReportRenderer.text(report)
        )
        return report.exitCode
      }
    } catch {
      diagnostics(text(of: error))
      return 1
    }
  }

  private static func parse(_ arguments: [String], command: String) throws(HubError) -> Options {
    guard let plan = arguments.first, !plan.hasPrefix("--") else {
      throw .invalid("Missing the plan file.")
    }
    var options = Options(plan: plan)
    var rest = arguments.dropFirst()
    let allowsJSON = command != "validate"
    let allowsStep = command != "validate" && command != "status"
    while let argument = rest.popFirst() {
      switch argument {
      case "--json" where allowsJSON:
        options.json = true
      case "--step" where allowsStep:
        guard let value = rest.popFirst(), !value.hasPrefix("--") else {
          throw .invalid("--step needs a step id.")
        }
        options.step = value
      default:
        throw .invalid("Unexpected argument for \(command): \(argument)")
      }
    }
    if command == "apply" || command == "verify" || command == "rollback", options.step == nil {
      throw .invalid("\(command) needs --step ID.")
    }
    return options
  }
}
