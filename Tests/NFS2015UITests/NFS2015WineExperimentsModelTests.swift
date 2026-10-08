import Foundation
import NFS2015Core
import SharedLauncher
import Testing

@testable import NFS2015Launcher

@MainActor
struct NFS2015WineExperimentsModelTests {
  typealias Service = NFS2015ModelTests.FakeService

  private static let flush = NFS2015WineExperimentsPreference(flushToggle: true)

  private func model(saved: NFS2015WineExperimentsState? = nil) -> (NFS2015Model, Service) {
    let service = Service(
      snapshot: NFS2015Snapshot(
        clientVersion: "13.805.2.6319", installedAt: "/Windows", hasOptionsFile: true,
        settings: NFS2015ModelTests.recorded, optionsDigest: NFS2015ModelTests.digest,
        experiments: saved))
    let sut = NFS2015Model(
      service: service,
      rosetta: RosettaSetup(service: NFS2015ModelTests.FakeRosetta(available: true)))
    return (sut, service)
  }

  @Test
  func `starts with every switch off and nothing pending, from a state file that has no entry`()
    async
  {
    let (sut, _) = model()
    await sut.run()
    #expect(sut.experiments == .standard && sut.savedExperiments == .standard)
    #expect(!sut.hasPendingExperiments && !sut.canResetExperiments)
    #expect(sut.experimentsNotice == nil && sut.experimentsOutcomeLine == nil)
    #expect(!sut.flushToggleBinding().wrappedValue && !sut.protectToggleBinding().wrappedValue)
    #expect(!sut.tracePageBinding().wrappedValue)
  }

  @Test
  func `sends what the player chose, and nothing for a choice that equals the saved one`() async {
    let (sut, service) = model()
    await sut.run()
    sut.flushToggleBinding().wrappedValue = true
    #expect(sut.hasPendingExperiments && sut.experiments.flushToggle)
    sut.flushToggleBinding().wrappedValue = false
    #expect(!sut.hasPendingExperiments)
    sut.saveExperiments()
    await sut.run()
    #expect(service.performed == [.prepare])
    sut.flushToggleBinding().wrappedValue = true
    sut.tracePageBinding().wrappedValue = true
    sut.saveExperiments()
    await sut.run()
    #expect(
      service.performed.last
        == .configureExperiments(
          NFS2015WineExperimentsRequest(
            action: .save,
            preference: NFS2015WineExperimentsPreference(flushToggle: true, tracePage: true))))
  }

  @Test
  func `each toggle changes only its own switch`() async {
    let (sut, _) = model()
    await sut.run()
    sut.protectToggleBinding().wrappedValue = true
    #expect(sut.experiments == .init(protectToggle: true))
    sut.tracePageBinding().wrappedValue = true
    #expect(sut.experiments == .init(protectToggle: true, tracePage: true))
  }

  @Test
  func `the workaround toggle changes only its own switch and is sent as chosen`() async {
    let (sut, service) = model()
    await sut.run()
    // A fresh state has the workaround on; the toggle turns it off, and Save sends exactly that.
    #expect(sut.rwxWxEmulationBinding().wrappedValue && !sut.hasPendingExperiments)
    sut.rwxWxEmulationBinding().wrappedValue = false
    #expect(sut.experiments == .init(rwxWxEmulation: false) && sut.hasPendingExperiments)
    sut.saveExperiments()
    await sut.run()
    #expect(
      service.performed.last
        == .configureExperiments(
          NFS2015WineExperimentsRequest(
            action: .save, preference: NFS2015WineExperimentsPreference(rwxWxEmulation: false))))
    // Turning it back on is the default again, so nothing is pending.
    sut.rwxWxEmulationBinding().wrappedValue = true
    #expect(!sut.hasPendingExperiments)
  }

  @Test
  func `adopts the saved choice and says when it applies`() async {
    let (sut, service) = model()
    await sut.run()
    sut.flushToggleBinding().wrappedValue = true
    service.snapshot.experiments = NFS2015WineExperimentsState(
      preference: Self.flush, outcome: .saved)
    sut.saveExperiments()
    await sut.run()
    #expect(sut.savedExperiments == Self.flush && !sut.hasPendingExperiments)
    #expect(sut.experimentsOutcomeLine == "Saved. It applies the next time you press Play.")
    #expect(sut.canResetExperiments)
    sut.enableController()
    await sut.run()
    #expect(sut.experimentsOutcomeLine == nil && sut.savedExperiments == Self.flush)
  }

  @Test
  func `keeps the player's choice when a request is refused, and shows why`() async {
    let (sut, service) = model()
    await sut.run()
    sut.protectToggleBinding().wrappedValue = true
    service.snapshot.experiments = NFS2015WineExperimentsState(
      preference: .standard,
      outcome: .refused("Could not save the Wine experiment choice: disk full"))
    sut.saveExperiments()
    await sut.run()
    #expect(sut.hasPendingExperiments && sut.experiments.protectToggle)
    #expect(sut.experimentsRefusal?.contains("disk full") == true)
  }

  @Test
  func `resets through the helper, and offers it for an unusable saved file`() async {
    let unusable = NFS2015WineExperimentsState(
      preference: .standard, notice: "The saved Wine experiment choice could not be used.")
    let (sut, service) = model(saved: unusable)
    await sut.run()
    #expect(sut.canResetExperiments)
    sut.resetExperiments()
    await sut.run()
    #expect(
      service.performed.last == .configureExperiments(NFS2015WineExperimentsRequest(action: .reset))
    )
  }

  @Test
  func `discarding drops the unsaved choice, and a busy helper takes no choice`() async {
    let (sut, service) = model()
    #expect(sut.isBusy)
    sut.flushToggleBinding().wrappedValue = true
    sut.resetExperiments()
    #expect(!sut.hasPendingExperiments)
    await sut.run()
    #expect(service.performed == [.prepare])
    sut.tracePageBinding().wrappedValue = true
    sut.discardExperiments()
    #expect(sut.experiments == .standard && !sut.hasPendingExperiments)
  }
}
