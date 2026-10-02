import AppKit
import CoD4Core
import Foundation
import LauncherCore
import Observation
import SharedLauncher
import SwiftUI

@MainActor @Observable
final class CoD4Model {
  enum Action {
    case helper(CoD4Operation)
    case importGame, importSetup, exportSetup, importProfile, exportProfile
    case installRosetta, refreshRosetta, openLog
  }
  private(set) var phase = CoD4Phase.preparing
  private(set) var request = 0
  private(set) var profiles: [CoD4Profile] = []
  private(set) var selectedProfile = ""
  private(set) var mode = CoD4Mode.singlePlayer
  private(set) var hasGameData = false
  var settings = CoD4Settings()
  var tab = "Play"
  var profileSelection = ""
  var backupSelection = ""
  var newProfileName = ""
  var discardConfirmation = false
  var removalConfirmation = false
  var restoreConfirmation = false
  var controllerStatus = "Use Refresh to detect connected controllers."
  var keySelection = "W"
  let rosetta: RosettaSetup
  let service: any CoD4Serving
  private var appliedSettings = CoD4Settings()
  private var action = Action.helper(.prepare(mode: .singlePlayer, profile: nil))
  private var deferredAction: Action?
  private let display: @MainActor () -> ResolutionPreset?
  private var detectedDisplay: ResolutionPreset?

  init(
    service: any CoD4Serving = CoD4SessionClient(), rosetta: RosettaSetup = RosettaSetup(),
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
  var playProfiles: [CoD4Profile] { profiles.filter(\.isInstalled) }
  var currentProfile: CoD4Profile? { profiles.first { $0.name == profileSelection } }
  var backupNames: [String] { currentProfile?.backupNames ?? [] }
  var canRestore: Bool { !isBusy && backupNames.contains(backupSelection) }
  var canManageProfile: Bool { !isBusy && currentProfile?.isInstalled == true }
  var canCreateProfile: Bool { !isBusy && CoD4ProfileStore.validName(newProfileName) }
  var canPlay: Bool {
    !isBusy && hasGameData && playProfiles.contains { $0.name == selectedProfile }
  }
  var resolutionSummary: String {
    settings.value("r_mode").replacingOccurrences(of: "x", with: " × ")
  }
  var renderSummary: String {
    settings.value("render.scale") == "1"
      ? "Full resolution · Metal rendering" : "Reduced rendering scale · Metal rendering"
  }
  var bindingCommand: String {
    get { settings.bindings[keySelection] ?? "" }
    set { settings.bindings[keySelection] = newValue }
  }
  var bindingDescription: String {
    settings.bindings[keySelection] == nil
      ? "No starter override. The existing game binding is preserved."
      : "This binding will be applied when you save or play."
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
        try Task.checkCancellation()
        load(snapshot, operation: operation)
      case .installRosetta, .refreshRosetta:
        guard hasGameData else {
          phase = .needsGameData
          return
        }
        let operation = CoD4Operation.prepare(
          mode: mode, profile: selectedProfile.isEmpty ? nil : selectedProfile)
        load(try await service.perform(operation), operation: operation)
      case .importGame: try await importGameFolder()
      case .importSetup: try await importSetupFile()
      case .exportSetup: try await exportSetupFile()
      case .importProfile: try await importProfileFolder()
      case .exportProfile: try await exportProfileFolder()
      case .openLog: break
      }
      try Task.checkCancellation()
      phase = hasGameData ? .ready : .needsGameData
      refreshControllers()
    } catch is CancellationError {
      phase = hasGameData ? .ready : .needsGameData
    } catch { phase = .failed(error.localizedDescription) }
  }

  func load(_ snapshot: CoD4Snapshot, operation: CoD4Operation) {
    var preserveDraft = false
    if case .profile(let request, _) = operation {
      preserveDraft = [.backup, .exportProfile].contains(request.action)
    }
    profiles = snapshot.profiles
    selectedProfile = snapshot.selectedProfile
    if case .prepare(let newMode, _) = operation { mode = newMode }
    if case .importGame(_, let newMode) = operation { mode = newMode }
    if !preserveDraft {
      settings = snapshot.settings
      if settings.values["r_mode"] == nil, let detectedDisplay {
        settings.values["r_mode"] = detectedDisplay.id
      }
      appliedSettings = settings
    }
    if !profiles.contains(where: { $0.name == profileSelection }) || profileSelection.isEmpty {
      profileSelection = snapshot.selectedProfile
    }
    if !backupNames.contains(backupSelection) { backupSelection = backupNames.first ?? "" }
  }

  func finishGameImport(_ snapshot: CoD4Snapshot, operation: CoD4Operation) {
    hasGameData = true
    load(snapshot, operation: operation)
  }
  func showLog() { enqueue(.openLog) }
  func returnToGame() { GameWindow.bringToFront(support: CoD4SessionClient.defaultSupport) }
  func play() { enqueue(.helper(.play(launchRequest()))) }
  func apply() { enqueue(.helper(.configure(launchRequest()))) }
  func reload() { enqueueDiscarding(.helper(.prepare(mode: mode, profile: selectedProfile))) }
  func selectProfile(_ profile: String) {
    guard profile != selectedProfile else { return }
    enqueueDiscarding(.helper(.prepare(mode: mode, profile: profile)))
  }
  func selectMode(_ mode: CoD4Mode) {
    guard mode != self.mode else { return }
    enqueueDiscarding(.helper(.prepare(mode: mode, profile: selectedProfile)))
  }
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
  func importProfile() { enqueueDiscarding(.importProfile) }
  func exportProfile() {
    guard canManageProfile else { return }
    enqueue(.exportProfile)
  }

  func createProfile() {
    guard canCreateProfile else { return }
    enqueueDiscarding(.helper(.profile(.init(action: .create, name: newProfileName), mode: mode)))
  }
  func backupProfile() {
    guard canManageProfile else { return }
    enqueue(.helper(.profile(.init(action: .backup, name: profileSelection), mode: mode)))
  }
  func removeProfile() {
    removalConfirmation = false
    guard canManageProfile else { return }
    enqueueDiscarding(.helper(.profile(.init(action: .remove, name: profileSelection), mode: mode)))
  }
  func restoreProfile() {
    restoreConfirmation = false
    guard canRestore else { return }
    enqueueDiscarding(
      .helper(
        .profile(
          .init(action: .restore, name: profileSelection, backup: backupSelection), mode: mode)))
  }
  func selectManagedProfile(_ name: String) {
    profileSelection = name
    backupSelection = backupNames.first ?? ""
  }
  func resetBindings() { settings.bindings = CoD4Bindings.defaults }
  func clearBindingOverride() { settings.bindings.removeValue(forKey: keySelection) }

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
  func settings(in group: String) -> [CoD4Setting] {
    CoD4Catalog.settings.filter {
      $0.group == group && $0.id != "r_mode" && (mode == .singlePlayer || !$0.campaignOnly)
    }
  }
  func openLog() async {
    guard let url = await service.logLocation(), NSWorkspace.shared.open(url) else {
      phase = .failed("No session log is available yet.")
      return
    }
  }

  private func launchRequest() -> CoD4LaunchRequest {
    .init(settings: settings, profile: selectedProfile, mode: mode)
  }
  private func enqueue(_ action: Action) {
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
