import AppKit
import LauncherCore

/// The player's way back to a running game from its starter.
///
/// Wine's Mac driver hides the game's application when its window loses focus in some situations, so
/// bringing it back means showing it again before activating it.
package enum GameWindow {
  package static func leaseURL(support: URL) -> URL {
    support.appendingPathComponent("game-session.json")
  }

  /// - Returns: false when no game is recorded as running, or macOS declined to activate it.
  @MainActor @discardableResult
  package static func bringToFront(support: URL) -> Bool {
    guard let pid = GameLease(url: leaseURL(support: support)).activeProcess(),
      let app = NSRunningApplication(processIdentifier: pid)
    else { return false }
    if app.isHidden { app.unhide() }
    return app.activate(from: .current, options: [.activateAllWindows])
  }
}
