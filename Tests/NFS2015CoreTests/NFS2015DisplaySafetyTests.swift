import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

/// The displays are fixtures. The two that were measured are the built-in panel of an M1
/// MacBook Air, where the game ran, and a 4K external screen, where it did not.
struct NFS2015DisplaySafetyTests {
  typealias Size = NFS2015DisplayFacts.Size

  static func facts(
    points: (Int, Int), pixels: (Int, Int), native: (Int, Int)?, builtIn: Bool = false,
    displays: Int = 1
  ) -> NFS2015DisplayFacts {
    NFS2015DisplayFacts(
      points: Size(width: points.0, height: points.1),
      pixels: Size(width: pixels.0, height: pixels.1),
      native: native.map { Size(width: $0.0, height: $0.1) }, isBuiltIn: builtIn,
      displayCount: displays)
  }

  /// This Mac: 2560x1600 panel looking like 1680x1050. Wine's desktop was 3360x2100 and it worked.
  static let macBookAir = facts(
    points: (1680, 1050), pixels: (3360, 2100), native: (2560, 1600), builtIn: true)
  /// The other Mac's screen: 4K, not scaled. Wine's desktop was 7680x4320 and the game died.
  static let external4K = facts(points: (3840, 2160), pixels: (3840, 2160), native: (3840, 2160))
  static let fullHD = facts(points: (1920, 1080), pixels: (1920, 1080), native: (1920, 1080))
  static let fiveK = facts(points: (2560, 1440), pixels: (5120, 2880), native: (5120, 2880))
  static let sixK = facts(points: (3008, 1692), pixels: (6016, 3384), native: (6016, 3384))
  static let macBookPro14 = facts(
    points: (1512, 982), pixels: (3024, 1964), native: (3024, 1964), builtIn: true)
  static let macBookPro16 = facts(
    points: (1728, 1117), pixels: (3456, 2234), native: (3456, 2234), builtIn: true)

  private func plan(
    _ facts: NFS2015DisplayFacts?, file: Bool? = false,
    preference: NFS2015DiagnosticsPreference = .standard
  ) -> NFS2015DisplaySafetyPlan {
    NFS2015DisplaySafety.plan(facts: facts, hasOptionsFile: file, preference: preference)
  }

  @Test
  func `leaves the built-in panel where the game ran exactly as it was`() {
    let result = plan(Self.macBookAir)
    #expect(result.retinaMode == true)
    #expect(result.wineDesktop == Size(width: 3360, height: 2100))
    #expect(result.seed == nil)
  }

  @Test
  func `turns Retina mode off on the 4K screen and starts the game below its desktop`() {
    let result = plan(Self.external4K)
    #expect(Self.external4K.retinaDesktop == Size(width: 7680, height: 4320))
    #expect(result.retinaMode == false)
    #expect(result.wineDesktop == Size(width: 3840, height: 2160))
    #expect(result.seed == Size(width: 2560, height: 1440))
    #expect(result.reasons.count == 2)
  }

  @Test(
    arguments: [
      ("a 1080p screen", NFS2015DisplaySafetyTests.fullHD, false, 1920, 1080),
      ("a 5K Retina display", NFS2015DisplaySafetyTests.fiveK, false, 2560, 1440),
      ("a 6K Retina display", NFS2015DisplaySafetyTests.sixK, false, 3008, 1692),
      ("a 14-inch MacBook Pro", NFS2015DisplaySafetyTests.macBookPro14, true, 3024, 1964),
      ("a 16-inch MacBook Pro", NFS2015DisplaySafetyTests.macBookPro16, true, 3456, 2234),
    ])
  func `decides Retina mode by what doubling would give`(
    _: String, facts: NFS2015DisplayFacts, retina: Bool, width: Int, height: Int
  ) {
    let result = plan(facts, file: true)
    #expect(result.retinaMode == retina)
    #expect(result.wineDesktop == Size(width: width, height: height))
    #expect(result.seed == nil)
  }

