import Foundation
import LauncherCore

/// What the player allowed for display safety and for the next launch's diagnostic log.
///
/// The defaults are the safe-first-run choices on and diagnostic logging off. A missing, damaged
/// or unrecognised saved file means these defaults, never a failure (see
/// `NFS2015DiagnosticsStore`). The file belongs to this app; the game never reads it.
package struct NFS2015DiagnosticsPreference: Codable, Equatable, Sendable {
  package static let current = 1
  package static let standard = Self()

  /// Record `RetinaMode=N` when the doubled desktop is larger than has been seen to work
  /// (see `NFS2015DisplaySafety`). Off leaves the recipe's value, and restores it.
  package var limitRetinaDesktop: Bool
  /// Seed a safe resolution into a game that has no options file yet. Never touches a file the
  /// game wrote.
  package var seedSafeResolution: Bool
  /// Run the next Play with the diagnostic Wine log (`NFS2015DiagnosticLog`), then switch off.
  package var diagnosticLoggingNextLaunch: Bool

  package init(
    limitRetinaDesktop: Bool = true, seedSafeResolution: Bool = true,
    diagnosticLoggingNextLaunch: Bool = false
  ) {
    self.limitRetinaDesktop = limitRetinaDesktop
    self.seedSafeResolution = seedSafeResolution
    self.diagnosticLoggingNextLaunch = diagnosticLoggingNextLaunch
  }

  private enum CodingKeys: String, CodingKey {
    case version, limitRetinaDesktop, seedSafeResolution, diagnosticLoggingNextLaunch
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.current else {
      throw DecodingError.dataCorruptedError(
        forKey: .version, in: container, debugDescription: "Unsupported version \(version).")
    }
    limitRetinaDesktop = try container.decode(Bool.self, forKey: .limitRetinaDesktop)
    seedSafeResolution = try container.decode(Bool.self, forKey: .seedSafeResolution)
    diagnosticLoggingNextLaunch = try container.decode(
      Bool.self, forKey: .diagnosticLoggingNextLaunch)
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.current, forKey: .version)
    try container.encode(limitRetinaDesktop, forKey: .limitRetinaDesktop)
    try container.encode(seedSafeResolution, forKey: .seedSafeResolution)
    try container.encode(diagnosticLoggingNextLaunch, forKey: .diagnosticLoggingNextLaunch)
  }
}

/// One change to the diagnostics preference, as the starter asks the session helper to make it.
package struct NFS2015DiagnosticsRequest: Codable, Equatable, Sendable {
  package enum Action: String, Codable, Sendable {
    /// Keep `preference`.
    case save
    /// Forget the saved preference, which means the defaults.
    case reset
  }

  package let action: Action
  package let preference: NFS2015DiagnosticsPreference?

  package init(action: Action, preference: NFS2015DiagnosticsPreference? = nil) {
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

/// What the last diagnostics request did. It reads like the MetalFX one, and means the same.
package typealias NFS2015DiagnosticsOutcome = NFS2015MetalFXOutcome

/// The diagnostics state the starter shows after any helper operation.
package struct NFS2015DiagnosticsState: Codable, Equatable, Sendable {
  /// What the next launch will use.
  package var preference: NFS2015DiagnosticsPreference
  /// Set when the saved file could not be used, so the defaults apply.
  package var notice: String?
  package var outcome: NFS2015DiagnosticsOutcome?
  /// What the display rule decided at the last launch, in the log's own words; nil before one.
  package var displayNote: String?

  package init(
    preference: NFS2015DiagnosticsPreference = .standard, notice: String? = nil,
    outcome: NFS2015DiagnosticsOutcome? = nil, displayNote: String? = nil
  ) {
    self.preference = preference
    self.notice = notice
    self.outcome = outcome
    self.displayNote = displayNote
  }
}
