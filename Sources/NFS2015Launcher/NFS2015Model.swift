import AppKit
import Foundation
import LauncherCore
import NFS2015Core
import Observation
import SharedLauncher
import SwiftUI
import UniformTypeIdentifiers

enum NFS2015Phase: Equatable {
  case preparing, ready, playing, needsRosetta, needsInstallation, installing, signingIn
  case failed(String)

  var isBusy: Bool { [.preparing, .playing, .installing, .signingIn].contains(self) }

  var message: String {
    switch self {
    case .preparing: "Checking your installation…"
    case .ready: "Ready to play"
    case .playing:
      """
      Starting the EA app and the game. If the EA app asks you to sign in, sign in there. \
      Quitting the EA app returns here.
      """
    case .needsRosetta: "Rosetta is required to run this Windows game."
    case .needsInstallation: "Choose the Windows folder that holds the EA app and this game."
    case .installing: "Running the EA app installer… finish it, then close its window."
    case .signingIn: "The EA app is open. Sign in, then quit it to return here."
    case .failed(let message): message
    }
  }
}

@MainActor @Observable
final class NFS2015Model {
  private(set) var phase = NFS2015Phase.preparing
  private(set) var snapshot = NFS2015Snapshot()
  /// How far the first-launch game copy has got, while one runs.
  private(set) var preparation: PrefixSeed.Progress?
  /// What the player changed and has not saved: only the settings they touched, so a value the
  /// game changed meanwhile is never put back by a save.
  private(set) var edits: [String: String] = [:]
  /// What the last settings request did.
  private(set) var outcome: NFS2015SettingsOutcome?
  var tab = "Play"
  var request = 0
  let rosetta: RosettaSetup
  /// Whether this app carries the game and prepares its own Windows folder on first launch.
  let carriesGame: Bool
  private let service: any NFS2015Serving
  private var pending: NFS2015Operation? = .prepare

  init(
    service: any NFS2015Serving = NFS2015SessionClient(), rosetta: RosettaSetup = RosettaSetup(),
    carriesGame: Bool = NFS2015Model.packagedManifestCarriesGame()
  ) {
    self.service = service
    self.rosetta = rosetta
    self.carriesGame = carriesGame
  }

  /// Reads this app's own manifest to learn which edition it is; an unreadable one is an import app.
  nonisolated static func packagedManifestCarriesGame() -> Bool {
    let url = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Resources/game-manifest.json")
    return (try? BundleManifest.read(from: url))?.seedsPrefix ?? false
  }

  var blocker: String? { snapshot.blocker }
  /// Whether this app created its own Windows folder and carries the game in it.
  var ownsWindowsFolder: Bool { snapshot.ownsWindowsFolder == true }
  var needsClientInstall: Bool { snapshot.setup == .installClient }
  var canOpenClient: Bool { ownsWindowsFolder && snapshot.setup != .installClient && !isBusy }
  var canInstallClient: Bool { ownsWindowsFolder && !isBusy }

