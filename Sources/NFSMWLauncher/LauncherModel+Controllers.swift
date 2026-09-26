import Foundation
import GameController

extension LauncherModel {
  func watchControllerConnections() async {
    refreshControllers()
    for await _ in NotificationCenter.default.notifications(named: .GCControllerDidConnect).map({
      _ in true
    }) {
      guard !Task.isCancelled else { return }
      refreshControllers()
    }
  }
  func watchControllerDisconnections() async {
    for await _ in NotificationCenter.default.notifications(named: .GCControllerDidDisconnect).map({
      _ in true
    }) {
      guard !Task.isCancelled else { return }
      refreshControllers()
    }
  }
}