  @Test
  func `a scaled mode that shows more space than the panel can use turns Retina mode off`() {
    let moreSpace = Self.facts(points: (1920, 1200), pixels: (3840, 2400), native: (2560, 1600))
    let result = plan(moreSpace)
    #expect(result.retinaMode == false)
    #expect(result.wineDesktop == Size(width: 1920, height: 1200))
    #expect(result.seed == nil)
  }

  @Test
  func `keeps Retina mode up to exactly 1.75 times the panel and not a pixel more`() {
    // Doubling 1000x875 points gives 2000x1750 = 3,500,000 pixels = 1.75 x 2,000,000.
    let at = Self.facts(points: (1000, 875), pixels: (2000, 1750), native: (2000, 1000))
    let over = Self.facts(points: (1000, 876), pixels: (2000, 1752), native: (2000, 1000))
    #expect(NFS2015DisplaySafety.allowsRetinaDesktop(at))
    #expect(!NFS2015DisplaySafety.allowsRetinaDesktop(over))
  }

  @Test
  func `keeps Retina mode up to 3840x2160 and not a point more`() {
    let at = Self.facts(points: (1920, 1080), pixels: (3840, 2160), native: (3840, 2160))
    let over = Self.facts(points: (1921, 1080), pixels: (3842, 2160), native: (3842, 2160))
    #expect(NFS2015DisplaySafety.allowsRetinaDesktop(at))
    #expect(!NFS2015DisplaySafety.allowsRetinaDesktop(over))
  }

  @Test
  func `measures against the current backing size when the panel could not be told`() {
    let unknown = Self.facts(points: (1680, 1050), pixels: (3360, 2100), native: nil)
    #expect(unknown.reference == Size(width: 3360, height: 2100))
    #expect(plan(unknown).retinaMode == true)
    let external = Self.facts(points: (3840, 2160), pixels: (3840, 2160), native: nil)
    #expect(plan(external).retinaMode == false)
  }

  @Test
  func `seeds nothing when the game already has an options file or its state is unknown`() {
    #expect(plan(Self.external4K, file: true).seed == nil)
    #expect(plan(Self.external4K, file: nil).seed == nil)
    #expect(plan(Self.external4K, file: true).retinaMode == false)
  }

  @Test
  func `does nothing when the display cannot be read or both switches are off`() {
    #expect(plan(nil) == .unmanaged)
    let off = NFS2015DiagnosticsPreference(limitRetinaDesktop: false, seedSafeResolution: false)
    #expect(plan(Self.external4K, preference: off) == .unmanaged)
  }

  @Test
  func `each switch works alone`() {
    let retinaOnly = NFS2015DiagnosticsPreference(seedSafeResolution: false)
    let first = plan(Self.external4K, preference: retinaOnly)
    #expect(first.retinaMode == false && first.seed == nil)
    // Without the first switch the recipe's Retina mode is assumed, so the desktop is 7680x4320.
    let seedOnly = NFS2015DiagnosticsPreference(limitRetinaDesktop: false)
    let second = plan(Self.external4K, preference: seedOnly)
    #expect(second.retinaMode == nil)
    #expect(second.wineDesktop == Size(width: 7680, height: 4320))
    #expect(second.seed == Size(width: 2560, height: 1440))
  }

  @Test
  func `the display summary names every fact a later failure needs`() {
    let summary = Self.facts(
      points: (1680, 1050), pixels: (3360, 2100), native: (2560, 1600), builtIn: true, displays: 2
    ).summary
    for part in [
      "1680x1050 points", "3360x2100 pixels", "scale 2.00", "native 2560x1600", "built-in",
      "2 active", "retina desktop would be 3360x2100",
    ] { #expect(summary.contains(part), "missing \(part)") }
    #expect(Self.external4K.summary.contains("external"))
    #expect(Self.external4K.backingScale == 1)
  }

  @Test
  func `refuses sizes a display cannot have`() {
    let zero = Self.facts(points: (0, 1050), pixels: (3360, 2100), native: nil)
    let huge = Self.facts(points: (1680, 1050), pixels: (999_999, 2100), native: nil)
    #expect(!zero.isPlausible && !huge.isPlausible)
    #expect(Self.macBookAir.isPlausible)
  }

  @Test(
    arguments: [
      (3840, 2160, 2560, 1440), (7680, 4320, 2560, 1440), (3840, 2400, 2560, 1600),
      (3456, 2234, 2160, 1440), (3440, 1440, 2560, 1080), (2560, 1920, 2048, 1536),
      (1280, 1024, 1280, 1024),
    ])
  func `picks the largest standard mode of the closest shape`(
    width: Int, height: Int, safeWidth: Int, safeHeight: Int
  ) {
    #expect(
      NFS2015DisplaySafety.safeResolution(for: Size(width: width, height: height))
        == Size(width: safeWidth, height: safeHeight))
  }