  /// The line beside the Play button: the phase, worded for the edition the player has.
  var statusMessage: String {
    if phase == .preparing, carriesGame, snapshot.installedAt == nil {
      if let progress = preparation, progress.files > 0 {
        return """
          Preparing the game for first use: copied \(progress.files) of \(progress.totalFiles) \
          game files (\(Int(progress.fraction * 100)) %). This takes a few minutes.
          """
      }
      return """
        Preparing the game for first use: creating its Windows folder and copying the game \
        files. This takes a few minutes.
        """
    }
    if phase == .ready, let refusal { return refusal }
    if phase == .ready, let notice = snapshot.notice { return notice }
    guard phase == .needsInstallation, ownsWindowsFolder else { return phase.message }
    return snapshot.setup == .installClient
      ? "Install the EA app, then sign in to it."
      : "Open the EA app and sign in, then quit it and play."
  }
  /// The determinate share of the first-launch copy; nil while the Windows folder is still being
  /// created or when nothing is being prepared, which the view shows as an indeterminate spinner.
  var preparationFraction: Double? {
    guard phase == .preparing, carriesGame, let progress = preparation, progress.files > 0 else {
      return nil
    }
    return progress.fraction
  }
  var clientVersion: String? { snapshot.clientVersion }
  var installedAt: String? { snapshot.installedAt }
  var isBusy: Bool { phase.isBusy || rosetta.isBusy }
  var canPlay: Bool { phase == .ready && rosetta.isAvailable && snapshot.blocker == nil }
  /// Whether the game's own options file can be changed from here.
  var canEditSettings: Bool {
    showsSettingControls && snapshot.optionsDigest != nil && !isBusy
  }
  /// Whether the page lists settings at all: before the game has written its file, or when its
  /// layout is not one this app validated, there is nothing to write and nothing is offered.
  var showsSettingControls: Bool { snapshot.hasOptionsFile && snapshot.optionsProblem == nil }
  var hasPendingChanges: Bool { !edits.isEmpty }
  var errorMessage: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }

  var settingsNotice: String? {
    guard snapshot.hasOptionsFile else {
      return """
        Start the game once and quit it so it writes its own options file. Until then there is \
        nothing here to change: this app edits only values the game has already written.
        """
    }
    return snapshot.optionsProblem
  }

  /// Why a request was refused, if the last one was.
  var refusal: String? { outcome?.refusal }

  /// What the last request did, one line each, worded from what the file was read back as.
  var outcomeLines: [String] {
    switch outcome {
    case .saved(let lines):
      return ["Saved. The game's file now holds:"] + lines.map(Self.describe)
    case .restored(let kind, let lines):
      return [
        kind == .original
          ? "Restored the file as the game wrote it before this app first changed it."
          : "Undid the last save."
      ] + lines.map(Self.describe)
    case .unchanged: return ["The file already held those values. Nothing was written."]
    case .refused, nil: return []
    }
  }

  private static func describe(_ line: NFS2015OptionLine) -> String {
    "\(line.key) \(line.now) (was \(line.before))"
  }

  func settings(in group: NFS2015SettingGroup) -> [NFS2015Setting] {
    NFS2015Catalog.settings(in: group)
  }

  /// Whether the game's file holds a value for this setting that the player can change.
  func isChangeable(_ setting: NFS2015Setting) -> Bool {
    showsSettingControls && setting.isEditable && snapshot.settings.isPresent(setting.id)
  }

  /// What the game wrote for a setting that is shown but not changed, or whose value is outside
  /// what this app offers.
  func recordedText(_ setting: NFS2015Setting) -> String? { snapshot.settings.observed[setting.id] }

  /// The value shown: the player's pending choice, else what the game's file holds.
  func value(_ id: String) -> String { edits[id] ?? snapshot.settings.value(id) }

  /// Holds a typed or dragged value inside its range and keeps it as a pending change.
  func set(_ id: String, to text: String) {
    guard let setting = NFS2015Catalog.setting(id), isChangeable(setting),
      let chosen = setting.clamped(text)
    else { return }
    outcome = nil
    if setting.isEquivalent(chosen, snapshot.settings.value(id)) {
      edits[id] = nil
    } else {
      edits[id] = chosen
    }
  }

  func binding(_ id: String) -> Binding<String> {
    Binding(get: { self.value(id) }, set: { self.set(id, to: $0) })
  }

  func numberBinding(_ id: String) -> Binding<Double> {
    Binding(
      get: { Double(self.value(id)) ?? 0 }, set: { self.set(id, to: String($0)) })
  }

  /// The detail levels at their top step with motion blur and film grain off. This changes the
  /// pending choices only, for the options the game's file holds; Save writes them.
  func applyMaximumQuality() {
    for (id, value) in NFS2015Preset.maximumQuality { set(id, to: value) }
  }

  func discard() {
    edits = [:]
    outcome = nil
  }

  var canRestoreOriginal: Bool { canEditSettings && snapshot.backups?.original == true }
  var canUndoLastSave: Bool { canEditSettings && snapshot.backups?.previous == true }

  func reload() { enqueue(.prepare) }
  func play() { enqueue(.play) }
  func enableController() { enqueue(.enableController) }

  /// Saves the pending choices, quoting the file as the player saw it.
  func apply() { request(.save, changes: edits) }

  /// Puts the file back as the game wrote it before this app first changed it.
  func restoreGameDefaults() { request(.restoreOriginal) }

  /// Puts the file back as it was before the latest save.
  func undoLastSave() { request(.restorePrevious) }

  private func request(
    _ action: NFS2015SettingsRequest.Action, changes: [String: String] = [:]
  ) {
    guard canEditSettings, let digest = snapshot.optionsDigest else { return }
    enqueue(
      .configure(
        NFS2015SettingsRequest(action: action, changes: changes, expectedDigest: digest)))
  }

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

  /// Asks for the EA app installer the player downloaded from ea.com.
  func chooseClientInstaller() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = false
    panel.allowedContentTypes = [.exe]
    panel.prompt = "Install"
    panel.message = """
      Choose the EA app installer you downloaded from ea.com. It is installed into this app's \
      own Windows folder, and you sign in to your own account there.
      """
    guard panel.runModal() == .OK, let installer = panel.url else { return }
    installClient(installer)
  }

  /// Runs the chosen EA app installer in the app's own Windows folder.
  func installClient(_ installer: URL) { enqueue(.installClient(installer)) }

  func openClient() { enqueue(.openClient) }

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
    if operation.runsWindowsProgram {
      await rosetta.refresh()
      guard rosetta.isAvailable else {
        phase = .needsRosetta
        return
      }
    }
    phase = operation.busyPhase
    let watcher =
      operation == .prepare && carriesGame && snapshot.installedAt == nil
      ? Task { await self.watchPreparation() } : nil
    defer {
      watcher?.cancel()
      preparation = nil
    }
    do {
      let result = try await service.perform(operation)
      snapshot = result
      adopt(result, after: operation)
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

  /// Takes a helper's answer in. A refused save keeps the player's choices, so they can quit the
  /// game or reload and save again; any other operation starts from what the file now holds.
  private func adopt(_ result: NFS2015Snapshot, after operation: NFS2015Operation) {
    if case .configure = operation {
      outcome = result.outcome
    } else if operation != .prepare {
      outcome = nil
    }
    if operation != .prepare, result.outcome?.refusal == nil { edits = [:] }
    edits = edits.filter { id, chosen in
      result.settings.isPresent(id) && result.settings.values[id] != chosen
    }
  }

  /// Reads the staged copy once; the watcher repeats this while the helper runs. A reading that
  /// arrives after the watcher was cancelled is dropped, so a finished run leaves no stale bar.
  func refreshPreparation() async {
    let progress = await service.preparationProgress()
    guard !Task.isCancelled else { return }
    preparation = progress
  }

  private func watchPreparation() async {
    while !Task.isCancelled {
      await refreshPreparation()
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
    }
  }

  private func enqueue(_ operation: NFS2015Operation) {
    guard !isBusy else { return }
    pending = operation
    request += 1
  }
}
