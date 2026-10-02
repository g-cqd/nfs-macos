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
  private(set) var edited = NFS2015Settings()
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
