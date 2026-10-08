import Foundation
import LauncherCore

/// Which of the Wine experiment switches the next Play sets (`WineExperimentSwitches`).
///
/// All three are off by default, and a missing, damaged or unrecognized saved file means off. They
/// exist to find out why `NFS16.exe` faults at `0x1B30159`; nothing about them is known to help.
/// The file belongs to this app; Wine reads only the environment variables the choice becomes.
package struct NFS2015WineExperimentsPreference: Codable, Equatable, Sendable {
  package static let current = 1
  package static let standard = Self()

  /// `WINE_ROSETTA_FLUSH_TOGGLE=1`.
  package var flushToggle: Bool
  /// `WINE_ROSETTA_PROTECT_TOGGLE=1`.
  package var protectToggle: Bool
  /// `WINE_TRACE_PAGE` with `WineExperimentSwitches.presetTraceWindow`.
  package var tracePage: Bool
  /// `WINE_RWX_WX_EMULATION=1`, the workaround for the Rosetta 2 late-resume defect.
  package var rwxWxEmulation: Bool

  package init(
    flushToggle: Bool = false, protectToggle: Bool = false, tracePage: Bool = false,
    rwxWxEmulation: Bool = false
  ) {
    self.flushToggle = flushToggle
    self.protectToggle = protectToggle
    self.tracePage = tracePage
    self.rwxWxEmulation = rwxWxEmulation
  }

  private enum CodingKeys: String, CodingKey {
    case version, flushToggle, protectToggle, tracePage, rwxWxEmulation
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.current else {
      throw DecodingError.dataCorruptedError(
        forKey: .version, in: container, debugDescription: "Unsupported version \(version).")
    }
    flushToggle = try container.decode(Bool.self, forKey: .flushToggle)
    protectToggle = try container.decode(Bool.self, forKey: .protectToggle)
    tracePage = try container.decode(Bool.self, forKey: .tracePage)
    // A file the -0007 apps wrote has no such key: that is off, not a damaged file.
    rwxWxEmulation = try container.decodeIfPresent(Bool.self, forKey: .rwxWxEmulation) ?? false
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.current, forKey: .version)
    try container.encode(flushToggle, forKey: .flushToggle)
    try container.encode(protectToggle, forKey: .protectToggle)
    try container.encode(tracePage, forKey: .tracePage)
    try container.encode(rwxWxEmulation, forKey: .rwxWxEmulation)
  }
}

/// One change to the Wine experiment switches, as the starter asks the session helper to make it.
package struct NFS2015WineExperimentsRequest: Codable, Equatable, Sendable {
  package enum Action: String, Codable, Sendable {
    /// Keep `preference`.
    case save
    /// Forget the saved preference, which means every switch off.
    case reset
  }

  package let action: Action
  package let preference: NFS2015WineExperimentsPreference?

  package init(action: Action, preference: NFS2015WineExperimentsPreference? = nil) {
    self.action = action
    self.preference = preference
  }

  package func validate() throws(LauncherError) {
    switch (action, preference) {
    case (.save, .some), (.reset, .none): return
    case (.save, .none): throw .operation("A save needs the choice to keep.")
    case (.reset, .some): throw .operation("A reset cannot also carry a choice.")
    }
  }
}

/// What the last request did. It reads like the MetalFX one, and means the same.
package typealias NFS2015WineExperimentsOutcome = NFS2015MetalFXOutcome

/// The switch state the starter shows after any helper operation.
package struct NFS2015WineExperimentsState: Codable, Equatable, Sendable {
  /// What the next Play will use, before any developer override.
  package var preference: NFS2015WineExperimentsPreference
  /// Set when the saved file could not be used, so every switch is off.
  package var notice: String?
  package var outcome: NFS2015WineExperimentsOutcome?

  package init(
    preference: NFS2015WineExperimentsPreference = .standard, notice: String? = nil,
    outcome: NFS2015WineExperimentsOutcome? = nil
  ) {
    self.preference = preference
    self.notice = notice
    self.outcome = outcome
  }
}

/// The switches one Play sets, and why: the single place that joins the saved preference with a
/// developer's `NFS2015_AB_WINE_*` overrides. A switch an override names wins, on or off.
package struct NFS2015WineExperimentsChoice: Equatable, Sendable {
  package enum Source: Equatable, Sendable {
    case preference
    case experiment
  }

  /// The environment variables to set; empty when every switch is off.
  package let environment: [String: String]
  private let sources: [String: Source]
  /// Switches an override turned off that the saved preference had on.
  private let overriddenOff: [String]

  package init(preference: NFS2015WineExperimentsPreference, experiment: NFS2015ExperimentOverrides)
  {
    var environment: [String: String] = [:]
    var sources: [String: Source] = [:]
    var off: [String] = []
    func toggle(_ name: String, saved: Bool, forced: Bool?) {
      if let forced {
        if forced {
          environment[name] = "1"
          sources[name] = .experiment
        } else if saved {
          off.append(name)
        }
      } else if saved {
        environment[name] = "1"
        sources[name] = .preference
      }
    }
    toggle(
      WineExperimentSwitches.flushToggle, saved: preference.flushToggle,
      forced: experiment.flushToggle)
    toggle(
      WineExperimentSwitches.protectToggle, saved: preference.protectToggle,
      forced: experiment.protectToggle)
    toggle(
      WineExperimentSwitches.rwxWxEmulation, saved: preference.rwxWxEmulation,
      forced: experiment.rwxWxEmulation)
    if let limit = experiment.rwxHotLimit {
      environment[WineExperimentSwitches.rwxHotLimit] = limit
      sources[WineExperimentSwitches.rwxHotLimit] = .experiment
    }
    if let window = experiment.tracePage {
      if window == NFS2015ExperimentOverrides.off {
        if preference.tracePage { off.append(WineExperimentSwitches.tracePage) }
      } else {
        environment[WineExperimentSwitches.tracePage] = window
        sources[WineExperimentSwitches.tracePage] = .experiment
      }
    } else if preference.tracePage {
      environment[WineExperimentSwitches.tracePage] = WineExperimentSwitches.presetTraceWindow
      sources[WineExperimentSwitches.tracePage] = .preference
    }
    self.environment = environment
    self.sources = sources
    self.overriddenOff = off
  }

  package static let standard = Self(
    preference: .standard, experiment: NFS2015ExperimentOverrides())

  package var isActive: Bool { !environment.isEmpty }

  /// Whether `WINE_RWX_WX_EMULATION` is set, so the runtime prints `wine-rwx:` lines.
  package var emulatesWriteXorExecute: Bool {
    environment[WineExperimentSwitches.rwxWxEmulation] != nil
  }

  /// Whether the switch that makes the runtime print `wine-trace:` lines is set.
  package var tracesPages: Bool { environment[WineExperimentSwitches.tracePage] != nil }

  /// One short statement for the session log and the crash report.
  package var line: String {
    var parts = WineExperimentSwitches.names.compactMap { name -> String? in
      guard let value = environment[name], let source = sources[name] else { return nil }
      return "\(name)=\(value) (\(source == .preference ? "saved setting" : "experiment override"))"
    }
    parts += overriddenOff.sorted().map { "\($0) off (experiment override)" }
    return parts.isEmpty ? "none (all off, the default)" : parts.joined(separator: ", ")
  }
}
