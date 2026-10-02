import AppKit
import Foundation
import GameController
import LauncherCore
import Observation
import SharedLauncher
import SwiftUI

@MainActor @Observable
final class LauncherModel {
  private(set) var phase = LauncherPhase.preparing
  private(set) var request = 0
  var settings = GameSettings()
  let saveEditor = SaveEditorModel()
  let rosetta: RosettaSetup
  var tab = "Play"
  var discardConfirmation = false
  private var appliedSettings = GameSettings()
  private(set) var mappingProfiles = [""]
  private(set) var controllerStatus = "Use Refresh to detect connected controllers."
  private var mappings: [String: ControllerMappings] = [:]
  private var paths: AppPaths?
  private var logURL: URL?
  private var operation = "--prepare"
  private var saveRequest: SaveRequest?
  private let maximumDisplayPreset: @MainActor () -> ResolutionPreset?
  private var displayPreset: ResolutionPreset?

  init(
    maximumDisplayPreset: @escaping @MainActor () -> ResolutionPreset? = DisplayQuality
      .maximumPreset,
    rosetta: RosettaSetup = RosettaSetup()
  ) {
    self.rosetta = rosetta
    self.maximumDisplayPreset = maximumDisplayPreset
    displayPreset = maximumDisplayPreset()
  }

  var selectedMappingProfile: String {
    get { settings.mappingProfile }
    set {
      if settings.mappings != mappings[settings.mappingProfile] {
        settings.mappingEdits[settings.mappingProfile] = settings.mappings
      }
      mappings[settings.mappingProfile] = settings.mappings
      settings.mappingProfile = newValue
      settings.mappings = mappings[newValue] ?? mappings[""] ?? ControllerMappings()
    }
  }

  func launch() async {
    phase = operation == "--play" ? .playing : .preparing
    var draft: URL?
    var gameData: URL?
    do {
      if operation == "--install-rosetta" {
        phase = .installingRosetta
        await rosetta.install()
      } else {
        await rosetta.refresh()
      }
      try Task.checkCancellation()
      guard rosetta.isAvailable else {
        phase = .needsRosetta
        return
      }
      if ["--install-rosetta", "--refresh-rosetta"].contains(operation) { operation = "--prepare" }
      let home = FileManager.default.homeDirectoryForCurrentUser
      var support = home.appendingPathComponent("Library/Application Support/NFSMW")
      #if DEBUG
        if let testSupport = ProcessInfo.processInfo.environment["NFSMW_TEST_SUPPORT"] {
          support = URL(fileURLWithPath: testSupport)
        }
      #endif
      let paths = try AppPaths(
        bundle: Bundle.main.bundleURL,
        support: support)
      self.paths = paths
      if operation == "--prepare", !paths.hasGameData {
        phase = .needsGameData
        return
      }
      if operation == "--import-game" {
        guard let selected = await readGameDataFolder() else {
          phase = paths.hasGameData ? .finished : .needsGameData
          return
        }
        try Task.checkCancellation()
        gameData = selected
      }
      if operation == "--import-setup" {
        if let imported = try await readSetupProfile() { settings = imported }
        phase = .finished
        return
      }
      if operation == "--export-setup" {
        try await writeSetupProfile(paths: paths)
        phase = .finished
        return
      }
      if operation == "--import" {
        guard let imported = try await importRequest() else {
          phase = .finished
          return
        }
        saveRequest = imported
        operation = "--save"
      }
      if operation == "--export" {
        try await exportProfile(paths: paths)
        phase = .finished
        return
      }
      try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
      let logs = home.appendingPathComponent("Library/Logs/NFSMW")
      try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      let logURL = logs.appendingPathComponent("session-\(UUID().uuidString).log")
      self.logURL = logURL
      try Data().write(to: logURL, options: .withoutOverwriting)
      let log = try FileHandle(forWritingTo: logURL)
      defer { do { try log.close() } catch { print("Could not close the launch log: \(error)") } }
      if operation != "--prepare", operation != "--import-game" {
        let url = paths.support.appendingPathComponent("settings-request-\(UUID().uuidString).json")
        if operation == "--save", let saveRequest {
          try JSONEncoder().encode(saveRequest).write(to: url, options: .atomic)
        } else {
          try settings.validate()
          try JSONEncoder().encode(settings).write(to: url, options: .atomic)
        }
        draft = url
      }
      let status = try await runSession(
        paths: paths, mode: operation, configuration: gameData ?? draft, output: log)
      guard !Task.isCancelled else { return }
      guard status == 0 else { throw failure(status: status) }
      let snapshot = try JSONDecoder().decode(
        LauncherSnapshot.self,
        from: BoundedFile.read(paths.support.appendingPathComponent("launcher-state.json")))
      if operation != "--save", operation != "--import-game" {
        settings = snapshot.settings
        appliedSettings = snapshot.settings
      }
      saveEditor.load(snapshot.profiles)
      if operation != "--save", operation != "--import-game" {
        mappings = snapshot.mappings
      } else {
        mappings.merge(snapshot.mappings) { existing, _ in existing }
        if case .create(let name) = saveRequest {
          saveEditor.selectedProfile = name
          saveEditor.newProfileName = ""
        }
      }
      mappingProfiles = mappings.keys.sorted()
      phase = .finished
      refreshControllers()
    } catch {
      if !Task.isCancelled { phase = .failed(error.localizedDescription) }
    }
    if let draft {
      do { try FileManager.default.removeItem(at: draft) } catch {
        print("Could not remove settings request: \(error)")
      }
    }
  }

