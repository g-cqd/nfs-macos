import Foundation
import NFS2015Core
import SharedLauncher
import Testing

@testable import NFS2015Launcher

@MainActor
struct NFS2015DiagnosticsModelTests {
  typealias Service = NFS2015ModelTests.FakeService

  private static let logging = NFS2015DiagnosticsPreference(diagnosticLoggingNextLaunch: true)

  private func model(saved: NFS2015DiagnosticsState? = nil) -> (NFS2015Model, Service) {
    let service = Service(
      snapshot: NFS2015Snapshot(
        clientVersion: "13.796.0.6309", installedAt: "/Windows", hasOptionsFile: true,
        settings: NFS2015ModelTests.recorded, optionsDigest: NFS2015ModelTests.digest,
        diagnostics: saved))
    let sut = NFS2015Model(
      service: service,
      rosetta: RosettaSetup(service: NFS2015ModelTests.FakeRosetta(available: true)))
    return (sut, service)
  }

  @Test
  func `starts with the safe choices on and the log off, from a state file that has no entry`()
    async
  {
    let (sut, _) = model()
    await sut.run()
    #expect(sut.diagnostics == NFS2015DiagnosticsPreference.standard)
    #expect(sut.diagnostics.limitRetinaDesktop && sut.diagnostics.seedSafeResolution)
    #expect(!sut.diagnostics.diagnosticLoggingNextLaunch)
    #expect(!sut.hasPendingDiagnostics && !sut.canResetDiagnostics)
    #expect(sut.displayNote == nil && sut.diagnosticsNotice == nil)
  }

  @Test
  func `sends what the player chose, and nothing for a choice that equals the saved one`() async {
    let (sut, service) = model()
    await sut.run()
    sut.setDiagnosticLogging(true)
    #expect(sut.hasPendingDiagnostics)
    sut.setDiagnosticLogging(false)
    #expect(!sut.hasPendingDiagnostics)
    sut.saveDiagnostics()
    await sut.run()
    #expect(service.performed == [.prepare])
    sut.setLimitRetinaDesktop(false)
    sut.setSeedSafeResolution(false)
    sut.setDiagnosticLogging(true)
    sut.saveDiagnostics()
    await sut.run()
    #expect(
      service.performed.last
        == .configureDiagnostics(
          NFS2015DiagnosticsRequest(
            action: .save,
            preference: NFS2015DiagnosticsPreference(
              limitRetinaDesktop: false, seedSafeResolution: false,
              diagnosticLoggingNextLaunch: true))))
  }

  @Test
  func `adopts the saved choice and says when it applies`() async {
    let (sut, service) = model()
    await sut.run()
    sut.setDiagnosticLogging(true)
    service.snapshot.diagnostics = NFS2015DiagnosticsState(
      preference: Self.logging, outcome: .saved)
    sut.saveDiagnostics()
    await sut.run()
    #expect(sut.diagnostics == Self.logging && !sut.hasPendingDiagnostics)
    #expect(sut.diagnosticsOutcomeLine == "Saved. It applies the next time you press Play.")
    #expect(sut.canResetDiagnostics)
    sut.enableController()
    await sut.run()
    #expect(sut.diagnosticsOutcomeLine == nil && sut.savedDiagnostics == Self.logging)
  }

  @Test
  func `keeps the player's choice when a request is refused, and shows why`() async {
    let (sut, service) = model()
    await sut.run()
    sut.setSeedSafeResolution(false)
    service.snapshot.diagnostics = NFS2015DiagnosticsState(
      preference: .standard, outcome: .refused("Could not save: disk full"))
    sut.saveDiagnostics()
    await sut.run()
    #expect(sut.hasPendingDiagnostics && !sut.diagnostics.seedSafeResolution)
    #expect(sut.diagnosticsRefusal?.contains("disk full") == true)
  }

  @Test
  func `resets through the helper, and offers it for an unusable saved file`() async {
    let unusable = NFS2015DiagnosticsState(
      preference: .standard, notice: "The saved diagnostics choice could not be used.")
    let (sut, service) = model(saved: unusable)
    await sut.run()
    #expect(sut.diagnosticsNotice?.contains("could not be used") == true)
    #expect(sut.canResetDiagnostics)
    sut.resetDiagnostics()
    await sut.run()
    #expect(
      service.performed.last == .configureDiagnostics(NFS2015DiagnosticsRequest(action: .reset)))
  }

  @Test
  func `discarding drops the unsaved choice`() async {
    let (sut, _) = model()
    await sut.run()
    sut.setLimitRetinaDesktop(false)
    #expect(sut.hasPendingDiagnostics)
    sut.discardDiagnostics()
    #expect(sut.diagnostics == NFS2015DiagnosticsPreference.standard && !sut.hasPendingDiagnostics)
  }

  @Test
  func `will not take a choice while the helper is busy`() async {
    let (sut, service) = model()
    #expect(sut.isBusy)
    sut.setDiagnosticLogging(true)
    sut.setLimitRetinaDesktop(false)
    sut.resetDiagnostics()
    #expect(!sut.hasPendingDiagnostics)
    await sut.run()
    #expect(service.performed == [.prepare])
  }

  @Test
  func `shows what the display rule decided`() async {
    let (sut, _) = model(
      saved: NFS2015DiagnosticsState(
        displayNote: "RetinaMode is turned off: doubling would make it 7680x4320."))
    await sut.run()
    #expect(sut.displayNote?.contains("RetinaMode is turned off") == true)
    let (empty, _) = model(saved: NFS2015DiagnosticsState(displayNote: ""))
    await empty.run()
    #expect(empty.displayNote == nil)
  }

  // MARK: The crash report

  private let notice = NFS2015CrashNotice(
    path: "/Player/Logs/crash-report-20261003T040000Z.txt", headline: "1 fault in 1 game launch")

  @Test
  func `shows the report of the Play that just ended, with its path`() async {
    let (sut, service) = model()
    await sut.run()
    #expect(sut.crashNotice == nil)
    service.snapshot.crashReport = notice
    sut.play()
    await sut.run()
    #expect(sut.crashNotice == notice)
    #expect(notice.sentence.contains("/Player/Logs/crash-report-20261003T040000Z.txt"))
    #expect(notice.sentence.contains("1 fault in 1 game launch"))
  }

  @Test
  func `finds a report the helper wrote while the game was still running`() async {
    let (sut, service) = model()
    await sut.run()
    await sut.refreshCrashNotice(since: Date())
    #expect(sut.crashNotice == nil)
    service.crashReport = notice
    await sut.refreshCrashNotice(since: Date())
    #expect(sut.crashNotice == notice)
  }

  @Test
  func `keeps the notice after the session ends, and clears it when the next Play begins`() async {
    let (sut, service) = model()
    await sut.run()
    service.snapshot.crashReport = notice
    sut.play()
    await sut.run()
    sut.reload()
    service.snapshot.crashReport = nil
    await sut.run()
    #expect(sut.crashNotice == notice)
    sut.play()
    await sut.run()
    #expect(sut.crashNotice == nil)
  }
}
