import AppKit
import FarCry2Core
import Foundation
import LauncherCore
import Observation
import SharedLauncher
import SwiftUI

@MainActor @Observable
final class FarCry2Model {
  enum Action {
    case helper(FarCry2Operation)
    case importGame, importSetup, exportSetup, exportShaderCache, importShaderCache
    case installRosetta, refreshRosetta, openLog
  }

  private(set) var phase = FarCry2Phase.preparing
  private(set) var request = 0
  private(set) var hasGameData = false
  private(set) var profileState = FarCry2ProfileState.missing
  private(set) var installation: InstalledGame?
  private(set) var backups: [FarCry2Backup] = []
  private(set) var keptAside = 0
  private(set) var shaderCache = ShaderCacheStatus(state: .unavailable)
  var settings = FarCry2Settings()
  var tab = "Play"
  var backupSelection = ""
  var discardConfirmation = false
  var restoreConfirmation = false
  var removalConfirmation = false
  var shaderResetConfirmation = false
  let rosetta: RosettaSetup
  let service: any FarCry2Serving
  private var appliedSettings = FarCry2Settings()
  private var action = Action.helper(.prepare)
  private var deferredAction: Action?
  private let display: @MainActor () -> ResolutionPreset?
  private var detectedDisplay: ResolutionPreset?

  init(
    service: any FarCry2Serving = FarCry2SessionClient(), rosetta: RosettaSetup = RosettaSetup(),
    display: @escaping @MainActor () -> ResolutionPreset? = DisplayQuality.maximumPreset
  ) {
    self.service = service
    self.rosetta = rosetta
    self.display = display
    detectedDisplay = display()
  }

