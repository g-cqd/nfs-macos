import Foundation

/// What was true when the game started, gathered once and kept for any report of that launch.
package struct NFS2015CrashContext: Sendable {
  package var pins: NFS2015BuildPins
  package var host: NFS2015HostFacts
  package var display: NFS2015DisplayFacts?
  package var displayPlan: NFS2015DisplaySafetyPlan
  package var seed: NFS2015FirstRunOptions.Outcome?
  package var metalFX: NFS2015MetalFXPreference
  package var diagnostics: NFS2015DiagnosticsPreference
  /// Whether the diagnostic Wine log was on for this launch.
  package var diagnosticLog: Bool
  /// The game's own options, as the catalog reads them; none before the game wrote its file.
  package var settings: NFS2015Settings
  /// The runtime switches the launch used, after any experiment.
  package var tuning: [String: String]
  package var experiment: NFS2015ExperimentOverrides
  /// Whether the x87 sidecar was attached to the Wine session of this launch, and why.
  package var sidecar: NFS2015SidecarChoice

  /// - Parameter sidecar: The choice the launch used; when omitted, the default joined with
  ///   `experiment`.
  package init(
    pins: NFS2015BuildPins, host: NFS2015HostFacts, display: NFS2015DisplayFacts?,
    displayPlan: NFS2015DisplaySafetyPlan, seed: NFS2015FirstRunOptions.Outcome?,
    metalFX: NFS2015MetalFXPreference, diagnostics: NFS2015DiagnosticsPreference,
    diagnosticLog: Bool, settings: NFS2015Settings, tuning: [String: String],
    experiment: NFS2015ExperimentOverrides, sidecar: NFS2015SidecarChoice? = nil
  ) {
    self.pins = pins
    self.host = host
    self.display = display
    self.displayPlan = displayPlan
    self.seed = seed
    self.metalFX = metalFX
    self.diagnostics = diagnostics
    self.diagnosticLog = diagnosticLog
    self.settings = settings
    self.tuning = tuning
    self.experiment = experiment
    self.sidecar =
      sidecar ?? NFS2015SidecarChoice(preference: .standard, experiment: experiment)
  }
}

