import CoreGraphics
import LauncherCore

@MainActor
enum DisplayQuality {
  static func maximumPreset() -> ResolutionPreset? {
    guard let modes = CGDisplayCopyAllDisplayModes(CGMainDisplayID(), nil) as? [CGDisplayMode],
      let largest = modes.max(by: {
        $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
      })
    else { return nil }
    return ResolutionPreset(width: largest.pixelWidth, height: largest.pixelHeight)
  }
}
