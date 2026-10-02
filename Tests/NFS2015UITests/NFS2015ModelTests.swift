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
    private(set) var performed: [NFS2015Operation] = []

    init(snapshot: NFS2015Snapshot) { self.snapshot = snapshot }

    func perform(_ operation: NFS2015Operation) async throws -> NFS2015Snapshot {
      performed.append(operation)
      if let failure { throw failure }
      return snapshot
    }

    func logLocation() async -> URL? { nil }
  }

  struct FakeRosetta: RosettaProviding {
    let available: Bool
    func isAvailable() async throws -> Bool { available }
    func requestInstallation() async throws {}
  }

  private func model(blocker: String? = nil, options: Bool = true, rosetta: Bool = true) -> (
    NFS2015Model, FakeService
  ) {
    var settings = NFS2015Settings()
    settings.values["render.vsync"] = "0"
    let service = FakeService(
      snapshot: NFS2015Snapshot(
        blocker: blocker, clientVersion: "13.796.0.6309", installedAt: "/Windows",
        hasOptionsFile: options, settings: settings))
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
  func `sends only validated settings to the helper`() async {
    let (model, service) = model()
    await model.run()
    model.binding("render.vsync").wrappedValue = "1"
    #expect(model.hasPendingChanges)
    model.binding("quality.texture").wrappedValue = "9"
    #expect(model.edited.value("quality.texture") == "3")
    model.apply()
    await model.run()
    #expect(service.performed.count == 2)
    guard case .configure(let sent) = service.performed[1] else {
      Issue.record("Expected a configure operation")
      return
    }
    #expect(sent.value("render.vsync") == "1")
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
    #expect(!model.hasPendingChanges)
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