  @Test
  func `every standard mode fits the pixel budget and none repeats`() {
    let modes = NFS2015DisplaySafety.standardModes
    #expect(modes.allSatisfy { $0.pixelCount <= NFS2015DisplaySafety.seedPixels })
    #expect(Set(modes.map(\.text)).count == modes.count)
  }

  // MARK: The registry value

  private let retina = RegistrySetting(
    hive: .currentUser, path: "Software\\Wine\\Mac Driver", name: "RetinaMode", value: "Y",
    kind: .string, reason: "recipe reason")
  private let other = RegistrySetting(
    hive: .currentUser, path: "Software\\Wine\\Mac Driver", name: "AllowSetGamma", value: "Y",
    kind: .string)

  @Test
  func `changes only the RetinaMode value, and only to what the plan says`() {
    let off = NFS2015DisplaySafetyPlan(retinaMode: false, wineDesktop: nil, seed: nil, reasons: [])
    let on = NFS2015DisplaySafetyPlan(retinaMode: true, wineDesktop: nil, seed: nil, reasons: [])
    let changed = NFS2015DisplaySafety.settings([retina, other], plan: off)
    #expect(changed.map(\.value) == ["N", "Y"])
    #expect(changed[0].name == "RetinaMode" && changed[0].path == retina.path)
    #expect(NFS2015DisplaySafety.settings([retina, other], plan: on) == [retina, other])
    #expect(NFS2015DisplaySafety.settings([retina, other], plan: .unmanaged) == [retina, other])
    // The new value is still a valid registry entry.
    #expect(throws: Never.self) {
      for setting in changed { try setting.validate() }
    }
  }

  @Test
  func `leaves a recipe that turns Retina mode off alone and adds nothing`() {
    let recipeOff = RegistrySetting(
      hive: .currentUser, path: "Software\\Wine\\Mac Driver", name: "RetinaMode", value: "N",
      kind: .string)
    let on = NFS2015DisplaySafetyPlan(retinaMode: true, wineDesktop: nil, seed: nil, reasons: [])
    #expect(NFS2015DisplaySafety.settings([recipeOff], plan: on) == [recipeOff])
    #expect(NFS2015DisplaySafety.settings([other], plan: on) == [other])
  }

  @Test
  func `a prefix that already holds Y is told N when needed and Y again when it is not`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let prefix = scratch.url("Prefix")
    try scratch.write("Prefix/user.reg", hive(retina: "Y"))
    let preparation = PrefixPreparation(support: scratch.root)
    let off = NFS2015DisplaySafetyPlan(retinaMode: false, wineDesktop: nil, seed: nil, reasons: [])
    let toN = NFS2015DisplaySafety.settings([retina], plan: off)
    #expect(try preparation.missing(toN, in: prefix).map(\.value) == ["N"])
    try scratch.write("Prefix/user.reg", hive(retina: "N"))
    #expect(try preparation.missing(toN, in: prefix).isEmpty)
    // Back on the built-in panel: the recipe's own value is missing again, so it is imported.
    #expect(try preparation.missing([retina], in: prefix).map(\.value) == ["Y"])
  }

  private func hive(retina: String) -> String {
    """
    WINE REGISTRY Version 2

    [Software\\\\Wine\\\\Mac Driver] 1790000000
    "RetinaMode"="\(retina)"

    """
  }
}
