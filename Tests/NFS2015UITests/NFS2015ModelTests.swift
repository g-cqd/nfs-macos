import Foundation
import LauncherCore
import NFS2015Core
import SharedLauncher
import Testing

@testable import NFS2015Launcher

@MainActor
struct NFS2015ModelTests {
  final class FakeService: NFS2015Serving, @unchecked Sendable {
    var snapshot: NFS2015Snapshot
    var failure: (any Error)?
    var progress: PrefixSeed.Progress?
    private(set) var performed: [NFS2015Operation] = []

    init(snapshot: NFS2015Snapshot) { self.snapshot = snapshot }

    func perform(_ operation: NFS2015Operation) async throws -> NFS2015Snapshot {
      performed.append(operation)
      if let failure { throw failure }
      return snapshot
    }

    func logLocation() async -> URL? { nil }

    func preparationProgress() async -> PrefixSeed.Progress? { progress }
  }

  struct FakeRosetta: RosettaProviding {
    let available: Bool
    func isAvailable() async throws -> Bool { available }
    func requestInstallation() async throws {}
  }

  static let digest = String(repeating: "ab", count: 32)

  static var recorded: NFS2015Settings {
    var settings = NFS2015Settings()
    settings.values = [
      "render.vsync": "0", "quality.texture": "2", "quality.mesh": "2", "quality.shadow": "1",
      "quality.effects": "2", "quality.terrain": "1", "quality.undergrowth": "1",
      "render.motionBlur": "1", "render.filmGrain": "1", "render.refreshRate": "60.000000",
      "render.resolution": "2560x1600", "audio.music": "0.750000",
    ]
    settings.observed = ["render.antiAliasing": "2"]
    return settings
  }

  private func model(
    blocker: String? = nil, options: Bool = true, rosetta: Bool = true, problem: String? = nil,
    backups: NFS2015BackupState? = nil
  ) -> (NFS2015Model, FakeService) {
    let service = FakeService(
      snapshot: NFS2015Snapshot(
        blocker: blocker, clientVersion: "13.796.0.6309", installedAt: "/Windows",
        hasOptionsFile: options, settings: options ? Self.recorded : NFS2015Settings(),
        optionsDigest: options ? Self.digest : nil, optionsProblem: problem, backups: backups))
    return (
      NFS2015Model(
        service: service, rosetta: RosettaSetup(service: FakeRosetta(available: rosetta))), service
    )
  }

  @Test
  func `becomes ready once the installation and Rosetta are both usable`() async {
    let (model, service) = model()
    await model.run()
    #expect(model.phase == .ready)
    #expect(model.canPlay)
    #expect(model.blocker == nil)
    #expect(model.clientVersion == "13.796.0.6309")
    #expect(service.performed == [.prepare])
  }

  /// A Play that left the EA app running tells the player what to do and keeps Play usable, so
  /// the next press reuses the running client.
  @Test
  func `keeps Play enabled and shows what to do when the EA app is running but not ready`() async {
    let (model, service) = model()
    service.snapshot.notice =
      "The EA app is open but not signed in. Sign in, then press Play again."
    await model.run()
    #expect(model.phase == .ready)
    #expect(model.canPlay)
    #expect(model.statusMessage.contains("not signed in"))
    #expect(model.errorMessage == nil)
    model.play()
    await model.run()
    #expect(service.performed == [.prepare, .play])
    #expect(model.canPlay)
  }

  @Test
  func `says Ready to play when there is nothing to add`() async {
    let (model, _) = model()
    await model.run()
    #expect(model.statusMessage == "Ready to play")
  }

  @Test
  func `shows the dependency message and refuses to play without it`() async {
    let (model, _) = model(blocker: "Open the EA app and sign in to your EA account.")
    await model.run()
    #expect(model.phase == .needsInstallation)
    #expect(!model.canPlay)
    #expect(model.blocker?.contains("sign in") == true)
  }

  @Test
  func `will not play before Rosetta is installed`() async {
    let (model, service) = model(rosetta: false)
    await model.run()
    #expect(model.phase == .needsRosetta)
    model.play()
    await model.run()
    #expect(model.phase == .needsRosetta)
    #expect(service.performed == [.prepare])
  }

  @Test
  func `keeps settings uneditable until the game has written its options file`() async {
    let (model, _) = model(options: false)
    await model.run()
    #expect(!model.canEditSettings)
    #expect(model.settingsNotice?.contains("options file") == true)
  }