  var isBusy: Bool { phase.isBusy }
  var needsRosetta: Bool { phase == .needsRosetta }
  var needsGameData: Bool { phase == .needsGameData }
  var hasPendingChanges: Bool { settings != appliedSettings }
  var errorMessage: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }
  var canPlay: Bool { !isBusy && hasGameData }
  var canRestore: Bool { !isBusy && backups.contains { $0.id == backupSelection } }
  var canBackUp: Bool { !isBusy && hasGameData && backups.count < FarCry2Backups.limit }
  var resolutionSummary: String {
    settings.value("resolution").replacingOccurrences(of: "x", with: " × ")
  }
  var renderSummary: String {
    settings.value("render.scale") == "1"
      ? "Full resolution · DirectX 9 on Metal" : "Reduced rendering scale · DirectX 9 on Metal"
  }
  /// Plain-language state of the game's own settings file.
  var profileNotice: String {
    switch profileState {
    case .ready: "Settings are read from and written to the game's profile."
    case .missing:
      "The game has not created its settings file yet. Start it once and quit; graphics options then apply to it. Renderer options apply now."
    case .unrecognized:
      "The game's settings file has a layout this starter does not understand, so it is left untouched. Renderer options still apply."
    }
  }
  var installationSummary: String? {
    guard let installation else { return nil }
    let build = installation.build ?? "not on the verified list"
    let hints =
      installation.markers.isEmpty ? "" : " · \(installation.markers.joined(separator: ", "))"
    return "Version \(installation.fileVersion ?? "unknown") · build \(build)\(hints)"
  }

  func run() async {
    let currentAction = action
    phase = isPlay(currentAction) ? .playing : .preparing
    if case .openLog = currentAction {
      phase = hasGameData ? .ready : .needsGameData
      await openLog()
      return
    }
    do {
      if case .installRosetta = currentAction {
        await rosetta.install()
      } else {
        await rosetta.refresh()
      }
      try Task.checkCancellation()
      guard rosetta.isAvailable else {
        phase = .needsRosetta
        return
      }
      hasGameData = try await service.hasGameData()
      if !hasGameData, case .helper(.prepare) = currentAction {
        phase = .needsGameData
        return
      }
      switch currentAction {
      case .helper(let operation):
        if let request = operation.launchRequest { try request.settings.validate() }
        let snapshot = try await service.perform(operation)
        if case .shaderCache = operation { updateShaderCache(snapshot) } else { load(snapshot) }
      case .installRosetta, .refreshRosetta:
        guard hasGameData else {
          phase = .needsGameData
          return
        }
        load(try await service.perform(.prepare))
      case .importGame: try await importGameFolder()
      case .importSetup: try await importSetupFile()
      case .exportSetup: try await exportSetupFile()
      case .exportShaderCache: try await exportShaderCacheFile()
      case .importShaderCache: try await importShaderCacheFile()
      case .openLog: break
      }
      try Task.checkCancellation()
      phase = hasGameData ? .ready : .needsGameData
    } catch is CancellationError {
      phase = hasGameData ? .ready : .needsGameData
    } catch { phase = .failed(error.localizedDescription) }
  }

  func load(_ snapshot: FarCry2Snapshot) {
    profileState = snapshot.profile
    installation = snapshot.installation
    backups = snapshot.backups
    keptAside = snapshot.keptAside
    updateShaderCache(snapshot)
    settings = snapshot.settings
    if settings.values["resolution"] == nil, let detectedDisplay {
      settings.values["resolution"] = detectedDisplay.id
    }
    appliedSettings = settings
    if !backups.contains(where: { $0.id == backupSelection }) {
      backupSelection = backups.first?.id ?? ""
    }
  }

  func updateShaderCache(_ snapshot: FarCry2Snapshot) {
    shaderCache = snapshot.shaderCache ?? ShaderCacheStatus(state: .unavailable)
  }

  func finishGameImport(_ snapshot: FarCry2Snapshot) {
    hasGameData = true
    load(snapshot)
  }

  func showLog() { enqueue(.openLog) }
  func play() { enqueue(.helper(.play(launchRequest()))) }
  func apply() { enqueue(.helper(.configure(launchRequest()))) }
  func reload() { enqueueDiscarding(.helper(.prepare)) }
  func confirmDiscard() {
    discardConfirmation = false
    guard let deferredAction else { return }
    self.deferredAction = nil
    enqueue(deferredAction)
  }
  func cancelDiscard() {
    discardConfirmation = false
    deferredAction = nil
  }
  func importGame() { enqueueDiscarding(.importGame) }
  func importSetup() { enqueueDiscarding(.importSetup) }
  func exportSetup() { enqueue(.exportSetup) }
  func installRosetta() { enqueue(.installRosetta) }
  func refreshRosetta() { enqueue(.refreshRosetta) }

  func backUp() {
    guard canBackUp else { return }
    enqueue(.helper(.backups(.init(action: .create))))
  }
  func restoreBackup() {
    restoreConfirmation = false
    guard canRestore else { return }
    enqueueDiscarding(.helper(.backups(.init(action: .restore, id: backupSelection))))
  }
  func removeBackup() {
    removalConfirmation = false
    guard canRestore else { return }
    enqueue(.helper(.backups(.init(action: .remove, id: backupSelection))))
  }

  func maximumQuality() {
    guard let preset = display() else {
      phase = .failed(
        "A supported display resolution could not be detected. Select a resolution in Graphics.")
      return
    }
    detectedDisplay = preset
    settings.maximumQuality(width: preset.width, height: preset.height)
  }
  func settingBinding(_ id: String) -> Binding<String> {
    Binding(get: { self.settings.value(id) }, set: { self.settings.values[id] = $0 })
  }
  func settings(in group: String) -> [FarCry2Setting] {
    FarCry2Catalog.settings.filter { $0.group == group && $0.id != "resolution" }
  }
  func openLog() async {
    guard let url = await service.logLocation(), NSWorkspace.shared.open(url) else {
      phase = .failed("No session log is available yet.")
      return
    }
  }
  func watchActivation() async {
    for await _ in NotificationCenter.default.notifications(
      named: NSApplication.didBecomeActiveNotification
    ).map({ _ in true }) {
      guard !Task.isCancelled else { return }
      if needsRosetta && !isBusy { refreshRosetta() }
    }
  }

  private func launchRequest() -> FarCry2LaunchRequest { .init(settings: settings) }
  func enqueue(_ action: Action) {
    guard !isBusy else { return }
    self.action = action
    phase = isPlay(action) ? .playing : .preparing
    request += 1
  }
  private func enqueueDiscarding(_ action: Action) {
    guard !isBusy else { return }
    if hasPendingChanges {
      deferredAction = action
      discardConfirmation = true
    } else {
      enqueue(action)
    }
  }
  private func isPlay(_ action: Action) -> Bool {
    if case .helper(.play) = action { return true }
    return false
  }
}
