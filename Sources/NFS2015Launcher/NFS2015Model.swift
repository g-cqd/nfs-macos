import AppKit
import Foundation
import LauncherCore
import NFS2015Core
import Observation
import SharedLauncher
import SwiftUI

enum NFS2015Phase: Equatable {
  case preparing, ready, playing, needsRosetta, needsInstallation
  case failed(String)

  var isBusy: Bool { self == .preparing || self == .playing }

  var message: String {
    switch self {
    case .preparing: "Checking your installation…"
    case .ready: "Ready to play"
    case .playing: "The EA app is running this session. Quit it to return here."
    case .needsRosetta: "Rosetta is required to run this Windows game."
    case .needsInstallation: "Choose the Windows folder that holds the EA app and this game."
    case .failed(let message): message
    }
  }
}

@MainActor @Observable
final class NFS2015Model {
  private(set) var phase = NFS2015Phase.preparing
  private(set) var snapshot = NFS2015Snapshot()
  private(set) var edited = NFS2015Settings()
  var tab = "Play"
  var request = 0
  let rosetta: RosettaSetup
  private let service: any NFS2015Serving
  private var pending: NFS2015Operation? = .prepare

  init(service: any NFS2015Serving = NFS2015SessionClient(), rosetta: RosettaSetup = RosettaSetup())
  {
    self.service = service
    self.rosetta = rosetta
  }

  var blocker: String? { snapshot.blocker }
  var clientVersion: String? { snapshot.clientVersion }
  var installedAt: String? { snapshot.installedAt }
  var isBusy: Bool { phase.isBusy || rosetta.isBusy }
  var canPlay: Bool { phase == .ready && rosetta.isAvailable && snapshot.blocker == nil }
  var canEditSettings: Bool { snapshot.hasOptionsFile && !isBusy }
  var hasPendingChanges: Bool { edited != snapshot.settings }
  var errorMessage: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }

  var settingsNotice: String? {
    snapshot.hasOptionsFile
      ? nil
      : """
      Start the game once and quit it so it writes its own options file. This app then changes \
      only the values you choose there.
      """
  }

  func settings(in group: String) -> [NFS2015Setting] {
    NFS2015Catalog.settings.filter { $0.group == group }
  }

  func binding(_ id: String) -> Binding<String> {
    Binding(
      get: { self.edited.value(id) },
      set: { value in
        guard NFS2015Catalog.setting(id)?.accepts(value) == true else { return }
        self.edited.values[id] = value
      })
  }

  func reload() { enqueue(.prepare) }
  func play() { enqueue(.play) }
  func apply() { enqueue(.configure(edited)) }
  func enableController() { enqueue(.enableController) }
  func discard() { edited = snapshot.settings }

  /// Asks for the folder the player installed Windows, the EA app and this game into.
  func chooseInstallation() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = false
    panel.prompt = "Choose"
    panel.message = """
      Choose the Windows folder that contains drive_c, with the EA app and Need for Speed \
      installed in it. Nothing is copied out of it.
      """
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    enqueue(.chooseInstallation(folder))
  }

  func installRosetta() { Task { await rosetta.install() } }
  func refreshRosetta() { Task { await rosetta.refresh() } }

  func showLog() {
    Task {
      guard let log = await service.logLocation() else { return }
      NSWorkspace.shared.open(log)
    }
  }

  /// Runs the queued helper transaction. Driven by a `task(id:)` so cancellation detaches only.
  func run() async {
    guard let operation = pending else { return }
    pending = nil
    if operation == .play {
      await rosetta.refresh()
      guard rosetta.isAvailable else {
        phase = .needsRosetta
        return
      }
    }
    phase = operation == .play ? .playing : .preparing
    do {
      let result = try await service.perform(operation)
      snapshot = result
      if !hasPendingChanges || operation != .prepare { edited = result.settings }
      if rosetta.state == .unchecked { await rosetta.refresh() }
      phase =
        result.blocker == nil
        ? (rosetta.isAvailable ? .ready : .needsRosetta) : .needsInstallation
    } catch is CancellationError {
      phase = .preparing
    } catch let error as LauncherError {
      phase = .failed(error.localizedDescription)
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private func enqueue(_ operation: NFS2015Operation) {
    guard !isBusy else { return }
    pending = operation
    request += 1
  }
}
