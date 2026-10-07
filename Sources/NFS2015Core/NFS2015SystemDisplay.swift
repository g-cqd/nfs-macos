import CoreGraphics
import Foundation

/// Reads the main display through Core Graphics.
///
/// The native mode is the one the display driver flags as native (`kDisplayModeNativeFlag`,
/// 0x02000000, in IOKit's `IOGraphicsTypes.h`); the built-in panel of an M1 MacBook Air lists it
/// twice (as 1x 2560x1600 and as the 2x 1280x800 point mode), both with the same pixel size.
package struct NFS2015SystemDisplay: NFS2015DisplayQuerying {
  static let nativeFlag: UInt32 = 0x0200_0000

  package init() {}

  package func mainDisplay() -> NFS2015DisplayFacts? {
    let display = CGMainDisplayID()
    guard let mode = CGDisplayCopyDisplayMode(display) else { return nil }
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    let native =
      modes.filter { $0.ioFlags & Self.nativeFlag != 0 }
      .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
      .map { NFS2015DisplayFacts.Size(width: $0.pixelWidth, height: $0.pixelHeight) }
    var active: UInt32 = 0
    if CGGetActiveDisplayList(0, nil, &active) != .success { active = 1 }
    let facts = NFS2015DisplayFacts(
      points: .init(width: mode.width, height: mode.height),
      pixels: .init(width: mode.pixelWidth, height: mode.pixelHeight), native: native,
      isBuiltIn: CGDisplayIsBuiltin(display) != 0, displayCount: max(1, Int(active)))
    return facts.isPlausible ? facts : nil
  }
}