  @Test
  func `sends only the settings the player changed, with the file they saw`() async {
    let (model, service) = model()
    await model.run()
    model.set("render.vsync", to: "1")
    #expect(model.hasPendingChanges)
    model.set("quality.texture", to: "9")
    #expect(model.value("quality.texture") == "2")
    model.apply()
    await model.run()
    #expect(service.performed.count == 2)
    #expect(
      service.performed[1]
        == .configure(
          NFS2015SettingsRequest(
            action: .save, changes: ["render.vsync": "1"], expectedDigest: Self.digest)))
  }

  @Test
  func `holds a number inside its range and shows it as the player typed it`() async {
    let (model, _) = model()
    await model.run()
    model.set("render.refreshRate", to: "9999")
    #expect(model.value("render.refreshRate") == "480.000000")
    model.numberBinding("audio.music").wrappedValue = 3
    #expect(model.value("audio.music") == "1.000000")
    model.set("render.resolution", to: "99999x2")
    #expect(model.value("render.resolution") == "7680x480")
    model.set("render.refreshRate", to: "fast")
    #expect(model.value("render.refreshRate") == "480.000000")
  }

  @Test
  func `choosing the value the file already holds is not a change`() async {
    let (model, _) = model()
    await model.run()
    model.set("render.refreshRate", to: "75")
    #expect(model.hasPendingChanges)
    model.set("render.refreshRate", to: "60")
    #expect(!model.hasPendingChanges)
  }

  @Test
  func `will not change a setting the game has not written or one that is only shown`() async {
    let (model, _) = model()
    await model.run()
    model.set("input.vibration", to: "1")
    model.set("render.antiAliasing", to: "1")
    model.set("render.nothing", to: "1")
    #expect(!model.hasPendingChanges)
    let shown = NFS2015Catalog.setting("render.antiAliasing")
    #expect(shown.map(model.isChangeable) == false)
    #expect(shown.flatMap(model.recordedText) == "2")
  }

  @Test
  func `the maximum quality preset changes pending choices only, and leaves the resolution`() async
  {
    let (model, service) = model()
    await model.run()
    model.applyMaximumQuality()
    #expect(model.edits["quality.texture"] == "3" && model.edits["quality.undergrowth"] == "3")
    #expect(model.edits["render.motionBlur"] == "0" && model.edits["render.filmGrain"] == "0")
    #expect(
      model.edits["render.resolution"] == nil && model.value("render.resolution") == "2560x1600")
    #expect(service.performed == [.prepare])
  }

  @Test
  func `the preset skips an option the game's file does not hold`() async {
    var settings = Self.recorded
    settings.values["render.filmGrain"] = nil
    let service = FakeService(
      snapshot: NFS2015Snapshot(
        hasOptionsFile: true, settings: settings, optionsDigest: Self.digest))
    let model = NFS2015Model(
      service: service, rosetta: RosettaSetup(service: FakeRosetta(available: true)))
    await model.run()
    model.applyMaximumQuality()
    #expect(model.edits["render.filmGrain"] == nil && model.edits["quality.mesh"] == "3")
  }

  @Test
  func `a refused save keeps the player's choices and shows the reason`() async {
    let (model, service) = model()
    await model.run()
    model.set("render.vsync", to: "1")
    service.snapshot.outcome = .refused("Need for Speed is running. Quit it first.")
    model.apply()
    await model.run()
    #expect(model.edits == ["render.vsync": "1"])
    #expect(model.refusal?.contains("running") == true)
    #expect(model.statusMessage.contains("running"))
    #expect(model.phase == .ready)
  }

  @Test
  func `a saved change clears the choices and reports what the file holds`() async {
    let (model, service) = model()
    await model.run()
    model.set("render.vsync", to: "1")
    service.snapshot.settings.values["render.vsync"] = "1"
    service.snapshot.outcome = .saved([
      NFS2015OptionLine(key: "GstRender.VSyncEnabled", before: "0", now: "1")
    ])
    model.apply()
    await model.run()
    #expect(!model.hasPendingChanges && model.refusal == nil)
    #expect(
      model.outcomeLines == [
        "Saved. The game's file now holds:", "GstRender.VSyncEnabled 1 (was 0)",
      ])
    model.set("render.vsync", to: "0")
    #expect(model.outcomeLines.isEmpty)
  }

  /// A value the game changed meanwhile must never be put back by an older choice.
  @Test
  func `a reload keeps only the choices that still differ from the game's file`() async {
    let (model, service) = model()
    await model.run()
    model.set("render.vsync", to: "1")
    model.set("quality.mesh", to: "0")
    service.snapshot.settings.values["render.vsync"] = "1"
    model.reload()
    await model.run()
    #expect(model.edits == ["quality.mesh": "0"])
    #expect(model.value("render.vsync") == "1")
  }

  @Test
  func `offers no controls before the game has written its file, or for a layout it cannot edit`()
    async
  {
    let (missing, _) = model(options: false)
    await missing.run()
    #expect(!missing.showsSettingControls && !missing.canEditSettings)
    #expect(missing.settingsNotice?.contains("nothing here to change") == true)
    missing.apply()
    missing.restoreGameDefaults()
    let (odd, service) = model(
      problem: "The game's options file has a layout this app has not validated.")
    await odd.run()
    #expect(!odd.showsSettingControls && !odd.canEditSettings)
    #expect(odd.settingsNotice?.contains("not validated") == true)
    odd.set("render.vsync", to: "1")
    odd.restoreGameDefaults()
    #expect(service.performed == [.prepare])
    #expect(!odd.hasPendingChanges)
  }

  @Test
  func `restore and undo are offered only when a saved copy exists, and name the file`() async {
    let (none, _) = model(backups: NFS2015BackupState())
    await none.run()
    #expect(!none.canRestoreOriginal && !none.canUndoLastSave)
    let (some, service) = model(backups: NFS2015BackupState(original: true, previous: true))
    await some.run()
    #expect(some.canRestoreOriginal && some.canUndoLastSave)
    some.restoreGameDefaults()
    await some.run()
    some.undoLastSave()
    await some.run()
    #expect(
      service.performed == [
        .prepare,
        .configure(NFS2015SettingsRequest(action: .restoreOriginal, expectedDigest: Self.digest)),
        .configure(NFS2015SettingsRequest(action: .restorePrevious, expectedDigest: Self.digest)),
      ])
  }

  @Test
  func `reports a helper failure without clearing the last known state`() async {
    let (model, service) = model()
    await model.run()
    service.failure = LauncherError.operation("The operation ended with status 1.")
    model.reload()
    await model.run()
    #expect(model.errorMessage?.contains("status 1") == true)
    #expect(model.clientVersion == "13.796.0.6309")
    #expect(!model.canPlay)
  }

  @Test
  func `discards edits back to the recorded settings`() async {
    let (model, _) = model()
    await model.run()
    model.binding("render.vsync").wrappedValue = "1"
    #expect(model.hasPendingChanges)
    model.discard()
    #expect(!model.hasPendingChanges && model.value("render.vsync") == "0")
  }

  @Test
  func `lists the settings in five groups, with the experimental ones apart`() {
    let (model, _) = model()
    let titles = NFS2015SettingGroup.allCases.filter { !model.settings(in: $0).isEmpty }.map(
      \.title)
    #expect(titles == ["Display", "Quality", "Controls", "Audio", "Experimental"])
    #expect(model.settings(in: .experimental).allSatisfy { $0.isExperimental })
    #expect(model.settings(in: .display).allSatisfy { !$0.isExperimental })
  }
  // MARK: The bundled edition, which owns its Windows folder

  private func bundled(
    setup: NFS2015Setup?, blocker: String? = nil, rosetta: Bool = true, carriesGame: Bool = true
  ) -> (NFS2015Model, FakeService) {
    let service = FakeService(
      snapshot: NFS2015Snapshot(
        blocker: blocker, clientVersion: setup == .installClient ? nil : "13.796.0.6309",
        installedAt: "/Player/Data/Prefix", hasOptionsFile: false, ownsWindowsFolder: true,
        setup: setup))
    return (
      NFS2015Model(
        service: service, rosetta: RosettaSetup(service: FakeRosetta(available: rosetta)),
        carriesGame: carriesGame), service
    )
  }

  @Test
  func `offers the EA app installer until the client is installed`() async {
    let (model, _) = bundled(setup: .installClient, blocker: "Install EA App first.")
    await model.run()
    #expect(model.phase == .needsInstallation)
    #expect(model.ownsWindowsFolder && model.needsClientInstall)
    #expect(model.canInstallClient && !model.canOpenClient && !model.canPlay)
    #expect(model.statusMessage.contains("Install the EA app"))
    #expect(!model.statusMessage.contains("Choose the Windows folder"))
  }

  @Test
  func `asks the player to sign in once the client is installed`() async {
    let (model, service) = bundled(setup: .signIn, blocker: "Press Open EA App.")
    await model.run()
    #expect(model.canOpenClient && model.canInstallClient && !model.canPlay)
    #expect(model.statusMessage.contains("sign in"))
    model.openClient()
    await model.run()
    #expect(service.performed == [.prepare, .openClient])
  }

  @Test
  func `sends the chosen installer to the helper`() async {
    let (model, service) = bundled(setup: .installClient, blocker: "Install EA App first.")
    await model.run()
    let installer = URL(fileURLWithPath: "/Users/player/Downloads/EAappInstaller.exe")
    model.installClient(installer)
    await model.run()
    #expect(service.performed == [.prepare, .installClient(installer)])
  }

  @Test
  func `can play once the client is installed and signed in`() async {
    let (model, _) = bundled(setup: nil)
    await model.run()
    #expect(model.phase == .ready && model.canPlay)
    #expect(model.statusMessage == "Ready to play")
  }

  @Test
  func `will not start a Windows program before Rosetta is installed`() async {
    let (model, service) = bundled(setup: .installClient, blocker: "Install", rosetta: false)
    await model.run()
    model.installClient(URL(fileURLWithPath: "/tmp/EAappInstaller.exe"))
    await model.run()
    #expect(model.phase == .needsRosetta)
    model.openClient()
    await model.run()
    #expect(model.phase == .needsRosetta)
    #expect(service.performed == [.prepare])
  }

  @Test
  func `runs only the last request queued before the helper starts`() async {
    let (model, service) = bundled(setup: .signIn, blocker: "Press Open EA App.")
    await model.run()
    model.openClient()
    model.installClient(URL(fileURLWithPath: "/tmp/EAappInstaller.exe"))
    await model.run()
    #expect(
      service.performed == [
        .prepare, .installClient(URL(fileURLWithPath: "/tmp/EAappInstaller.exe")),
      ])
  }

  @Test
  func `explains the long first start of an app that carries the game`() async {
    let (carrying, _) = bundled(setup: nil, carriesGame: true)
    #expect(carrying.statusMessage.contains("first use"))
    let (importing, _) = bundled(setup: nil, carriesGame: false)
    #expect(importing.statusMessage == "Checking your installation…")
    await carrying.run()
    #expect(!carrying.statusMessage.contains("first use"))
  }

  @Test
  func `shows how many game files the first start has copied`() async {
    let (model, service) = bundled(setup: nil)
    // The Windows folder is still being created: an indeterminate wait, the plain explanation.
    service.progress = PrefixSeed.Progress(files: 0, totalFiles: 144, bytes: 0, totalBytes: 1000)
    await model.refreshPreparation()
    #expect(model.preparationFraction == nil)
    #expect(model.statusMessage.contains("creating its Windows folder"))

    service.progress = PrefixSeed.Progress(files: 36, totalFiles: 144, bytes: 250, totalBytes: 1000)
    await model.refreshPreparation()
    #expect(model.preparationFraction == 0.25)
    #expect(model.statusMessage.contains("copied 36 of 144 game files (25 %)"))
    #expect(model.statusMessage.contains("few minutes"))

    // Once the helper has finished, the line goes back to the ordinary status and no bar remains.
    await model.run()
    #expect(model.preparationFraction == nil)
    #expect(model.statusMessage == "Ready to play")
  }

  @Test
  func `an app that carries no game never shows a copy progress`() async {
    let (model, service) = bundled(setup: nil, carriesGame: false)
    service.progress = PrefixSeed.Progress(files: 36, totalFiles: 144, bytes: 250, totalBytes: 1000)
    await model.refreshPreparation()
    #expect(model.statusMessage == "Checking your installation…")
  }

  @Test
  func `an import app keeps asking for a Windows folder and never offers the installer`() async {
    let (model, _) = model(blocker: "Choose the Windows folder.")
    await model.run()
    #expect(!model.ownsWindowsFolder && !model.canInstallClient && !model.canOpenClient)
    #expect(model.statusMessage == "Choose the Windows folder that holds the EA app and this game.")
  }
}

