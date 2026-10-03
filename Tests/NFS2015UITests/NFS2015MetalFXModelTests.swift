import Foundation
import NFS2015Core
import SharedLauncher
import Testing

@testable import NFS2015Launcher

@MainActor
struct NFS2015MetalFXModelTests {
  typealias Service = NFS2015ModelTests.FakeService

  private static let on = NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x150)

  private func model(
    options: Bool = true, saved: NFS2015MetalFXState? = nil,
    display: (width: Int, height: Int)? = (2560, 1600)
  ) -> (NFS2015Model, Service) {
    let service = Service(
      snapshot: NFS2015Snapshot(
        clientVersion: "13.796.0.6309", installedAt: "/Windows", hasOptionsFile: options,
        settings: options ? NFS2015ModelTests.recorded : NFS2015Settings(),
        optionsDigest: options ? NFS2015ModelTests.digest : nil, metalFX: saved))
    let sut = NFS2015Model(
      service: service,
      rosetta: RosettaSetup(service: NFS2015ModelTests.FakeRosetta(available: true)),
      displayPixels: { display })
    return (sut, service)
  }

  @Test
  func `starts off with nothing pending, from a state file that has no MetalFX entry`() async {
    let (sut, _) = model()
    await sut.run()
    #expect(sut.metalFX == .off && sut.savedMetalFX == .off)
    #expect(!sut.hasPendingMetalFX && !sut.canResetMetalFX)
    #expect(sut.metalFXNotice == nil && sut.metalFXOutcomeLine == nil)
  }

  @Test
  func `can be changed before the game has written its options file`() async {
    let (sut, service) = model(options: false)
    await sut.run()
    #expect(!sut.canEditSettings && sut.canEditMetalFX)
    sut.setMetalFXEnabled(true)
    sut.saveMetalFX()
    await sut.run()
    #expect(
      service.performed.last
        == .configureMetalFX(
          NFS2015MetalFXRequest(
            action: .save,
            preference: NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x150))))
  }

  @Test
  func `sends what the player chose, and nothing for a choice that equals the saved one`() async {
    let (sut, service) = model()
    await sut.run()
    sut.setMetalFXFactor(.x200)
    #expect(sut.hasPendingMetalFX)
    sut.setMetalFXFactor(.default)
    #expect(!sut.hasPendingMetalFX)
    sut.saveMetalFX()
    await sut.run()
    #expect(service.performed == [.prepare])
    sut.setMetalFXEnabled(true)
    sut.setMetalFXFactor(.x175)
    sut.saveMetalFX()
    await sut.run()
    #expect(
      service.performed.last
        == .configureMetalFX(
          NFS2015MetalFXRequest(
            action: .save,
            preference: NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x175))))
  }

  @Test
  func `adopts the saved choice and says when it applies`() async {
    let (sut, service) = model()
    await sut.run()
    sut.setMetalFXEnabled(true)
    service.snapshot.metalFX = NFS2015MetalFXState(preference: Self.on, outcome: .saved)
    sut.saveMetalFX()
    await sut.run()
    #expect(sut.savedMetalFX == Self.on && sut.metalFX == Self.on)
    #expect(!sut.hasPendingMetalFX)
    #expect(sut.metalFXOutcomeLine == "Saved. It applies the next time the game starts.")
    #expect(sut.canResetMetalFX)
    sut.enableController()
    await sut.run()
    #expect(sut.metalFXOutcomeLine == nil && sut.savedMetalFX == Self.on)
  }

  @Test
  func `keeps the player's choice when a request is refused, and shows why`() async {
    let (sut, service) = model()
    await sut.run()
    sut.setMetalFXEnabled(true)
    service.snapshot.metalFX = NFS2015MetalFXState(
      preference: .off, outcome: .refused("Could not save the MetalFX choice: disk full"))
    sut.saveMetalFX()
    await sut.run()
    #expect(sut.hasPendingMetalFX && sut.metalFX.spatialUpscaling)
    #expect(sut.metalFXRefusal?.contains("disk full") == true)
  }

  @Test
  func `resets through the helper, and offers it for an unusable saved file`() async {
    let unusable = NFS2015MetalFXState(
      preference: .off, notice: "The saved MetalFX choice could not be used, so MetalFX is off.")
    let (sut, service) = model(saved: unusable)
    await sut.run()
    #expect(sut.metalFXNotice?.contains("MetalFX is off") == true)
    #expect(sut.canResetMetalFX)
    sut.resetMetalFX()
    await sut.run()
    #expect(service.performed.last == .configureMetalFX(NFS2015MetalFXRequest(action: .reset)))
  }

  @Test
  func `discarding drops the unsaved choice`() async {
    let (sut, _) = model()
    await sut.run()
    sut.setMetalFXEnabled(true)
    #expect(sut.hasPendingMetalFX)
    sut.discardMetalFX()
    #expect(sut.metalFX == .off && !sut.hasPendingMetalFX)
  }

  @Test
  func `will not take a choice while the helper is busy`() async {
    let (sut, service) = model()
    #expect(sut.isBusy)
    sut.setMetalFXEnabled(true)
    sut.setMetalFXFactor(.x200)
    sut.resetMetalFX()
    #expect(!sut.hasPendingMetalFX)
    await sut.run()
    #expect(service.performed == [.prepare])
  }

  @Test
  func `shows the arithmetic at the game's resolution against this display`() async {
    let (sut, _) = model()
    await sut.run()
    sut.setMetalFXFactor(.x150)
    #expect(sut.metalFXSummary.hasPrefix("The game draws 2560x1600 and DXMT presents 3840x2400."))
    #expect(sut.metalFXSummary.contains("larger than this display's 2560x1600"))
    let (other, _) = model(options: false)
    await other.run()
    #expect(other.metalFXSummary.contains("not known until it has written its options file"))
  }
}
