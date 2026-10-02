import FarCry2Core
import Foundation
import LauncherCore
import SharedLauncher
import Testing

@testable import FarCry2Launcher

@MainActor
struct FarCry2ModelTests {
  @Test func `preparation respects missing Rosetta and never starts a helper`() async {
    let service = SessionStub()
    let sut = makeModel(service: service, available: false)
    await sut.run()
    #expect(sut.needsRosetta)
    #expect(service.operations.isEmpty)
  }

  @Test func `without game data the starter asks for an import and starts no helper`() async {
    let service = SessionStub()
    service.hasData = false
    let sut = makeModel(service: service)
    await sut.run()
    #expect(sut.needsGameData)
    #expect(!sut.canPlay)
    #expect(service.operations.isEmpty)
  }

  @Test func `play carries the edited settings`() async throws {
    let service = SessionStub()
    let sut = makeModel(service: service)
    await sut.run()
    sut.settings.values["antialiasing"] = "2"
    sut.play()
    await sut.run()
    let request = try #require(service.operations.last?.launchRequest)
    #expect(request.settings.value("antialiasing") == "2")
    #expect(sut.phase == .ready)
  }

  @Test func `reload requires an explicit discard of pending edits`() async {
    let service = SessionStub()
    let sut = makeModel(service: service)
    await sut.run()
    sut.settings.values["vsync"] = "1"
    let request = sut.request
    sut.reload()
    #expect(sut.discardConfirmation)
    #expect(sut.request == request)
    sut.confirmDiscard()
    #expect(sut.request == request + 1)
  }

  @Test func `maximum quality uses physical display pixels and keeps unrelated options`() async {
    let sut = makeModel(service: SessionStub())
    await sut.run()
    sut.settings.values["showFPS"] = "1"
    sut.maximumQuality()
    #expect(sut.settings.value("resolution") == "3840x2160")
    #expect(sut.settings.value("antialiasing") == "4")
    #expect(sut.settings.value("showFPS") == "1")
  }

  @Test func `invalid settings fail before helper execution`() async {
    let service = SessionStub()
    let sut = makeModel(service: service)
    await sut.run()
    sut.settings.values["antialiasing"] = "99"
    let count = service.operations.count
    sut.play()
    await sut.run()
    #expect(service.operations.count == count)
    #expect(sut.errorMessage != nil)
  }

  @Test func `a snapshot without a profile explains that the game must run once`() async {
    let service = SessionStub()
    service.snapshot = FarCry2Snapshot(
      settings: .init(), profile: .missing, installation: nil, backups: [])
    let sut = makeModel(service: service)
    await sut.run()
    #expect(sut.profileNotice.contains("Start it once"))
  }

  @Test func `the recognised build is shown as unverified when it is not on the list`() async {
    let service = SessionStub()
    service.snapshot = FarCry2Snapshot(
      settings: .init(), profile: .ready,
      installation: InstalledGame(
        executableSHA256: String(repeating: "a", count: 64), build: nil, fileVersion: "1.0.3.0",
        versionStrings: [:], markers: ["gog"], fileCount: 3, totalBytes: 9), backups: [])
    let sut = makeModel(service: service)
    await sut.run()
    #expect(sut.installationSummary == "Version 1.0.3.0 · build not on the verified list · gog")
  }

  @Test
  func `backup operations carry the selected backup and need a confirmation to discard edits`()
    async
  {
    let service = SessionStub()
    let backup = FarCry2Backup(
      id: UUID().uuidString, created: Date(), label: "Manual backup", files: 1, bytes: 2)
    service.snapshot = FarCry2Snapshot(
      settings: .init(), profile: .ready, installation: nil, backups: [backup])
    let sut = makeModel(service: service)
    await sut.run()
    #expect(sut.backupSelection == backup.id && sut.canRestore)
    sut.restoreBackup()
    await sut.run()
    guard case .backups(let request) = service.operations.last else {
      Issue.record("Expected a backup operation")
      return
    }
    #expect(request.action == .restore && request.id == backup.id)
  }

  @Test func `kept-aside folders are reported to the player`() async {
    let service = SessionStub()
    service.snapshot = FarCry2Snapshot(
      settings: .init(), profile: .ready, installation: nil, backups: [], keptAside: 2)
    let sut = makeModel(service: service)
    await sut.run()
    #expect(sut.keptAside == 2)
  }

  @Test func `the helper request for importing carries the chosen folder`() async throws {
    let service = SessionStub()
    service.hasData = false
    let sut = makeModel(service: service)
    await sut.run()
    let folder = URL(fileURLWithPath: "/tmp/Far Cry 2")
    sut.finishGameImport(try await service.perform(.importGame(folder)))
    guard case .importGame(let url) = service.operations.last else {
      Issue.record("Expected an import operation")
      return
    }
    #expect(url == folder)
    #expect(sut.hasGameData)
  }

  private func makeModel(service: SessionStub, available: Bool = true) -> FarCry2Model {
    FarCry2Model(
      service: service, rosetta: RosettaSetup(service: RosettaStub(available: available)),
      display: { ResolutionPreset(width: 3840, height: 2160) })
  }
}

@MainActor
private final class SessionStub: FarCry2Serving {
  var operations: [FarCry2Operation] = []
  var hasData = true
  var snapshot = FarCry2Snapshot(settings: .init(), profile: .ready, installation: nil, backups: [])
  func hasGameData() async throws -> Bool { hasData }
  func perform(_ operation: FarCry2Operation) async throws -> FarCry2Snapshot {
    operations.append(operation)
    return snapshot
  }
  func readSetup(_ url: URL) async throws -> FarCry2Settings { .init() }
  func writeSetup(_ settings: FarCry2Settings, to url: URL) async throws {}
  func logLocation() async -> URL? { nil }
}

@MainActor
private struct RosettaStub: RosettaProviding {
  let available: Bool
  func isAvailable() async throws -> Bool { available }
  func requestInstallation() async throws {}
}
