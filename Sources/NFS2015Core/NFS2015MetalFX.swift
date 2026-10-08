import Foundation
import LauncherCore

/// The MetalFX spatial upscaler of DXMT, the Direct3D 11 layer the game runs on.
///
/// This is not a game option and never reaches the game's own options file. DXMT reads it from
/// its environment when the game creates its swap chain, so the app hands it over as environment
/// variables for the game's executable alone (see `ExecutableEnvironment`): the EA app and its
/// browser helpers, which also run on DXMT, are left exactly as they were.
///
/// The only options offered are the two DXMT v0.80 documents for this feature
/// (`docs/CUSTOMIZATION.md` and `dxmt.conf`): the environment variable that turns the upscaler
/// on, and the scale factor. DXMT has no quality mode for it. DXMT v0.80 also holds a temporal
/// upscaler, but it is reachable only through DLSS calls that this game never makes, and it has
/// no frame generation or denoiser, so none of those is offered.
package enum NFS2015MetalFX {
  /// The environment variable that makes DXMT upscale its swap chain output with MetalFX.
  package static let switchVariable = "DXMT_METALFX_SPATIAL_SWAPCHAIN"
  /// The environment variable that carries DXMT configuration in the same syntax as `dxmt.conf`.
  package static let configurationVariable = "DXMT_CONFIG"
  /// The only DXMT option written into that configuration.
  package static let factorOption = "d3d11.metalSpatialUpscaleFactor"

  /// The executable the settings apply to.
  package static var executable: String { GameKind.nfs2015.executable }

  /// The player-facing name of the group on the settings page.
  package static let title = "MetalFX"

  /// The status the settings page shows beside the group's name and the toggle. Two of two
  /// launches with MetalFX on that reached a display-mode change faulted at the same place
  /// (`0x1B30159`), and none of 17 launches with it off did; why is not known (see
  /// `docs/NFS2015.md` section 25). It stays off by default.
  package static let statusLabel = "experimental, known to crash NFS16"

  /// The group's heading, with its status.
  package static var heading: String { "\(title) (\(statusLabel))" }

  /// The warning printed with the factor's explanation.
  package static let crashWarning = """
    With MetalFX on, the game faulted at the same place in every launch that got as far as a \
    display-mode change (2 launches on 2 Macs, 2026-10-07 and 2026-10-08), and it did not in 17 \
    launches with MetalFX off. Why is not known, and the scale factor is not known to matter. \
    Leave it off to play; turn it on only to help find the cause.
    """

  /// The environment this preference gives the game's executable; nil when it is off.
  package static func environment(for preference: NFS2015MetalFXPreference)
    -> ExecutableEnvironment?
  {
    guard preference.spatialUpscaling else { return nil }
    return ExecutableEnvironment(
      executable: executable,
      entries: [
        .init(name: switchVariable, value: "1"),
        .init(
          name: configurationVariable, value: "\(factorOption)=\(preference.factor.rawValue)"),
      ])
  }

  /// The size DXMT presents when the game's swap chain is `width` by `height`.
  ///
  /// DXMT multiplies each side by the factor as single-precision numbers and drops the fraction.
  package static func outputSize(
    width: Int, height: Int, factor: NFS2015UpscaleFactor
  ) -> (width: Int, height: Int) {
    let scale = factor.singlePrecisionValue
    return (Int(Float(width) * scale), Int(Float(height) * scale))
  }

  /// One short statement of the arithmetic at the game's resolution, and a warning when the
  /// presented size is larger than the display can show.
  ///
  /// What the player sees on screen is not claimed: that is what the player tests in the game.
  package static func summary(
    game: (width: Int, height: Int)?, factor: NFS2015UpscaleFactor,
    display: (width: Int, height: Int)?
  ) -> String {
    guard let game else {
      return """
        The game's resolution is not known until it has written its options file, so the size \
        DXMT would present cannot be shown yet.
        """
    }
    let output = outputSize(width: game.width, height: game.height, factor: factor)
    var text =
      "The game draws \(game.width)x\(game.height) and DXMT presents \(output.width)x\(output.height)."
    guard let display else { return text }
    if output.width > display.width || output.height > display.height {
      text += """
         That is larger than this display's \(display.width)x\(display.height) pixels, so it is \
        shrunk again on the way to the screen: more GPU work for no extra detail on this display.
        """
    } else {
      text += " This display shows \(display.width)x\(display.height) pixels."
    }
    return text
  }
}

