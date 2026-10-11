import Foundation

/// The `runtime` commands of `gamehub-cli`, kept in the library so tests can drive them.
///
/// Exit codes: 0 ok; 1 usage error; 2 a precondition failed (nothing changed, or nothing to
/// verify); 3 the install failed (staging removed) or the warm-up failed; 4 verification found
/// a difference.
package enum RuntimeCommand {
  package static let usage = """
    usage: gamehub-cli runtime <command> [options]
      install --id ID --from WINE_TREE --helpers DIR --manifest FILE --links FILE --to APP
      verify  APP [--expect-sha SHA256] [--json]
      warm-eagep --wine WINE_TREE --prefix EA_PREFIX --scratch PREFIX --stamp FILE [--home DIR]
                 [--force]
    """

  /// Runs `arguments` (everything after `runtime`) and returns the process exit code.
  package static func run(
    _ arguments: [String], installer: RuntimeAppInstaller = RuntimeAppInstaller(),
    runner: any RuntimeProcessRunner = LiveRuntimeProcessRunner(),
    output: (String) -> Void, diagnostics: (String) -> Void
  ) -> Int32 {
    guard let command = arguments.first, ["install", "verify", "warm-eagep"].contains(command)
    else {
      diagnostics(usage)
      return 1
    }
    do throws(HubError) {
      if command == "warm-eagep" {
        return warmEAGEP(
          try warmRequest(Array(arguments.dropFirst())), runner: runner, output: output,
          diagnostics: diagnostics)
      }
      if command == "install" {
        return install(
          try installRequest(Array(arguments.dropFirst())), installer: installer, output: output,
          diagnostics: diagnostics)
      }
      return try verify(Array(arguments.dropFirst()), output: output, diagnostics: diagnostics)
    } catch {
      diagnostics(text(of: error) + "\n" + usage)
      return 1
    }
  }

  // MARK: - install

  private static func installRequest(_ arguments: [String]) throws(HubError)
    -> RuntimeInstallRequest
  {
    var values: [String: String] = [:]
    var rest = arguments[...]
    let flags = ["--id", "--from", "--helpers", "--manifest", "--links", "--to"]
    while let flag = rest.popFirst() {
      guard flags.contains(flag) else { throw .invalid("Unexpected argument for install: \(flag)") }
      guard values[flag] == nil else { throw .invalid("\(flag) was given twice.") }
      guard let value = rest.popFirst(), !value.hasPrefix("--") else {
        throw .invalid("\(flag) needs a value.")
      }
      values[flag] = value
    }
    if let missing = flags.first(where: { values[$0] == nil }) {
      throw .invalid("install needs \(missing).")
    }
    func url(_ flag: String) -> URL { URL(fileURLWithPath: values[flag] ?? "") }
    return RuntimeInstallRequest(
      id: values["--id"] ?? "", wineTree: url("--from"), helpersDir: url("--helpers"),
      manifest: url("--manifest"), links: url("--links"), appURL: url("--to"))
  }

  private static func install(
    _ request: RuntimeInstallRequest, installer: RuntimeAppInstaller,
    output: (String) -> Void, diagnostics: (String) -> Void
  ) -> Int32 {
    output("Installing runtime \(request.id) into \(request.appURL.path) ...\n")
    do throws(HubError) {
      let result = try installer.install(request)
      output(
        """
        OK: installed \(request.appURL.path)
          id: \(result.info.id)
          manifest SHA-256: \(result.info.manifestSHA256)
          copied: \(result.copiedBytes) bytes; \(result.filesVerified) files verified
          wine: \(result.wineVersion)

        """)
      return 0
    } catch {
      if case .io = error {
        diagnostics("Install failed. \(text(of: error))")
        return 3
      }
      diagnostics("Install refused; nothing was written. \(text(of: error))")
      return 2
    }
  }

  // MARK: - warm-eagep

  private struct WarmRequest {
    let wine: URL
    let prefix: URL
    let scratch: URL
    let stamp: URL
    let home: URL?
    let force: Bool
  }

  private static func warmRequest(_ arguments: [String]) throws(HubError) -> WarmRequest {
    var values: [String: String] = [:]
    var force = false
    var rest = arguments[...]
    let required = ["--wine", "--prefix", "--scratch", "--stamp"]
    while let flag = rest.popFirst() {
      if flag == "--force" {
        force = true
        continue
      }
      guard required.contains(flag) || flag == "--home" else {
        throw .invalid("Unexpected argument for warm-eagep: \(flag)")
      }
      guard values[flag] == nil else { throw .invalid("\(flag) was given twice.") }
      guard let value = rest.popFirst(), !value.hasPrefix("--") else {
        throw .invalid("\(flag) needs a value.")
      }
      values[flag] = value
    }
    if let missing = required.first(where: { values[$0] == nil }) {
      throw .invalid("warm-eagep needs \(missing).")
    }
    func url(_ flag: String) -> URL { URL(fileURLWithPath: values[flag] ?? "") }
    return WarmRequest(
      wine: url("--wine"), prefix: url("--prefix"), scratch: url("--scratch"),
      stamp: url("--stamp"), home: values["--home"].map { URL(fileURLWithPath: $0) }, force: force)
  }

  /// Runs EA's elevation proxy once in a scratch prefix, when the runtime changed since the last
  /// warm-up (or always with `--force`), so that Rosetta's translations are in place before EA
  /// starts it for a game launch. See `EAGEPWarmup`.
  private static func warmEAGEP(
    _ request: WarmRequest, runner: any RuntimeProcessRunner, output: (String) -> Void,
    diagnostics: (String) -> Void
  ) -> Int32 {
    let warmup = EAGEPWarmup(
      wine: request.wine, scratchPrefix: request.scratch, stampFile: request.stamp, runner: runner)
    guard let eagep = EAGEPWarmup.locateEAGEP(inPrefix: request.prefix) else {
      diagnostics("No EA app with EAGEP.exe in \(request.prefix.path); nothing to warm.")
      return 2
    }
    do throws(HubError) {
      if !request.force, try !warmup.isNeeded() {
        output("OK: the runtime is unchanged since the last warm-up; nothing to do.\n")
        return 0
      }
      output("Warming Rosetta's translations for \(eagep.path) in \(request.scratch.path) ...\n")
      let started = Date()
      let result = try warmup.run(eagep: eagep, livePrefix: request.prefix, home: request.home)
      output(
        String(
          format: "OK: warmed in %.1f s (EAGEP exit %d); stamp written to %@\n",
          Date().timeIntervalSince(started), result.exitCode, request.stamp.path))
      return 0
    } catch {
      switch error {
      case .io:
        diagnostics("Warm-up failed. \(text(of: error))")
        return 3
      default:
        diagnostics("Warm-up refused; nothing was run. \(text(of: error))")
        return 2
      }
    }
  }

  // MARK: - verify

  private static func verify(
    _ arguments: [String], output: (String) -> Void, diagnostics: (String) -> Void
  ) throws(HubError) -> Int32 {
    guard let app = arguments.first, !app.hasPrefix("--") else {
      throw .invalid("Missing the app to verify.")
    }
    var expected: String?
    var json = false
    var rest = arguments.dropFirst()
    while let argument = rest.popFirst() {
      switch argument {
      case "--json":
        json = true
      case "--expect-sha":
        guard let value = rest.popFirst(), !value.hasPrefix("--") else {
          throw .invalid("--expect-sha needs a SHA-256.")
        }
        try Check.sha256(value, field: "--expect-sha")
        expected = value
      default:
        throw .invalid("Unexpected argument for verify: \(argument)")
      }
    }
    let report: RuntimeVerifyReport
    do throws(HubError) {
      report = try RuntimeApp.verify(URL(fileURLWithPath: app), expectedSHA256: expected)
    } catch {
      diagnostics("Cannot verify \(app): \(text(of: error))")
      return 4
    }
    let view = RuntimeVerifyView(report: report, path: app)
    do {
      output(json ? try view.json() + "\n" : view.text())
    } catch {
      diagnostics("Cannot render the report: \(error.localizedDescription)")
      return 4
    }
    if report.isOK { return 0 }
    return report.state == .notFound ? 2 : 4
  }
}