  func playAgain() { enqueue("--play") }
  func returnToGame() {
    if let support = paths?.support { GameWindow.bringToFront(support: support) }
  }
  func applySettings() { enqueue("--configure") }
  func reload() {
    if hasPendingChanges { discardConfirmation = true } else { enqueue("--prepare") }
  }
  func discardChanges() { enqueue("--prepare") }
  var hasPendingChanges: Bool {
    GameSettings.definitions.contains { settings.value($0.id) != appliedSettings.value($0.id) }
      || settings.unlockAll != appliedSettings.unlockAll
      || settings.mappings != appliedSettings.mappings
      || settings.mappingProfile != appliedSettings.mappingProfile
      || !settings.mappingEdits.isEmpty
  }
  func importSetup() { enqueue("--import-setup") }
  func importGameData() { enqueue("--import-game") }
  func installRosetta() { enqueue("--install-rosetta") }
  func refreshRosetta() {
    guard phase == .needsRosetta else { return }
    enqueue("--refresh-rosetta")
  }

  func watchApplicationActivation() async {
    for await _ in NotificationCenter.default.notifications(
      named: NSApplication.didBecomeActiveNotification
    ).map({ _ in true }) {
      guard !Task.isCancelled else { return }
      refreshRosetta()
    }
  }
  func exportSetup() { enqueue("--export-setup") }
  func importSave() { enqueue("--import") }
  func exportSave() { enqueue("--export") }
  func changeCash() { enqueueSave { try saveEditor.moneyRequest() } }
  func changeCar() { enqueueSave { try saveEditor.carRequest() } }
  func addCar() { enqueueSave { try saveEditor.addCarRequest() } }
  func createProfile() { enqueueSave { try saveEditor.createRequest() } }
  func removeProfile() { enqueueSave { try saveEditor.removeRequest() } }
  func requestProfileRemoval() { saveEditor.removeConfirmation = true }
  func duplicateCar() { enqueueSave { try saveEditor.duplicateRequest() } }
  func backupSave() { enqueueSave { try saveEditor.backupRequest() } }
  func restoreSave() { enqueueSave { try saveEditor.restoreRequest() } }

  private func enqueueSave(_ make: () throws -> SaveRequest) {
    guard !phase.isBusy else { return }
    do {
      saveRequest = try make()
      enqueue("--save")
    } catch { phase = .failed(error.localizedDescription) }
  }

  private func enqueue(_ mode: String) {
    guard !phase.isBusy else { return }
    operation = mode
    request += 1
  }

  func settingBinding(_ id: String) -> Binding<String> {
    Binding(get: { self.settings.value(id) }, set: { self.settings.values[id] = $0 })
  }

  func commandBinding(_ id: String) -> Binding<String> {
    Binding(
      get: { self.settings.mappings.value(for: id) },
      set: { self.settings.mappings.bindings[id] = $0 })
  }

  var selectedResolution: String {
    get { settings.value("width") + "x" + settings.value("height") }
    set {
      guard let preset = availableResolutions.first(where: { $0.id == newValue }) else { return }
      settings.values["width"] = String(preset.width)
      settings.values["height"] = String(preset.height)
    }
  }
  var aspectRatio: AspectRatio {
    get { availableResolutions.first { $0.id == selectedResolution }?.ratio ?? .wide16to10 }
    set {
      guard
        let preset = availableResolutions.filter({ $0.ratio == newValue }).min(by: {
          abs($0.height - (Int(settings.value("height")) ?? 1050))
            < abs($1.height - (Int(settings.value("height")) ?? 1050))
        })
      else { return }
      selectedResolution = preset.id
    }
  }
  var resolutionPresets: [ResolutionPreset] {
    availableResolutions.filter { $0.ratio == aspectRatio }
  }
  var aspectRatios: [AspectRatio] {
    AspectRatio.allCases.filter { ratio in availableResolutions.contains { $0.ratio == ratio } }
  }
  private var availableResolutions: [ResolutionPreset] {
    var presets = ResolutionPreset.all
    let current = ResolutionPreset(
      width: Int(settings.value("width")) ?? 0, height: Int(settings.value("height")) ?? 0)
    for preset in [displayPreset, current].compactMap({ $0 })
    where !presets.contains(where: { $0.id == preset.id }) { presets.append(preset) }
    return presets.sorted { $0.width * $0.height < $1.width * $1.height }
  }
  func graphics(in group: String) -> [SettingDefinition] {
    GraphicsCatalog.settings.filter { $0.group == group && $0.id != "width" && $0.id != "height" }
  }
  func actions(in group: String) -> [ControllerAction] {
    ControllerAction.all.filter { $0.group == group }
  }

