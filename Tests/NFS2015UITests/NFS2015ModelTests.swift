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
}
