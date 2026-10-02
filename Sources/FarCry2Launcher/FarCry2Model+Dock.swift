import AppKit
import FarCry2Core
import LauncherCore
import SharedLauncher

extension FarCry2Model {
  var dockEnabled: Bool { settings.value("dock") == "1" }
  var gameViewSize: CGSize? { GameDock.viewSize(forResolution: settings.value("resolution")) }
  var dockNeedsPermission: Bool { dockEnabled && !GameDock.isTrusted }

  /// Docking needs a windowed, borderless game; both are set where the player can see and change them.
  func setDock(_ enabled: Bool) {
    settings.values["dock"] = enabled ? "1" : "0"
    settings.values["borderless"] = enabled ? "1" : "0"
    if enabled {
      settings.values["fullscreen"] = "0"
      if !GameDock.isTrusted { requestAccessibility() }
    }
  }

  func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
  }

  /// Keeps the running game's window over the Game view until the session ends.
  func followGame() async {
    let lease = GameLease(
      url: GameWindow.leaseURL(support: FarCry2SessionClient.defaultSupport))
    while !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(250))
      guard phase == .playing, GameDock.isTrusted, let frame = dockFrame,
        let screen = NSScreen.screens.first, let pid = lease.activeProcess()
      else { continue }
      let target = GameDock.accessibilityOrigin(
        ofAppKitFrame: frame, primaryScreenHeight: screen.frame.height)
      if GameDock.position(of: pid) != target { GameDock.place(pid: pid, at: target) }
    }
  }
}
