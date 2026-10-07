import Foundation

/// What the main display is doing, as far as the first-run display safety needs to know.
///
/// "Points" are the logical size macOS reports for the current mode; "pixels" are the backing
/// store behind that mode; "native" is the physical panel's own mode. Wine's Mac driver, with
/// `RetinaMode` on, advertises twice the point size as the desktop (**inferred** from two
/// observations: 3360x2100 for 1680x1050 points on the built-in M1 panel, and, as the player
/// reports, 7680x4320 for a 3840x2160 external screen). With it off the driver advertises the
/// point size.
package struct NFS2015DisplayFacts: Equatable, Sendable, Codable {
  package struct Size: Equatable, Sendable, Codable {
    package let width: Int
    package let height: Int

    package init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }

    package var pixelCount: Int { width * height }
    package var text: String { "\(width)x\(height)" }
    var isPlausible: Bool { (1...32_768).contains(width) && (1...32_768).contains(height) }
  }

  /// The logical size of the current mode.
  package let points: Size
  /// The backing-store size of the current mode.
  package let pixels: Size
  /// The physical panel's own mode; nil when it could not be told.
  package let native: Size?
  package let isBuiltIn: Bool
  /// How many displays are active. Wine and the game use the main one.
  package let displayCount: Int

  package init(
    points: Size, pixels: Size, native: Size?, isBuiltIn: Bool, displayCount: Int = 1
  ) {
    self.points = points
    self.pixels = pixels
    self.native = native
    self.isBuiltIn = isBuiltIn
    self.displayCount = displayCount
  }

  /// Backing pixels per point along one axis; the same number as `NSScreen.backingScaleFactor`
  /// for the screen in this mode, without needing AppKit in the helper.
  package var backingScale: Double {
    points.width > 0 ? Double(pixels.width) / Double(points.width) : 1
  }

  /// The desktop Wine advertises with `RetinaMode` on (**inferred**, see the type's note).
  package var retinaDesktop: Size { Size(width: points.width * 2, height: points.height * 2) }

  /// The desktop Wine advertises with `RetinaMode` off.
  package var logicalDesktop: Size { points }

  /// The panel size to measure against: the physical mode, or the current backing store when
  /// the panel could not be told (which can overstate it in a scaled mode, so it errs towards
  /// more caution only through the absolute ceiling).
  package var reference: Size { native ?? pixels }

  /// Whether every size is one a display can have, so a garbled answer is never acted on.
  package var isPlausible: Bool {
    points.isPlausible && pixels.isPlausible && (native?.isPlausible ?? true) && displayCount >= 1
  }

  /// One line for the session log and the crash report.
  package var summary: String {
    let scale = String(format: "%.2f", backingScale)
    return """
      main display: \(points.text) points, \(pixels.text) pixels (scale \(scale)), \
      native \(native?.text ?? "unknown"), \(isBuiltIn ? "built-in" : "external"), \
      \(displayCount) active; Wine retina desktop would be \(retinaDesktop.text)
      """
  }
}

/// Looks at the main display. A fixture stands in for it under test.
package protocol NFS2015DisplayQuerying: Sendable {
  /// The main display now, or nil when it cannot be read.
  func mainDisplay() -> NFS2015DisplayFacts?
}