struct NFS2015SupportFolderTests {
  private let home = URL(fileURLWithPath: "/Users/player")

  @Test
  func `uses the account's own folder by default`() {
    let folder = NFS2015SessionClient.supportFolder(environment: [:], home: home)
    #expect(folder.path == "/Users/player/Library/Application Support/NFS2015Mac")
  }

  @Test
  func `HOME does not move the player folder`() {
    let folder = NFS2015SessionClient.supportFolder(environment: ["HOME": "/tmp/other"], home: home)
    #expect(folder.path == "/Users/player/Library/Application Support/NFS2015Mac")
  }

  @Test
  func `an explicit override points the starter at another folder`() {
    let folder = NFS2015SessionClient.supportFolder(
      environment: [NFS2015SessionClient.supportFolderVariable: "/tmp/private support/NFS"],
      home: home)
    #expect(folder.path == "/tmp/private support/NFS")
  }

  @Test(arguments: ["", "relative/folder", "/tmp/../Users/player/Library", "~/folder"])
  func `ignores an override that is not a plain absolute folder`(value: String) {
    let folder = NFS2015SessionClient.supportFolder(
      environment: [NFS2015SessionClient.supportFolderVariable: value], home: home)
    #expect(folder.path == "/Users/player/Library/Application Support/NFS2015Mac")
  }
}