  func resetMappings() { settings.mappings = ControllerMappings() }
  func tunedGraphics() {
    for definition in GraphicsCatalog.settings
    where !Self.displayPreferences.contains(definition.id) {
      settings.values[definition.id] = definition.defaultValue
    }
  }
  func lighterGraphics() {
    tunedGraphics()
    settings.values["scale"] = "0.75"
    settings.values["shadowResolution"] = "1024"
    settings.values["msaa"] = "0"
  }
  func maximumGraphics() {
    guard let display = maximumDisplayPreset() else {
      phase = .failed(
        "Could not detect a display resolution within the supported 640–7680 by 480–4320 range. Select a resolution in Graphics."
      )
      return
    }
    tunedGraphics()
    displayPreset = display
    selectedResolution = display.id
    for (key, value) in [
      "window": "4", "retina": "1", "scale": "1", "lodBias": "true",
      "msaa": "2", "smaa": "0", "filtering": "2", "world": "3", "cars": "1",
      "carReflections": "3", "roadReflections": "3", "reflectionUpdate": "1",
      "shadows": "2", "shadowResolution": "8192", "shadowLOD": "1", "shadowFix": "1",
      "motionBlur": "1", "bloom": "1", "rain": "1", "streaks": "1", "particles": "1",
      "droplets": "1", "treatment": "1", "fixHUD": "1", "hideMouse": "1",
    ] { settings.values[key] = value }
  }

  func refreshControllers() {
    let controllers = GCController.controllers()
    controllerStatus =
      controllers.isEmpty
      ? "Connect an Xbox or PlayStation controller by USB or Bluetooth. Keyboard controls are also available."
      : controllers.map { $0.vendorName ?? "Game controller" }.joined(separator: ", ")
  }

  func openSaves() {
    guard let paths else { return }
    if !NSWorkspace.shared.open(paths.saves) {
      phase = .failed("The saves folder is not available yet.")
    }
  }
  func openLog() {
    guard let logURL else { return }
    if !NSWorkspace.shared.open(logURL) { phase = .failed("Could not open the session log.") }
  }

  private func failure(status: Int32?) -> LauncherError {
    if status == 73 { return .alreadyRunning }
    let code = status.map(String.init) ?? "unknown"
    guard let logURL else { return .operation("The game session ended with status \(code).") }
    do {
      let handle = try FileHandle(forReadingFrom: logURL)
      defer {
        do { try handle.close() } catch { print("Could not close the session log: \(error)") }
      }
      let size = try handle.seekToEnd()
      try handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
      let tail = try handle.read(upToCount: 4096) ?? Data()
      let lastLine = String(decoding: tail, as: UTF8.self).split(separator: "\n").last
      return .operation(
        lastLine.map(String.init)
          ?? "The game session ended with status \(code). Open Log for details.")
    } catch {
      return .operation(
        "The game session ended with status \(code). Could not read its log: \(error.localizedDescription)"
      )
    }
  }

  /// Cancellation detaches the UI; the helper retains its process lock until the game exits.
  private func runSession(paths: AppPaths, mode: String, configuration: URL?, output: FileHandle)
    async throws -> Int32?
  {
    let process = Process()
    let (events, continuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
    process.executableURL = paths.session
    process.arguments = [mode, paths.bundle.path, "--support", paths.support.path]
    if let configuration {
      process.arguments?.append(contentsOf: [
        mode == "--import-game"
          ? "--game-data" : (mode == "--save" ? "--save-request" : "--settings"),
        configuration.path,
      ])
    }
    process.currentDirectoryURL = paths.bundle.deletingLastPathComponent()
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    process.terminationHandler = { child in
      continuation.yield(child.terminationStatus)
      continuation.finish()
    }
    do { try process.run() } catch {
      continuation.finish()
      throw error
    }
    for await status in events { return status }
    return nil
  }
}
