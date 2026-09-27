import AppKit
import Foundation
import GameController

extension CoD4Model {
  func refreshControllers() {
    let controllers = GCController.controllers()
    controllerStatus =
      controllers.isEmpty
      ? "No controller detected. Connect by Bluetooth or USB, then refresh."
      : controllers.map { $0.vendorName ?? "Game controller" }.joined(separator: ", ")
  }
  func watchControllerConnections() async {
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
  func watchActivation() async {
    for await _ in NotificationCenter.default.notifications(
      named: NSApplication.didBecomeActiveNotification
    ).map({ _ in true }) {
      guard !Task.isCancelled else { return }
      refreshControllers()
      if needsRosetta && !isBusy { refreshRosetta() }
    }
  }
}
