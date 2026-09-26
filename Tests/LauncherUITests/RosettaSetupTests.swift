import Foundation
import Testing

@testable import NFSMWLauncher

@MainActor
struct RosettaSetupTests {
  @Test func `refresh detects an external installation without opening an installer`() async {
    let service = RosettaServiceStub()
    let sut = RosettaSetup(service: service)
    await sut.refresh()
    #expect(sut.state == .missing)
    service.available = true
    await sut.refresh()
    #expect(sut.isAvailable)
    #expect(service.requests == 0)
  }

  @Test(arguments: [true, false])
  func `installation rechecks availability instead of assuming success`(installed: Bool) async {
    let service = RosettaServiceStub()
    service.installationSucceeds = installed
    let sut = RosettaSetup(service: service)
    await sut.install()
    #expect(sut.isAvailable == installed)
    #expect(service.requests == 1)
    if !installed { #expect(sut.state == .missing) }
  }

  @Test func `installation failure stays retryable and reports the error`() async {
    let service = RosettaServiceStub()
    service.failure = CocoaError(.userCancelled)
    let sut = RosettaSetup(service: service)
    await sut.install()
    #expect(!sut.isAvailable)
    #expect(!sut.isBusy)
    #expect(sut.issue != nil)
    service.failure = nil
    service.installationSucceeds = true
    await sut.install()
    #expect(sut.isAvailable)
    #expect(service.requests == 2)
  }

  @Test func `launcher gates setup before a missing Rosetta can start Wine`() async {
    let service = RosettaServiceStub()
    let sut = LauncherModel(rosetta: RosettaSetup(service: service))
    await sut.launch()
    #expect(sut.phase == .needsRosetta)
    #expect(!sut.canLaunch)
    let previous = sut.request
    sut.refreshRosetta()
    #expect(sut.request == previous + 1)
  }

  @Test func `cancelled refresh restores the previous state`() async {
    let sut = RosettaSetup(service: RosettaServiceStub())
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await sut.refresh() }
      group.cancelAll()
      await group.waitForAll()
    }
    #expect(sut.state == .unchecked)
    #expect(!sut.isBusy)
  }
}

@MainActor
private final class RosettaServiceStub: RosettaProviding {
  var available = false
  var installationSucceeds = false
  var failure: CocoaError?
  var requests = 0
  func isAvailable() async throws -> Bool { available }
  func requestInstallation() async throws {
    requests += 1
    if let failure { throw failure }
    available = installationSucceeds
  }
}
