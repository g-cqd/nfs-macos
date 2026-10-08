import Foundation
import LauncherCore

/// Whether the next Play runs the Windows programs of this app's Wine session through the x87
/// sidecar.
///
/// The default is off, and a missing, damaged or unrecognised saved file means off (see
/// `NFS2015SidecarStore`). The choice is a prior, not a measurement: the game is a 64-bit program
/// with little x87 code, so the sidecar's benefit is expected to be small for it while every
/// translated block costs a round trip to another process, and every crash logged on the first
/// Mac happened with the sidecar attached. Nothing has been measured on this game with it off or
/// on, and `docs/NFS2015.md` section 21 says how to compare. The file belongs to this app; Wine
/// reads only the environment variable the choice becomes.
package struct NFS2015SidecarPreference: Codable, Equatable, Sendable {
  package static let current = 1
  package static let standard = Self(enabled: false)

  /// Attach `ROSETTA_X87_PATH` to the Wine session, so 32-bit processes run through the sidecar.
  package var enabled: Bool

  package init(enabled: Bool) { self.enabled = enabled }

  private enum CodingKeys: String, CodingKey {
    case version, enabled
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.current else {
      throw DecodingError.dataCorruptedError(
        forKey: .version, in: container, debugDescription: "Unsupported version \(version).")
    }
    enabled = try container.decode(Bool.self, forKey: .enabled)
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.current, forKey: .version)
    try container.encode(enabled, forKey: .enabled)
  }
}

/// One change to the sidecar preference, as the starter asks the session helper to make it.
package struct NFS2015SidecarRequest: Codable, Equatable, Sendable {
  package enum Action: String, Codable, Sendable {
    /// Keep `preference`.
    case save
    /// Forget the saved preference, which means the sidecar off.
    case reset
  }

  package let action: Action
  package let preference: NFS2015SidecarPreference?

  package init(action: Action, preference: NFS2015SidecarPreference? = nil) {
    self.action = action
    self.preference = preference
  }

  package func validate() throws(LauncherError) {
    switch (action, preference) {
    case (.save, .some), (.reset, .none): return
    case (.save, .none): throw .operation("A sidecar save needs the choice to keep.")
    case (.reset, .some): throw .operation("A sidecar reset cannot also carry a choice.")
    }
  }
}

/// What the last sidecar request did. It reads like the MetalFX one, and means the same.
package typealias NFS2015SidecarOutcome = NFS2015MetalFXOutcome

/// The sidecar state the starter shows after any helper operation.
package struct NFS2015SidecarState: Codable, Equatable, Sendable {
  /// What the next Play will use, before any developer override.
  package var preference: NFS2015SidecarPreference
  /// Set when the saved file could not be used, so the sidecar is off.
  package var notice: String?
  package var outcome: NFS2015SidecarOutcome?

  package init(
    preference: NFS2015SidecarPreference = .standard, notice: String? = nil,
    outcome: NFS2015SidecarOutcome? = nil
  ) {
    self.preference = preference
    self.notice = notice
    self.outcome = outcome
  }
}

/// The sidecar state one Play uses, and why: the single place that joins the saved preference with
/// a developer's `NFS2015_AB_SIDECAR` override.
package struct NFS2015SidecarChoice: Equatable, Sendable {
  package enum Source: Equatable, Sendable {
    /// Nothing was chosen: the shipped default, off.
    case standard
    /// The player's saved preference.
    case preference
    /// A developer's `NFS2015_AB_SIDECAR`, which wins over the saved preference.
    case experiment
  }

  /// Whether `ROSETTA_X87_PATH` is attached to the Wine session.
  package let enabled: Bool
  package let source: Source

  package init(preference: NFS2015SidecarPreference, experiment: NFS2015ExperimentOverrides) {
    if let forced = experiment.sidecar {
      enabled = forced
      source = .experiment
    } else {
      enabled = preference.enabled
      source = preference == .standard ? .standard : .preference
    }
  }

  /// One short statement for the session log and the crash report.
  package var line: String {
    let state = enabled ? "on" : "off"
    switch source {
    case .standard: return "\(state) (default)"
    case .preference: return "\(state) (saved setting)"
    case .experiment: return "\(state) (experiment override)"
    }
  }
}
