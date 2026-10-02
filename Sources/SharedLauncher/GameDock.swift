import AppKit
import ApplicationServices

/// Positions a running game's borderless window over a region of the starter.
///
/// macOS has no public way to host another process's window inside a view. Wine's window can be moved
/// through the Accessibility API but not resized, so the starter shows a placeholder the size of the game
/// and keeps the game's window over it. Moving needs the player's Accessibility permission.
package enum GameDock {
  package static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Asks macOS to show its Accessibility permission prompt for this app.
  @discardableResult
  package static func requestTrust() -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  /// Accessibility positions use a top-left origin on the primary display; AppKit uses bottom-left.
  package static func accessibilityOrigin(
    ofAppKitFrame frame: CGRect, primaryScreenHeight: CGFloat
  ) -> CGPoint {
    CGPoint(x: frame.minX.rounded(), y: (primaryScreenHeight - frame.maxY).rounded())
  }

  /// The size, in points, a game window needs for a `WIDTHxHEIGHT` resolution; nil when malformed.
  package static func viewSize(forResolution resolution: String) -> CGSize? {
    let parts = resolution.split(separator: "x")
    guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0,
      height > 0
    else { return nil }
    return CGSize(width: width, height: height)
  }

  /// The first window of `pid`: its position, or nil when the process has none yet or access is denied.
  package static func position(of pid: Int32) -> CGPoint? {
    guard let window = firstWindow(of: pid) else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, "AXPosition" as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    // The type was checked above, so this reads a CGPoint into storage of exactly that type.
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
  }

  /// Moves the first window of `pid` to `origin`. Returns whether macOS accepted the move.
  @discardableResult
  package static func place(pid: Int32, at origin: CGPoint) -> Bool {
    guard let window = firstWindow(of: pid) else { return false }
    var point = origin
    guard let value = AXValueCreate(.cgPoint, &point) else { return false }
    return AXUIElementSetAttributeValue(window, "AXPosition" as CFString, value) == .success
  }

  private static func firstWindow(of pid: Int32) -> AXUIElement? {
    guard isTrusted else { return nil }
    var value: CFTypeRef?
    let application = AXUIElementCreateApplication(pid)
    guard AXUIElementCopyAttributeValue(application, "AXWindows" as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { return nil }
    return windows.first
  }
}
