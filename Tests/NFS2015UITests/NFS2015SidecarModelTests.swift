import Foundation
import NFS2015Core
import SharedLauncher
import Testing

@testable import NFS2015Launcher

@MainActor
struct NFS2015SidecarModelTests {
  typealias Service = NFS2015ModelTests.FakeService

  private static let on = NFS2015SidecarPreference(enabled: true)

  private func model(saved: NFS2015SidecarState? = nil) -> (NFS2015Model, Service) {
    let service = Service(
      snapshot: NFS2015Snapshot(
        clientVersion: "13.796.0.6309", installedAt: "/Windows", hasOptionsFile: true,
        settings: NFS2015ModelTests.recorded, optionsDigest: NFS2015ModelTests.digest,
        sidecar: saved))
    let sut = NFS2015Model(
      service: service,
      rosetta: RosettaSetup(service: NFS2015ModelTests.FakeRosetta(available: true)))
    return (sut, service)
  }

  @Test
  func `starts off with nothing pending, from a state file that has no sidecar entry`() async {
    let (sut, _) = model()
    await sut.run()
    #expect(sut.sidecar == .standard && sut.savedSidecar == .standard && !sut.sidecar.enabled)
    #expect(!sut.hasPendingSidecar && !sut.canResetSidecar)
    #expect(sut.sidecarNotice == nil && sut.sidecarOutcomeLine == nil)
  }

  @Test
  func `sends what the player chose, and nothing for a choice that equals the saved one`() async {
    let (sut, service) = model()
    await sut.run()
    sut.setSidecarEnabled(true)
    #expect(sut.hasPendingSidecar && sut.sidecar.enabled)
    sut.setSidecarEnabled(false)
    #expect(!sut.hasPendingSidecar)
    sut.saveSidecar()
    await sut.run()
    #expect(service.performed == [.prepare])
    sut.setSidecarEnabled(true)
    sut.saveSidecar()
    await sut.run()
    #expect(
      service.performed.last
        == .configureSidecar(NFS2015SidecarRequest(action: .save, preference: Self.on)))
  }

  @Test
  func `adopts the saved choice and says when it applies`() async {
    let (sut, service) = model()
    await sut.run()
    sut.setSidecarEnabled(true)
    service.snapshot.sidecar = NFS2015SidecarState(preference: Self.on, outcome: .saved)
    sut.saveSidecar()
    await sut.run()
    #expect(sut.savedSidecar == Self.on && !sut.hasPendingSidecar)
    #expect(sut.sidecarOutcomeLine == "Saved. It applies the next time you press Play.")
    #expect(sut.canResetSidecar)
    sut.enableController()
    await sut.run()
    #expect(sut.sidecarOutcomeLine == nil && sut.savedSidecar == Self.on)
  }

  @Test
  func `keeps the player's choice when a request is refused, and shows why`() async {
    let (sut, service) = model()
    await sut.run()
    sut.setSidecarEnabled(true)
    service.snapshot.sidecar = NFS2015SidecarState(
      preference: .standard, outcome: .refused("Could not save the x87 sidecar choice: disk full"))
    sut.saveSidecar()
    await sut.run()
    #expect(sut.hasPendingSidecar && sut.sidecar.enabled)
    #expect(sut.sidecarRefusal?.contains("disk full") == true)
  }

  @Test
  func `resets through the helper, and offers it for an unusable saved file`() async {
    let unusable = NFS2015SidecarState(
      preference: .standard, notice: "The saved x87 sidecar choice could not be used.")
    let (sut, service) = model(saved: unusable)
    await sut.run()
    #expect(sut.sidecarNotice?.contains("could not be used") == true && sut.canResetSidecar)
    sut.resetSidecar()
    await sut.run()
    #expect(service.performed.last == .configureSidecar(NFS2015SidecarRequest(action: .reset)))
  }

  @Test
  func `discarding drops the unsaved choice`() async {
    let (sut, _) = model()
    await sut.run()
    sut.setSidecarEnabled(true)
    sut.discardSidecar()
    #expect(sut.sidecar == .standard && !sut.hasPendingSidecar)
  }

  @Test
  func `will not take a choice while the helper is busy`() async {
    let (sut, service) = model()
    #expect(sut.isBusy)
    sut.setSidecarEnabled(true)
    sut.resetSidecar()
    #expect(!sut.hasPendingSidecar)
    await sut.run()
    #expect(service.performed == [.prepare])
  }
}
