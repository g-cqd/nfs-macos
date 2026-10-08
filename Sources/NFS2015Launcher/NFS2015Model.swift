import AppKit
import CoreGraphics
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
  /// The MetalFX choice the player made and has not saved.
  private(set) var metalFXEdit: NFS2015MetalFXPreference?
  /// What the last MetalFX request did.
  private(set) var metalFXOutcome: NFS2015MetalFXOutcome?
  /// The display-safety and diagnostic-log choices the player made and has not saved.
  private(set) var diagnosticsEdit: NFS2015DiagnosticsPreference?
  /// What the last diagnostics request did.
  private(set) var diagnosticsOutcome: NFS2015DiagnosticsOutcome?
  /// The x87 sidecar choice the player made and has not saved.
  private(set) var sidecarEdit: NFS2015SidecarPreference?
  /// What the last sidecar request did.
  private(set) var sidecarOutcome: NFS2015SidecarOutcome?
  /// The Wine experiment choice the player made and has not saved.
  private(set) var experimentsEdit: NFS2015WineExperimentsPreference?
  /// What the last experiment request did.
  private(set) var experimentsOutcome: NFS2015WineExperimentsOutcome?
  /// The newest crash report of this run of the starter; it stays until the next Play begins.
  private(set) var crashNotice: NFS2015CrashNotice?
  var tab = "Play"
  var request = 0
  let rosetta: RosettaSetup
  /// Whether this app carries the game and prepares its own Windows folder on first launch.
  let carriesGame: Bool
  private let service: any NFS2015Serving
  private let displayPixels: @MainActor () -> (width: Int, height: Int)?
  private var pending: NFS2015Operation? = .prepare

  init(
    service: any NFS2015Serving = NFS2015SessionClient(), rosetta: RosettaSetup = RosettaSetup(),
    carriesGame: Bool = NFS2015Model.packagedManifestCarriesGame(),
    displayPixels: @escaping @MainActor () -> (width: Int, height: Int)? = {
      NFS2015Model.mainDisplayPixels()
    }
  ) {
    self.service = service
    self.rosetta = rosetta
    self.carriesGame = carriesGame
    self.displayPixels = displayPixels
  }

  /// The pixel size the main display is showing now, which is what a window of this size fills.
  static func mainDisplayPixels() -> (width: Int, height: Int)? {
    guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
    return (mode.pixelWidth, mode.pixelHeight)
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
  /// The checklist for a player who has not signed in to the EA app yet, on a bundled app.
  let firstRunGuide = NFS2015FirstRunGuide()
  var needsFirstRunGuide: Bool { ownsWindowsFolder && snapshot.setup != nil }
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
        Preparing the game for first use: creating its Windows folder, setting up the EA app \
        that comes with it and copying the game files. This takes a few minutes.
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

  /// The MetalFX choice the next launch will use, as saved.
  var savedMetalFX: NFS2015MetalFXPreference { snapshot.metalFX?.preference ?? .off }
  /// The choice shown: the player's unsaved one, else the saved one.
  var metalFX: NFS2015MetalFXPreference { metalFXEdit ?? savedMetalFX }
  var hasPendingMetalFX: Bool { metalFXEdit != nil }
  /// Why a saved MetalFX file was not used, if it was not.
  var metalFXNotice: String? { snapshot.metalFX?.notice }
  var canEditMetalFX: Bool { !isBusy }
  /// Whether anything is saved that Reset would clear, or the saved file could not be used.
  var canResetMetalFX: Bool {
    canEditMetalFX && (savedMetalFX != .off || metalFXNotice != nil)
  }
  var metalFXRefusal: String? { metalFXOutcome?.refusal }

  /// What the last MetalFX request did, worded for the player.
  var metalFXOutcomeLine: String? {
    switch metalFXOutcome {
    case .saved: "Saved. It applies the next time the game starts."
    case .reset: "Cleared. MetalFX is off."
    case .unchanged: "That was already saved."
    case .refused, nil: nil
    }
  }

  /// What the choice does at the game's current resolution on this display.
  var metalFXSummary: String {
    let size = value("render.resolution").split(separator: "x").compactMap { Int($0) }
    return NFS2015MetalFX.summary(
      game: size.count == 2 && snapshot.settings.isPresent("render.resolution")
        ? (size[0], size[1]) : nil,
      factor: metalFX.factor, display: displayPixels())
  }

  func setMetalFXEnabled(_ enabled: Bool) {
    guard canEditMetalFX else { return }
    var choice = metalFX
    choice.spatialUpscaling = enabled
    holdMetalFX(choice)
  }

  func setMetalFXFactor(_ factor: NFS2015UpscaleFactor) {
    guard canEditMetalFX else { return }
    var choice = metalFX
    choice.factor = factor
    holdMetalFX(choice)
  }

  func metalFXEnabledBinding() -> Binding<Bool> {
    Binding(get: { self.metalFX.spatialUpscaling }, set: { self.setMetalFXEnabled($0) })
  }

  func metalFXFactorBinding() -> Binding<NFS2015UpscaleFactor> {
    Binding(get: { self.metalFX.factor }, set: { self.setMetalFXFactor($0) })
  }

  func discardMetalFX() {
    metalFXEdit = nil
    metalFXOutcome = nil
  }

  /// Keeps the shown choice for the next launch.
  func saveMetalFX() {
    guard canEditMetalFX, let choice = metalFXEdit else { return }
    enqueue(.configureMetalFX(NFS2015MetalFXRequest(action: .save, preference: choice)))
  }

  /// Forgets what is saved, which means MetalFX off.
  func resetMetalFX() {
    guard canEditMetalFX else { return }
    enqueue(.configureMetalFX(NFS2015MetalFXRequest(action: .reset)))
  }

  private func holdMetalFX(_ choice: NFS2015MetalFXPreference) {
    metalFXOutcome = nil
    metalFXEdit = choice == savedMetalFX ? nil : choice
  }

  // MARK: Display safety and diagnostics

  /// The choices the next launch will use, as saved.
  var savedDiagnostics: NFS2015DiagnosticsPreference {
    snapshot.diagnostics?.preference ?? .standard
  }
  /// The choices shown: the player's unsaved ones, else the saved ones.
  var diagnostics: NFS2015DiagnosticsPreference { diagnosticsEdit ?? savedDiagnostics }
  var hasPendingDiagnostics: Bool { diagnosticsEdit != nil }
  /// Why a saved diagnostics file was not used, if it was not.
  var diagnosticsNotice: String? { snapshot.diagnostics?.notice }
  /// What the display rule decided at the last launch, in the log's words.
  var displayNote: String? {
    snapshot.diagnostics?.displayNote.flatMap { $0.isEmpty ? nil : $0 }
  }
  var canEditDiagnostics: Bool { !isBusy }
  var canResetDiagnostics: Bool {
    canEditDiagnostics && (savedDiagnostics != .standard || diagnosticsNotice != nil)
  }
  var diagnosticsRefusal: String? { diagnosticsOutcome?.refusal }

  var diagnosticsOutcomeLine: String? {
    switch diagnosticsOutcome {
    case .saved: "Saved. It applies the next time you press Play."
    case .reset: "Cleared. The defaults apply."
    case .unchanged: "That was already saved."
    case .refused, nil: nil
    }
  }

  func setLimitRetinaDesktop(_ on: Bool) {
    var choice = diagnostics
    choice.limitRetinaDesktop = on
    holdDiagnostics(choice)
  }

  func setSeedSafeResolution(_ on: Bool) {
    var choice = diagnostics
    choice.seedSafeResolution = on
    holdDiagnostics(choice)
  }

  func setDiagnosticLogging(_ on: Bool) {
    var choice = diagnostics
    choice.diagnosticLoggingNextLaunch = on
    holdDiagnostics(choice)
  }

  func limitRetinaBinding() -> Binding<Bool> {
    Binding(get: { self.diagnostics.limitRetinaDesktop }, set: { self.setLimitRetinaDesktop($0) })
  }

  func seedResolutionBinding() -> Binding<Bool> {
    Binding(get: { self.diagnostics.seedSafeResolution }, set: { self.setSeedSafeResolution($0) })
  }

  func diagnosticLoggingBinding() -> Binding<Bool> {
    Binding(
      get: { self.diagnostics.diagnosticLoggingNextLaunch },
      set: { self.setDiagnosticLogging($0) })
  }

  private func holdDiagnostics(_ choice: NFS2015DiagnosticsPreference) {
    guard canEditDiagnostics else { return }
    diagnosticsOutcome = nil
    diagnosticsEdit = choice == savedDiagnostics ? nil : choice
  }

  func discardDiagnostics() {
    diagnosticsEdit = nil
    diagnosticsOutcome = nil
  }

  /// Keeps the shown choices for the next launch.
  func saveDiagnostics() {
    guard canEditDiagnostics, let choice = diagnosticsEdit else { return }
    enqueue(.configureDiagnostics(NFS2015DiagnosticsRequest(action: .save, preference: choice)))
  }

  /// Forgets what is saved, which means the defaults.
  func resetDiagnostics() {
    guard canEditDiagnostics else { return }
    enqueue(.configureDiagnostics(NFS2015DiagnosticsRequest(action: .reset)))
  }

  // MARK: x87 sidecar (experimental)

  /// The choice the next Play will use, as saved.
  var savedSidecar: NFS2015SidecarPreference { snapshot.sidecar?.preference ?? .standard }
  /// The choice shown: the player's unsaved one, else the saved one.
  var sidecar: NFS2015SidecarPreference { sidecarEdit ?? savedSidecar }
  var hasPendingSidecar: Bool { sidecarEdit != nil }
  /// Why a saved sidecar file was not used, if it was not.
  var sidecarNotice: String? { snapshot.sidecar?.notice }
  var canEditSidecar: Bool { !isBusy }
  var canResetSidecar: Bool {
    canEditSidecar && (savedSidecar != .standard || sidecarNotice != nil)
  }
  var sidecarRefusal: String? { sidecarOutcome?.refusal }

  var sidecarOutcomeLine: String? {
    switch sidecarOutcome {
    case .saved: "Saved. It applies the next time you press Play."
    case .reset: "Cleared. The x87 sidecar is off."
    case .unchanged: "That was already saved."
    case .refused, nil: nil
    }
  }

  func setSidecarEnabled(_ on: Bool) {
    guard canEditSidecar else { return }
    sidecarOutcome = nil
    let choice = NFS2015SidecarPreference(enabled: on)
    sidecarEdit = choice == savedSidecar ? nil : choice
  }

  func sidecarBinding() -> Binding<Bool> {
    Binding(get: { self.sidecar.enabled }, set: { self.setSidecarEnabled($0) })
  }

  func discardSidecar() {
    sidecarEdit = nil
    sidecarOutcome = nil
  }

  /// Keeps the shown choice for the next Play.
  func saveSidecar() {
    guard canEditSidecar, let choice = sidecarEdit else { return }
    enqueue(.configureSidecar(NFS2015SidecarRequest(action: .save, preference: choice)))
  }

  /// Forgets what is saved, which means the sidecar off.
  func resetSidecar() {
    guard canEditSidecar else { return }
    enqueue(.configureSidecar(NFS2015SidecarRequest(action: .reset)))
  }

  // MARK: Wine experiments

  /// The choice the next Play will use, as saved.
  var savedExperiments: NFS2015WineExperimentsPreference {
    snapshot.experiments?.preference ?? .standard
  }
  /// The choice shown: the player's unsaved one, else the saved one.
  var experiments: NFS2015WineExperimentsPreference { experimentsEdit ?? savedExperiments }
  var hasPendingExperiments: Bool { experimentsEdit != nil }
  /// Why a saved experiments file was not used, if it was not.
  var experimentsNotice: String? { snapshot.experiments?.notice }
  var canEditExperiments: Bool { !isBusy }
  var canResetExperiments: Bool {
    canEditExperiments && (savedExperiments != .standard || experimentsNotice != nil)
  }
  var experimentsRefusal: String? { experimentsOutcome?.refusal }

  var experimentsOutcomeLine: String? {
    switch experimentsOutcome {
    case .saved: "Saved. It applies the next time you press Play."
    case .reset: "Cleared. Every experiment is off."
    case .unchanged: "That was already saved."
    case .refused, nil: nil
    }
  }

  func setExperiments(_ change: (inout NFS2015WineExperimentsPreference) -> Void) {
    guard canEditExperiments else { return }
    experimentsOutcome = nil
    var choice = experiments
    change(&choice)
    experimentsEdit = choice == savedExperiments ? nil : choice
  }

  func flushToggleBinding() -> Binding<Bool> {
    Binding(
      get: { self.experiments.flushToggle },
      set: { value in self.setExperiments { $0.flushToggle = value } })
  }

  func protectToggleBinding() -> Binding<Bool> {
    Binding(
      get: { self.experiments.protectToggle },
      set: { value in self.setExperiments { $0.protectToggle = value } })
  }

  func tracePageBinding() -> Binding<Bool> {
    Binding(
      get: { self.experiments.tracePage },
      set: { value in self.setExperiments { $0.tracePage = value } })
  }

  func rwxWxEmulationBinding() -> Binding<Bool> {
    Binding(
      get: { self.experiments.rwxWxEmulation },
      set: { value in self.setExperiments { $0.rwxWxEmulation = value } })
  }

  func discardExperiments() {
    experimentsEdit = nil
    experimentsOutcome = nil
  }

  /// Keeps the shown choice for the next Play.
  func saveExperiments() {
    guard canEditExperiments, let choice = experimentsEdit else { return }
    enqueue(.configureExperiments(NFS2015WineExperimentsRequest(action: .save, preference: choice)))
  }

  /// Forgets what is saved, which means every experiment off.
  func resetExperiments() {
    guard canEditExperiments else { return }
    enqueue(.configureExperiments(NFS2015WineExperimentsRequest(action: .reset)))
  }

  /// Shows the crash report in Finder.
  func revealCrashReport() {
    guard let notice = crashNotice else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: notice.path)])
  }

  /// Looks once for a crash report the helper wrote since `start`. A reading that arrives after
  /// the watcher was cancelled is dropped.
  func refreshCrashNotice(since start: Date) async {
    let found = await service.latestCrashReport(since: start)
    guard !Task.isCancelled, let found, found != crashNotice else { return }
    crashNotice = found
  }

  /// Looks for a crash report while the helper runs, so the notice appears when the game dies
  /// and not only when the session ends.
  private func watchCrashReports(since start: Date) async {
    while !Task.isCancelled {
      await refreshCrashNotice(since: start)
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }

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
    var crashWatcher: Task<Void, Never>?
    if operation == .play {
      crashNotice = nil
      let start = Date()
      crashWatcher = Task { await self.watchCrashReports(since: start) }
    }
    defer {
      watcher?.cancel()
      crashWatcher?.cancel()
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
    if case .configureMetalFX = operation {
      metalFXOutcome = result.metalFX?.outcome
      if result.metalFX?.outcome?.refusal == nil { metalFXEdit = nil }
    } else if operation != .prepare {
      metalFXOutcome = nil
    }
    if metalFXEdit == (result.metalFX?.preference ?? .off) { metalFXEdit = nil }
    if case .configureDiagnostics = operation {
      diagnosticsOutcome = result.diagnostics?.outcome
      if result.diagnostics?.outcome?.refusal == nil { diagnosticsEdit = nil }
    } else if operation != .prepare {
      diagnosticsOutcome = nil
    }
    if diagnosticsEdit == (result.diagnostics?.preference ?? .standard) { diagnosticsEdit = nil }
    if case .configureSidecar = operation {
      sidecarOutcome = result.sidecar?.outcome
      if result.sidecar?.outcome?.refusal == nil { sidecarEdit = nil }
    } else if operation != .prepare {
      sidecarOutcome = nil
    }
    if sidecarEdit == (result.sidecar?.preference ?? .standard) { sidecarEdit = nil }
    if case .configureExperiments = operation {
      experimentsOutcome = result.experiments?.outcome
      if result.experiments?.outcome?.refusal == nil { experimentsEdit = nil }
    } else if operation != .prepare {
      experimentsOutcome = nil
    }
    if experimentsEdit == (result.experiments?.preference ?? .standard) { experimentsEdit = nil }
    if let report = result.crashReport { crashNotice = report }
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
