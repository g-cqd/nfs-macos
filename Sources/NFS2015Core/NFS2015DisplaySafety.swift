import Foundation
import LauncherCore

/// What to do about the display before the game starts, decided from the display alone.
package struct NFS2015DisplaySafetyPlan: Equatable, Sendable {
  /// The `RetinaMode` value to record in the prefix; nil leaves the recipe's value alone.
  package let retinaMode: Bool?
  /// The desktop Wine will advertise, and so the mode a game without a saved file starts in.
  package let wineDesktop: NFS2015DisplayFacts.Size?
  /// The resolution to seed into a game that has no options file yet; nil seeds nothing.
  package let seed: NFS2015DisplayFacts.Size?
  /// What was decided and why, one sentence each, for the log and the crash report.
  package let reasons: [String]

  package static let unmanaged = Self(retinaMode: nil, wineDesktop: nil, seed: nil, reasons: [])
}

/// The first-run display rule: the Wine desktop and the game's first resolution never go beyond
/// what has been seen to work.
///
/// **Evidence.** On the built-in 2560x1600 panel of an M1 MacBook Air (1680x1050 points) the
/// Wine desktop was 3360x2100, 1.72 times the panel's pixels and 7,056,000 pixels, in about a
/// dozen launches that got as far as the game's menus **[verified]**. On a 3840x2160 external
/// screen (as the player reports) the desktop was 7680x4320, four times the panel's pixels and
/// 33,177,600 pixels, and both launches ended within seconds in a call through a null function
/// pointer **[verified in the log]**. That the size is the cause is **not proven**.
///
/// **Rule.** Keep `RetinaMode` on only while the desktop it gives stays within 1.75 times the
/// panel's pixels (the one ratio seen working, rounded up) and within 3840x2160. Otherwise record
/// `RetinaMode=N`, so Wine advertises the point size: on a display that is not scaled that is the
/// panel's own size, and doubling it bought nothing. If the desktop is still larger than any
/// seen working and the game has no options file yet, seed a resolution (see
/// `NFS2015FirstRunOptions`). The three numbers are judgements between one working and one
/// failing observation, so they are named constants with their reasons, not facts.
///
/// **Not verified.** None of this has run on a screen like the failing one.
package enum NFS2015DisplaySafety {
  /// The largest Wine desktop seen working: 3360x2100.
  static let provenDesktopPixels = 3360 * 2100
  /// The only desktop-to-panel pixel ratio seen working (3360x2100 on 2560x1600), rounded up to 7/4.
  static let ratioNumerator = 7
  static let ratioDenominator = 4
  /// The largest desktop for which `RetinaMode` is kept: native 4K. It admits every built-in
  /// MacBook Pro panel at its default scaling and a 4K screen in a scaled mode that shows
  /// 1920x1080, and rules out 5K and larger and every case that quadruples a 1x display.
  static let retinaCeilingPixels = 3840 * 2160
  /// The pixel budget of a seeded resolution: 2560x1600, the game resolution that ran **[verified]**.
  static let seedPixels = 2560 * 1600

  /// Standard modes the game can be asked for, each within `seedPixels`.
  static let standardModes: [NFS2015DisplayFacts.Size] = [
    (1024, 768), (1280, 960), (1600, 1200), (2048, 1536),  // 4:3
    (1280, 1024),  // 5:4
    (1440, 960), (2160, 1440),  // 3:2
    (1280, 800), (1440, 900), (1680, 1050), (1920, 1200), (2560, 1600),  // 16:10
    (1280, 720), (1600, 900), (1920, 1080), (2560, 1440),  // 16:9
    (2560, 1080),  // 21:9
  ].map { NFS2015DisplayFacts.Size(width: $0.0, height: $0.1) }

  /// Whether `RetinaMode` may stay on for this display.
  static func allowsRetinaDesktop(_ facts: NFS2015DisplayFacts) -> Bool {
    let desktop = facts.retinaDesktop.pixelCount
    return desktop <= retinaCeilingPixels
      && desktop * ratioDenominator <= facts.reference.pixelCount * ratioNumerator
  }

  /// The largest standard mode within `seedPixels` whose shape is closest to the desktop's.
  static func safeResolution(for desktop: NFS2015DisplayFacts.Size) -> NFS2015DisplayFacts.Size {
    let target = Double(desktop.width) / Double(max(1, desktop.height))
    func distance(_ mode: NFS2015DisplayFacts.Size) -> Double {
      abs(log(Double(mode.width) / Double(mode.height) / target))
    }
    return standardModes.filter { $0.pixelCount <= seedPixels }
      .min {
        let (left, right) = (distance($0), distance($1))
        return left == right ? $0.pixelCount > $1.pixelCount : left < right
      } ?? NFS2015DisplayFacts.Size(width: 1280, height: 720)
  }

  /// Decides for the display as it is now.
  /// - Parameters:
  ///   - facts: The main display; nil means it could not be read, and nothing is managed.
  ///   - hasOptionsFile: Whether the game has already written its options file. Nil when that
  ///     could not be told, which seeds nothing.
  ///   - preference: What the player allowed.
  ///   - recipeRetina: Whether the recipe turns `RetinaMode` on, which it does for this game.
  package static func plan(
    facts: NFS2015DisplayFacts?, hasOptionsFile: Bool?, preference: NFS2015DiagnosticsPreference,
    recipeRetina: Bool = true
  ) -> NFS2015DisplaySafetyPlan {
    guard let facts, preference.limitRetinaDesktop || preference.seedSafeResolution else {
      return .unmanaged
    }
    var reasons: [String] = []
    var retina: Bool?
    var desktop = recipeRetina ? facts.retinaDesktop : facts.logicalDesktop
    if preference.limitRetinaDesktop {
      let allowed = allowsRetinaDesktop(facts)
      retina = allowed
      desktop = allowed ? facts.retinaDesktop : facts.logicalDesktop
      reasons.append(
        allowed
          ? "RetinaMode stays on: the desktop \(desktop.text) is within 1.75 times the panel's "
            + "pixels and within 3840x2160."
          : "RetinaMode is turned off: doubling would make the desktop "
            + "\(facts.retinaDesktop.text), beyond 1.75 times the panel's pixels or beyond "
            + "3840x2160, so Wine advertises \(desktop.text).")
    }
    var seed: NFS2015DisplayFacts.Size?
    if preference.seedSafeResolution, hasOptionsFile == false,
      desktop.pixelCount > provenDesktopPixels
    {
      let mode = safeResolution(for: desktop)
      seed = mode
      reasons.append(
        "The game has no options file and its first desktop would be \(desktop.text), larger than "
          + "any seen working, so it is asked to start at \(mode.text).")
    }
    return NFS2015DisplaySafetyPlan(
      retinaMode: retina, wineDesktop: desktop, seed: seed, reasons: reasons)
  }

  /// The recipe's registry values with `RetinaMode` set as the plan says.
  ///
  /// Only an existing `RetinaMode` string value of `Y` is replaced (a recipe that turns it off is
  /// left alone), and nothing is added,
  /// so the existing "record what is missing" step imports exactly this value: on a prefix that
  /// already holds `Y` it imports `N` when the display needs it and `Y` again when it does not.
  package static func settings(_ declared: [RegistrySetting], plan: NFS2015DisplaySafetyPlan)
    -> [RegistrySetting]
  {
    guard let retina = plan.retinaMode else { return declared }
    return declared.map { setting in
      guard setting.hive == .currentUser, setting.path == "Software\\Wine\\Mac Driver",
        setting.name == "RetinaMode", setting.kind == .string, setting.value == "Y"
      else { return setting }
      return RegistrySetting(
        hive: setting.hive, path: setting.path, name: setting.name, value: retina ? "Y" : "N",
        kind: .string,
        reason: retina
          ? setting.reason
          : "The display is not one the doubled desktop is known to work on, so Wine advertises "
            + "the point size")
    }
  }
}
