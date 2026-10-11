import Foundation

/// The `runtime` commands of `gamehub-cli`, kept in the library so tests can drive them.
///
/// Exit codes: 0 ok; 1 usage error; 2 a precondition failed (nothing changed, or nothing to
/// verify); 3 the install failed (staging removed); 4 verification found a difference.
package enum RuntimeCommand {
  package static let usage = """
    usage: gamehub-cli runtime <command> [options]
      install --id ID --from WINE_TREE --helpers DIR --manifest FILE --links FILE --to APP
      verify  APP [--expect-sha SHA256] [--json]
    """

  /// Runs `arguments` (everything after `runtime`) and returns the process exit code.
  package static func run(
    _ arguments: [String], installer: RuntimeAppInstaller = RuntimeAppInstaller(),
    output: (String) -> Void, diagnostics: (String) -> Void
  ) -> Int32 {
    guard let command = arguments.first, command == "install" || command == "verify" else {
      diagnostics(usage)
      return 1
    }
    do throws(HubError) {
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
