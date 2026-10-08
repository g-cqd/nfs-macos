import Foundation
import LauncherCore

/// Switches for comparing runtime settings by hand, read from the session helper's own
/// environment.
///
/// The starter runs the helper with a bare environment, so a player never reaches these. A
/// developer running the helper from Terminal can name them to repeat launches under different
/// runtime settings (see the A/B procedure in `docs/NFS2015.md`): the x87 sidecar forced on or
/// off, which wins over the player's saved preference, and the execution-breakpoint switches
/// `WINE_TF_*` of the bundle's recipe. Each override is validated
/// like the recipe's own value, written to the session log, and recorded in every crash report so
/// a crash is always counted against the setting that was in force.
package struct NFS2015ExperimentOverrides: Equatable, Sendable {
  static let sidecarVariable = "NFS2015_AB_SIDECAR"
  static let tuningPrefix = "NFS2015_AB_"

  /// Forces the x87 sidecar on (`ROSETTA_X87_PATH` set) or off (left out of the environment)
  /// whatever the saved preference says; nil leaves the preference in force.
  package var sidecar: Bool?
  /// `WINE_TF_*` values that replace the recipe's.
  package var tuning: [String: String] = [:]
  /// Forces `WINE_ROSETTA_FLUSH_TOGGLE` on or off whatever the saved setting says; nil leaves it.
  package var flushToggle: Bool?
  /// Forces `WINE_ROSETTA_PROTECT_TOGGLE` on or off; nil leaves the saved setting.
  package var protectToggle: Bool?
  /// `WINE_TRACE_PAGE` window as `<hexstart>-<hexend>`, or `off`; nil leaves the saved setting.
  package var tracePage: String?

  /// The value that turns the page trace off.
  static let off = "off"

  package init() {}

  package var isActive: Bool {
    sidecar != nil || !tuning.isEmpty || flushToggle != nil || protectToggle != nil
      || tracePage != nil
  }

  /// - Throws: A failure for a value that is not accepted, so a typo never runs as a different
  ///   experiment than the one intended.
  package init(environment: [String: String]) throws(LauncherError) {
    if let sidecar = environment[Self.sidecarVariable] {
      guard ["on", "off"].contains(sidecar) else {
        throw .operation("\(Self.sidecarVariable) must be on or off.")
      }
      self.sidecar = sidecar == "on"
    }
    flushToggle = try Self.toggle(environment, WineExperimentSwitches.flushToggle)
    protectToggle = try Self.toggle(environment, WineExperimentSwitches.protectToggle)
    if let window = environment[Self.tuningPrefix + WineExperimentSwitches.tracePage] {
      guard window == Self.off || WineExperimentSwitches.isTraceWindow(window) else {
        throw .operation(
          "\(Self.tuningPrefix + WineExperimentSwitches.tracePage) must be <hexstart>-<hexend> "
            + "with the end above the start, or off.")
      }
      tracePage = window
    }
    for name in RuntimeTuning.supportedNames {
      guard let value = environment[Self.tuningPrefix + name] else { continue }
      tuning[name] = value
    }
    try RuntimeTuning(tuning).validate()
  }

  private static func toggle(_ environment: [String: String], _ name: String)
    throws(LauncherError) -> Bool?
  {
    guard let value = environment[tuningPrefix + name] else { return nil }
    guard value == "0" || value == "1" else {
      throw .operation("\(tuningPrefix + name) must be 0 or 1.")
    }
    return value == "1"
  }

  /// The recipe's switches with these applied over them.
  package func applied(to recipe: RuntimeTuning) throws(LauncherError) -> RuntimeTuning {
    guard !tuning.isEmpty else { return recipe }
    var values = try recipe.environment()
    for (name, value) in tuning { values[name] = value }
    let merged = RuntimeTuning(values)
    try merged.validate()
    return merged
  }

  /// One line for the log and the report.
  package var summary: String {
    guard isActive else { return "none" }
    var parts = tuning.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    if let flushToggle {
      parts.append("\(WineExperimentSwitches.flushToggle)=\(flushToggle ? 1 : 0)")
    }
    if let protectToggle {
      parts.append("\(WineExperimentSwitches.protectToggle)=\(protectToggle ? 1 : 0)")
    }
    if let tracePage { parts.append("\(WineExperimentSwitches.tracePage)=\(tracePage)") }
    if let sidecar { parts.insert("x87 sidecar \(sidecar ? "on" : "off")", at: 0) }
    return parts.joined(separator: ", ")
  }
}