/// A scale factor DXMT accepts: its documentation allows 1.0 to 2.0, and the app offers steps in
/// that range. Each raw value is written to DXMT exactly as it appears here.
package enum NFS2015UpscaleFactor: String, CaseIterable, Codable, Sendable {
  case x125 = "1.25"
  case x133 = "1.33"
  case x150 = "1.5"
  case x175 = "1.75"
  case x200 = "2.0"

  /// DXMT's own default is 2.0; the app starts lower so that a first try is not the heaviest one.
  package static let `default` = Self.x150

  package var title: String {
    switch self {
    case .x125: "1.25x"
    case .x133: "1.33x (1080p becomes about 1440p)"
    case .x150: "1.5x"
    case .x175: "1.75x"
    case .x200: "2x (DXMT's own default)"
    }
  }

  /// The value DXMT reads, as the single-precision number it keeps.
  var singlePrecisionValue: Float { Float(Double(rawValue) ?? 1) }
}

/// What the player chose for MetalFX: off, or the spatial upscaler with a factor.
///
/// The default is off, and a missing, damaged or unrecognized saved file means off, so a player
/// who never opens this page runs the game exactly as before.
package struct NFS2015MetalFXPreference: Codable, Equatable, Sendable {
  package static let current = 1
  package static let off = Self(spatialUpscaling: false, factor: .default)

  package var spatialUpscaling: Bool
  package var factor: NFS2015UpscaleFactor

  package init(spatialUpscaling: Bool, factor: NFS2015UpscaleFactor) {
    self.spatialUpscaling = spatialUpscaling
    self.factor = factor
  }

  private enum CodingKeys: String, CodingKey {
    case version, spatialUpscaling, factor
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.current else {
      throw DecodingError.dataCorruptedError(
        forKey: .version, in: container, debugDescription: "Unsupported version \(version).")
    }
    spatialUpscaling = try container.decode(Bool.self, forKey: .spatialUpscaling)
    factor = try container.decode(NFS2015UpscaleFactor.self, forKey: .factor)
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.current, forKey: .version)
    try container.encode(spatialUpscaling, forKey: .spatialUpscaling)
    try container.encode(factor, forKey: .factor)
  }
}

/// One change to the MetalFX preference, as the starter asks the session helper to make it.
package struct NFS2015MetalFXRequest: Codable, Equatable, Sendable {
  package enum Action: String, Codable, Sendable {
    /// Keep `preference`.
    case save
    /// Forget the saved preference, which means MetalFX off.
    case reset
  }

  package let action: Action
  package let preference: NFS2015MetalFXPreference?

  package init(action: Action, preference: NFS2015MetalFXPreference? = nil) {
    self.action = action
    self.preference = preference
  }

  package func validate() throws(LauncherError) {
    switch (action, preference) {
    case (.save, .some), (.reset, .none): return
    case (.save, .none): throw .operation("A MetalFX save needs the choice to keep.")
    case (.reset, .some): throw .operation("A MetalFX reset cannot also carry a choice.")
    }
  }
}

/// What the last MetalFX request did, for the starter to show.
package enum NFS2015MetalFXOutcome: Codable, Equatable, Sendable {
  case saved
  case reset
  /// The saved choice already matched; nothing was written.
  case unchanged
  /// Nothing was changed, for this reason.
  case refused(String)

  package var refusal: String? {
    if case .refused(let reason) = self { return reason }
    return nil
  }
}

/// The MetalFX state the starter shows after any helper operation.
package struct NFS2015MetalFXState: Codable, Equatable, Sendable {
  /// What the next launch will use.
  package var preference: NFS2015MetalFXPreference
  /// Set when the saved file could not be used, so the game starts with MetalFX off.
  package var notice: String?
  package var outcome: NFS2015MetalFXOutcome?

  package init(
    preference: NFS2015MetalFXPreference = .off, notice: String? = nil,
    outcome: NFS2015MetalFXOutcome? = nil
  ) {
    self.preference = preference
    self.notice = notice
    self.outcome = outcome
  }
}