/// A short text file that says what the game did when it died, and on what.
///
/// It exists so that the next failure arrives with its facts: where the faulting instruction is
/// in the game, what kind of value the pointer was, which display modes the game asked for,
/// which renderer settings and runtime switches were in force, which build and Mac it was, and
/// how busy the Mac was. It holds no names, no EA data of any kind and no game content; the text
/// is passed through `NFS2015Redaction.scrubReport` before it is kept.
package struct NFS2015CrashReport: Equatable, Sendable {
  static let sizeLimit = 65_536

  package let text: String
  package let faultCount: Int
  /// The first fault, in one line, for the notice in the starter.
  package let headline: String

  /// - Returns: nil when the digest holds no fault: there is nothing to report.
  package init?(
    digest: NFS2015LogDigest, context: NFS2015CrashContext, load: NFS2015LoadSample, now: Date
  ) {
    let findings = digest.faults.map { NFS2015FaultFinding(line: $0) }
    guard let first = findings.first else { return nil }
    faultCount = findings.count
    headline =
      "\(findings.count) fault\(findings.count == 1 ? "" : "s") in \(digest.launches) game "
      + "launch\(digest.launches == 1 ? "" : "es"); first at \(first.location)"
    var lines: [String] = []
    lines.append("Need for Speed (2015) on macOS: crash report")
    lines.append("written: \(now.formatted(.iso8601)) (UTC)")
    lines.append("It holds no names and no EA data. Send it as it is.")
    lines.append("")
    lines.append("== What happened ==")
    lines.append(headline)
    lines.append(
      "wineserver reported a crash \(digest.serverCrashes) time(s); game launches in this session: "
        + "\(digest.launches)")
    lines += Self.faultLines(findings)
    lines.append("")
    lines += Self.displaySection(digest: digest, context: context)
    lines.append("")
    lines.append("== Renderer and runtime ==")
    lines.append(
      "MetalFX: "
        + (context.metalFX.spatialUpscaling
          ? "on, \(context.metalFX.factor.rawValue)x for NFS16.exe" : "off"))
    lines.append(
      "diagnostic Wine log for this launch: "
        + (context.diagnosticLog ? NFS2015DiagnosticLog.channels : "off"))
    lines.append("x87 sidecar: \(context.sidecar.line)")
    let switches = context.tuning.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    lines.append("runtime switches in force: \(switches.isEmpty ? "none" : switches)")
    lines.append("experiment overrides: \(context.experiment.summary)")
    lines.append("")
    lines.append("== Game options (catalog values only) ==")
    let values = context.settings.values.sorted { $0.key < $1.key }
    lines += values.isEmpty ? ["none: the game had not written its options file"] : []
    lines += values.map { "\($0.key) \($0.value)" }
    lines.append("")
    lines.append("== Build ==")
    lines += context.pins.lines
    lines.append("")
    lines.append("== Mac ==")
    lines.append(context.host.summary)
    lines.append("at the time of this report: \(load.summary)")
    if !digest.context.isEmpty {
      lines.append("")
      lines.append("== Last diagnostic lines of the log ==")
      lines += digest.context
    }
    if !digest.trace.isEmpty {
      lines.append("")
      lines.append("== Last exception trace lines (diagnostic Wine log) ==")
      lines += digest.trace
    }
    var body = NFS2015Redaction.scrubReport(lines.joined(separator: "\n"))
    if body.utf8.count > Self.sizeLimit {
      body = String(decoding: body.utf8.prefix(Self.sizeLimit), as: UTF8.self) + "\n[cut]"
    }
    text = body + "\n"
  }

  private static func faultLines(_ findings: [NFS2015FaultFinding]) -> [String] {
    var lines: [String] = []
    for (index, finding) in findings.enumerated() {
      lines.append("")
      lines.append("fault \(index + 1): thread \(finding.line.thread) at \(finding.location)")
      switch finding.line.kind {
      case .pageFault(let access, let value):
        lines.append(
          "  \(access) access to 0x\(String(value, radix: 16, uppercase: true)) "
            + "(instruction pointer 0x\(String(finding.line.address, radix: 16, uppercase: true)))")
      case .exception(let code):
        lines.append("  exception 0x\(String(code, radix: 16, uppercase: true))")
      }
      lines += finding.patterns.map { "  - \($0)" }
      lines.append("  log line: \(finding.line.text)")
    }
    let repeats = Dictionary(grouping: findings.compactMap(\.rva), by: { $0 })
      .filter { $0.value.count > 1 }
    for (rva, hits) in repeats.sorted(by: { $0.key < $1.key }) {
      lines.append("")
      lines.append(
        "the same place, nfs16+0x\(String(rva, radix: 16, uppercase: true)), faulted "
          + "\(hits.count) times in this session")
    }
    return lines
  }

  private static func displaySection(digest: NFS2015LogDigest, context: NFS2015CrashContext)
    -> [String]
  {
    var lines = ["== Display =="]
    lines.append(context.display?.summary ?? "main display: could not be read")
    let modes = digest.displayModes.map { "\($0.mode) x\($0.count)" }.joined(separator: ", ")
    lines.append("display modes the game set: \(modes.isEmpty ? "none seen" : modes)")
    lines.append(
      "display safety: limit retina desktop "
        + "\(context.diagnostics.limitRetinaDesktop ? "on" : "off"), safe first resolution "
        + "\(context.diagnostics.seedSafeResolution ? "on" : "off")")
    lines.append(
      "RetinaMode recorded for this launch: "
        + (context.displayPlan.retinaMode.map { $0 ? "Y" : "N" } ?? "recipe value (not managed)"))
    lines.append("desktop Wine advertises: \(context.displayPlan.wineDesktop?.text ?? "unknown")")
    lines += context.displayPlan.reasons.map { "  - \($0)" }
    lines.append("first-run seed: \(context.seed?.sentence ?? "not considered")")
    return lines
  }
}
