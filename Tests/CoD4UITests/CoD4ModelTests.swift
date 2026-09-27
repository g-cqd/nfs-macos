import CoD4Core
import Foundation
import LauncherCore
import SharedLauncher
import Testing

@testable import CoD4Launcher

@MainActor
struct CoD4ModelTests {
  @Test func `preparation respects missing Rosetta and never starts a helper`() async {
    let service = SessionStub()
    let sut = makeModel(service: service, available: false)
    await sut.run()
    #expect(sut.needsRosetta)
    #expect(service.operations.isEmpty)
  }

  @Test func `play uses the chosen mode profile and edited settings`() async throws {
    let service = SessionStub()
    let sut = makeModel(service: service)
    await sut.run()
    sut.settings.values["snd_volume"] = "0.4"
    sut.play()
    await sut.run()
    let request = try #require(service.operations.last?.launchRequest)
    #expect(request.profile == "Gigi")
    #expect(request.mode == .singlePlayer)
    #expect(request.settings.value("snd_volume") == "0.4")
  }

  @Test func `reload and profile selection require explicit discard of pending edits`() async {
    let service = SessionStub()
    let sut = makeModel(service: service)
    await sut.run()
    sut.settings.values["sensitivity"] = "2"
    let request = sut.request
    sut.selectProfile("Other")
    #expect(sut.discardConfirmation)
    #expect(sut.request == request)
    #expect(sut.selectedProfile == "Gigi")
    sut.confirmDiscard()
    await sut.run()
    #expect(service.operations.last?.profileSelection == "Other")
  }

  @Test func `maximum quality uses physical display pixels and preserves audio`() async {
    let sut = makeModel(service: SessionStub())
    await sut.run()
    sut.settings.values["snd_volume"] = "0.3"
    sut.maximumQuality()
    #expect(sut.settings.value("r_mode") == "3840x2160")
    #expect(sut.settings.value("snd_volume") == "0.3")
  }

  @Test func `invalid settings fail before helper execution`() async {
    let service = SessionStub()
    let sut = makeModel(service: service)
    await sut.run()
    sut.settings.values["sensitivity"] = "quit"
    let count = service.operations.count
    sut.play()
    await sut.run()
    #expect(service.operations.count == count)
    #expect(sut.errorMessage != nil)
  }

  @Test func `archived profiles are restorable but absent from play choices`() async {
    let service = SessionStub()
    service.snapshot = CoD4Snapshot(
      settings: .init(),
      profiles: [
        .init(name: "Gigi", hasCampaignSave: true, backupNames: []),
        .init(name: "Archived", hasCampaignSave: true, backupNames: ["backup"], isInstalled: false),
      ], selectedProfile: "Gigi")
    let sut = makeModel(service: service)
    await sut.run()
    #expect(sut.playProfiles.map(\.name) == ["Gigi"])
    sut.profileSelection = "Archived"
    sut.backupSelection = "backup"
    #expect(sut.canRestore)
  }

  @Test func `profile backup retains multiplayer mode in the helper request`() async {
    let service = SessionStub()
    let sut = makeModel(service: service)
    await sut.run()
    sut.selectMode(.multiplayer)
    await sut.run()
    sut.backupProfile()
    await sut.run()
    #expect(service.operations.last?.requestedMode == .multiplayer)
  }

  private func makeModel(service: SessionStub, available: Bool = true) -> CoD4Model {
    CoD4Model(
      service: service, rosetta: RosettaSetup(service: RosettaStub(available: available)),
      display: { ResolutionPreset(width: 3840, height: 2160) })
  }
}

@MainActor
private final class SessionStub: CoD4Serving {
  var operations: [CoD4Operation] = []
  var snapshot = CoD4Snapshot(
    settings: .init(), profiles: [.init(name: "Gigi", hasCampaignSave: true, backupNames: [])],
    selectedProfile: "Gigi")
  func hasGameData() async throws -> Bool { true }
  func perform(_ operation: CoD4Operation) async throws -> CoD4Snapshot {
    operations.append(operation)
    return snapshot
  }
  func readSetup(_ url: URL) async throws -> CoD4Settings { .init() }
  func writeSetup(_ settings: CoD4Settings, to url: URL) async throws {}
  func logLocation() async -> URL? { nil }
}

@MainActor
private struct RosettaStub: RosettaProviding {
  let available: Bool
  func isAvailable() async throws -> Bool { available }
  func requestInstallation() async throws {}
}
