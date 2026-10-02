import CoreGraphics
import Testing

@testable import SharedLauncher

struct GameDockTests {
  @Test
  func `AppKit frames convert to Accessibility positions from the top of the primary display`() {
    let frame = CGRect(x: 100, y: 200, width: 1280, height: 800)
    let origin = GameDock.accessibilityOrigin(ofAppKitFrame: frame, primaryScreenHeight: 1600)
    #expect(origin == CGPoint(x: 100, y: 600))
  }

  @Test
  func `positions are whole points so the game is not asked for half pixels`() {
    let frame = CGRect(x: 10.4, y: 20.2, width: 100, height: 50.3)
    let origin = GameDock.accessibilityOrigin(ofAppKitFrame: frame, primaryScreenHeight: 1000)
    #expect(origin.x == 10 && origin.y == 930)
  }

  @Test(arguments: [
    ("1280x800", CGSize(width: 1280, height: 800)),
    ("3024x1964", CGSize(width: 3024, height: 1964)),
  ])
  func `the view size is the resolution in points`(resolution: String, expected: CGSize) {
    #expect(GameDock.viewSize(forResolution: resolution) == expected)
  }

  @Test(arguments: ["", "1280", "1280x", "x800", "0x800", "1280x0", "ax b", "1x2x3", "-5x10"])
  func `a malformed resolution gives no view size`(resolution: String) {
    #expect(GameDock.viewSize(forResolution: resolution) == nil)
  }
}
