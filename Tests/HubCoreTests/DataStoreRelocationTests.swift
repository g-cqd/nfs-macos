import Darwin
import Foundation
import Testing

@testable import HubCore

private struct Fixture {
  let tree: TempTree
  var capabilities = FakeCapabilities()
  var probe = QuietProbe()
  var faults = DataStoreRelocation.Faults()
  var safetyMargin: Int64 = 1024

  /// A data store at `Vol/GameHub` with a config, a prefix, files, a symlink and an empty folder.
  init() throws {
    tree = try TempTree()
    try tree.writeHubConfig(in: "Vol/GameHub")
    try tree.makeDirectory("Vol/GameHub/Prefix")
    try tree.write("Vol/GameHub/Prefix/system.reg", "registry")
    try tree.write("Vol/GameHub/Library/Steam/steam.exe", String(repeating: "s", count: 5000))
    try tree.write("Vol/GameHub/EA Games/Game/data.bin", String(repeating: "d", count: 3000))
    try tree.symlink("Vol/GameHub/Library/EA", to: "../EA Games")
    try tree.makeDirectory("Vol/GameHub/Apps")
    try tree.makeDirectory("Vol/Moved")
  }

  var current: String { tree.path("Vol/GameHub") }

  var relocation: DataStoreRelocation {
    DataStoreRelocation(
      home: tree.url, capabilities: capabilities, probe: probe, checkEnvironment: .quiet,
      safetyMargin: safetyMargin, processID: 4242, faults: faults)
  }

  func savedSettings() throws -> HubSettings { try HubSettings.load(home: tree.url) }
}

@Suite struct DataStoreRelocationPlanTests {
  @Test func anExistingStoreIsPointedAt() throws {
    let fixture = try Fixture()
    try fixture.tree.writeHubConfig(in: "Vol/Other")
    let plan = try fixture.relocation.plan(
      current: fixture.current, chosen: fixture.tree.path("Vol/Other"))
    #expect(plan == .pointAtExisting(root: fixture.tree.path("Vol/Other")))
  }

  @Test func theCurrentStoreIsTheSameLocation() throws {
    let fixture = try Fixture()
    let relocation = fixture.relocation
    #expect(
      try relocation.plan(current: fixture.current, chosen: fixture.current + "/")
        == .refused(.sameLocation))
    // The volume's folder would receive a store named like the current one: that is the current.
    #expect(
      try relocation.plan(current: fixture.current, chosen: fixture.tree.path("Vol"))
        == .refused(.sameLocation))
  }

  @Test func aStoreWithBrokenConfigCannotBePointedAt() throws {
    let fixture = try Fixture()
    try fixture.tree.write("Vol/Bad/Hub/hub.json", "{")
    let plan = try fixture.relocation.plan(
      current: fixture.current, chosen: fixture.tree.path("Vol/Bad"))
    guard case .refused(.targetUnusable(.configInvalid)) = plan else {
      Issue.record("expected a refusal, got \(plan)")
      return
    }
  }

  @Test func anotherFolderOnTheSameDriveIsARename() throws {
    let fixture = try Fixture()
    let plan = try fixture.relocation.plan(
      current: fixture.current, chosen: fixture.tree.path("Vol/Moved"))
    #expect(plan == .rename(from: fixture.current, to: fixture.tree.path("Vol/Moved/GameHub")))

    let named = try fixture.relocation.plan(
      current: fixture.current, chosen: fixture.tree.path("Vol/NewName"))
    #expect(named == .rename(from: fixture.current, to: fixture.tree.path("Vol/NewName")))
  }

  @Test func aFolderOnAnotherDriveIsACopyWithItsSize() throws {
    var fixture = try Fixture()
    fixture.capabilities.otherDevicePrefixes = [fixture.tree.path("Vol/Moved")]
    let plan = try fixture.relocation.plan(
      current: fixture.current, chosen: fixture.tree.path("Vol/Moved"))
    guard case .copy(let from, let to, let bytes, let entries, let free) = plan else {
      Issue.record("expected a copy, got \(plan)")
      return
    }
    #expect(from == fixture.current)
    #expect(to == fixture.tree.path("Vol/Moved/GameHub"))
    let configBytes = try Data(contentsOf: URL(fileURLWithPath: fixture.current + "/Hub/hub.json"))
    #expect(bytes == Int64(8 + 5000 + 3000 + configBytes.count), "regular files only, links not")
    #expect(entries > 8)
    #expect(free == 500 << 30)
  }

  @Test func aCopyNeedsTheSizeAndTheMarginFree() throws {
    var fixture = try Fixture()
    fixture.capabilities.otherDevicePrefixes = [fixture.tree.path("Vol/Moved")]
    fixture.capabilities.capacity = DataStoreCapacity(free: 9000, total: 1 << 40)
    fixture.safetyMargin = 5000
    let plan = try fixture.relocation.plan(
      current: fixture.current, chosen: fixture.tree.path("Vol/Moved"))
    guard case .refused(.insufficientSpace(_, let free, let margin)) = plan else {
      Issue.record("expected insufficient space, got \(plan)")
      return
    }
    #expect(free == 9000)
    #expect(margin == 5000)
    if case .refused(let reason) = plan { #expect(reason.message.contains("free")) }
  }

  @Test func refusesTargetsThatCannotHoldAStore() throws {
    var fixture = try Fixture()
    let moved = fixture.tree.path("Vol/Moved")

    fixture.capabilities.caseInsensitivePrefixes = [moved]
    #expect(
      try fixture.relocation.plan(current: fixture.current, chosen: moved)
        == .refused(.targetUnusable(.notCaseSensitive)))

    fixture.capabilities = FakeCapabilities(readOnlyPrefixes: [moved])
    #expect(
      try fixture.relocation.plan(current: fixture.current, chosen: moved)
        == .refused(.targetUnusable(.notWritable)))

    fixture.capabilities = FakeCapabilities(unmountedVolumes: ["/Volumes/Gone"])
    #expect(
      try fixture.relocation.plan(current: fixture.current, chosen: "/Volumes/Gone/GameHub")
        == .refused(.targetUnusable(.driveNotConnected(volume: "/Volumes/Gone"))))
  }

  @Test func refusesTargetsThatAreNotFreePlaces() throws {
    let fixture = try Fixture()
    let relocation = fixture.relocation
    try fixture.tree.makeDirectory("Vol/Moved/GameHub")
    #expect(
      try relocation.plan(current: fixture.current, chosen: fixture.tree.path("Vol/Moved"))
        == .refused(.targetExists(fixture.tree.path("Vol/Moved/GameHub"))))

    #expect(
      try relocation.plan(current: fixture.current, chosen: fixture.current + "/Library")
        == .refused(.insideCurrentStore))
    #expect(
      try relocation.plan(current: fixture.current, chosen: fixture.current + "/New")
        == .refused(.insideCurrentStore))

    try fixture.tree.write("Vol/file.txt", "x")
    #expect(
      try relocation.plan(current: fixture.current, chosen: fixture.tree.path("Vol/file.txt"))
        == .refused(.notAFolder(fixture.tree.path("Vol/file.txt"))))
    #expect(
      try relocation.plan(current: fixture.current, chosen: fixture.tree.path("Nowhere/Store"))
        == .refused(.parentMissing(fixture.tree.path("Nowhere"))))
  }

  @Test func refusesToMoveAStoreThatIsNotThere() throws {
    let fixture = try Fixture()
    let plan = try fixture.relocation.plan(
      current: fixture.tree.path("Vol/Missing"), chosen: fixture.tree.path("Vol/Moved"))
    #expect(plan == .refused(.currentUnusable(.missing)))
  }

  @Test func refusesARenameThatWouldBreakLinksIntoTheStore() throws {
    let fixture = try Fixture()
    try fixture.tree.symlink("Vol/Steam", to: "GameHub/Library/Steam")
    try fixture.tree.symlink("Vol/Unrelated", to: "/usr")
    let plan = try fixture.relocation.plan(
      current: fixture.current, chosen: fixture.tree.path("Vol/Moved"))
    #expect(plan == .refused(.compatibilityLinks(["Steam"])))
    if case .refused(let reason) = plan { #expect(reason.message.contains("Steam")) }
  }

  @Test func aSymlinkedStoreRootIsRefusedForRenameAndCopy() throws {
    var fixture = try Fixture()
    try fixture.tree.symlink("Vol/Link", to: "GameHub")
    let link = fixture.tree.path("Vol/Link")
    let moved = fixture.tree.path("Vol/Moved")
    #expect(
      try fixture.relocation.plan(current: link, chosen: moved)
        == .refused(.currentUnusable(.notADirectory)))

    fixture.capabilities.otherDevicePrefixes = [moved]
    #expect(
      try fixture.relocation.plan(current: link, chosen: moved)
        == .refused(.currentUnusable(.notADirectory)))
  }

  @Test func aFolderLinkedIntoTheStoreIsInsideTheStore() throws {
    let fixture = try Fixture()
    try fixture.tree.symlink("Vol/Moved/Shortcut", to: fixture.tree.path("Vol/GameHub/Library"))
    #expect(
      try fixture.relocation.plan(
        current: fixture.current, chosen: fixture.tree.path("Vol/Moved/Shortcut"))
        == .refused(.insideCurrentStore))
    #expect(
      try fixture.relocation.plan(
        current: fixture.current, chosen: fixture.tree.path("Vol/Moved/Shortcut/New"))
        == .refused(.insideCurrentStore))
  }

  @Test func aCopyDoesNotBreakLinksBecauseTheSourceStays() throws {
    var fixture = try Fixture()
    try fixture.tree.symlink("Vol/Steam", to: "GameHub/Library/Steam")
    fixture.capabilities.otherDevicePrefixes = [fixture.tree.path("Vol/Moved")]
    let plan = try fixture.relocation.plan(
      current: fixture.current, chosen: fixture.tree.path("Vol/Moved"))
    guard case .copy = plan else {
      Issue.record("expected a copy, got \(plan)")
      return
    }
  }
}

@Suite struct DataStoreRelocationRunTests {
  @Test func pointingAtAnExistingStoreOnlyChangesTheSettings() throws {
    let fixture = try Fixture()
    try fixture.tree.writeHubConfig(in: "Vol/Other")
    let outcome = try fixture.relocation.perform(
      .pointAtExisting(root: fixture.tree.path("Vol/Other")))
    guard case .done(let result) = outcome else {
      Issue.record("expected done")
      return
    }
    #expect(result.settings.dataStoreRoot == fixture.tree.path("Vol/Other"))
    #expect(try fixture.savedSettings() == result.settings)
    #expect(fixture.tree.exists("Vol/GameHub/Hub/hub.json"), "nothing moved")
  }

  @Test func aRefusedPlanIsNotPerformed() throws {
    let fixture = try Fixture()
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(.refused(.sameLocation))
    }
  }

  @Test func renamesTheWholeStoreInOneStepKeepingItsIdentity() throws {
    let fixture = try Fixture()
    let before = fixture.tree.inode("Vol/GameHub")
    let target = fixture.tree.path("Vol/Moved/GameHub")
    let outcome = try fixture.relocation.perform(
      .rename(from: fixture.current, to: target))

    guard case .done(let result) = outcome else {
      Issue.record("expected done")
      return
    }
    #expect(!fixture.tree.exists("Vol/GameHub"))
    #expect(fixture.tree.inode("Vol/Moved/GameHub") == before, "the same directory, not a copy")
    #expect(fixture.tree.contents("Vol/Moved/GameHub/Prefix/system.reg") == "registry")
    #expect(result.settings.dataStoreRoot == target)
    #expect(try fixture.savedSettings().dataStoreRoot == target)
    #expect(result.summary.contains("Windows"))
  }

  @Test func aRenameIsBlockedWhileAFileInTheStoreIsOpen() throws {
    var fixture = try Fixture()
    fixture.probe = QuietProbe(openFiles: [fixture.current + "/Prefix/user.reg"])
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(
        .rename(from: fixture.current, to: fixture.tree.path("Vol/Moved/GameHub")))
    }
    #expect(fixture.tree.exists("Vol/GameHub/Hub/hub.json"), "nothing moved")
    #expect(!fixture.tree.exists("Vol/Moved/GameHub"))
    #expect(!fixture.tree.exists("Library"), "the settings were not written")
  }

  @Test func aSymlinkedStoreIsNotRenamedOrCopied() throws {
    var fixture = try Fixture()
    try fixture.tree.symlink("Vol/Link", to: "GameHub")
    let link = fixture.tree.path("Vol/Link")
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(.rename(from: link, to: fixture.tree.path("Vol/Moved/Link")))
    }
    fixture.capabilities.otherDevicePrefixes = [fixture.tree.path("Vol/Moved")]
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(
        .copy(
          from: link, to: fixture.tree.path("Vol/Moved/Link"), requiredBytes: 1, entries: 1,
          freeBytes: 1 << 40),
        confirmedCopy: true)
    }
    #expect(fixture.tree.exists("Vol/Link"))
    #expect(fixture.tree.names("Vol/Moved") == [])
  }

  @Test func aBrokenHubJSONStopsTheIdleCheck() throws {
    let fixture = try Fixture()
    try fixture.tree.write("Vol/GameHub/Hub/hub.json", "{ not json")
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(
        .rename(from: fixture.current, to: fixture.tree.path("Vol/Moved/GameHub")))
    }
    #expect(fixture.tree.exists("Vol/GameHub/Hub/hub.json"), "nothing moved")
  }

  @Test func aRenameKeepsASettingChangedByAnotherWriter() throws {
    let fixture = try Fixture()
    // The runtime location saved on disk is not the one any earlier snapshot held.
    try HubSettings(dataStoreRoot: fixture.current, runtimeApp: "/x/Newer.app")
      .save(home: fixture.tree.url)
    let outcome = try fixture.relocation.perform(
      .rename(from: fixture.current, to: fixture.tree.path("Vol/Moved/GameHub")))
    guard case .done(let result) = outcome else {
      Issue.record("expected done")
      return
    }
    #expect(result.settings.runtimeApp == "/x/Newer.app")
    #expect(try fixture.savedSettings().runtimeApp == "/x/Newer.app")
  }

  @Test func aRenameNeverReplacesAnExistingFolder() throws {
    let fixture = try Fixture()
    try fixture.tree.makeDirectory("Vol/Moved/GameHub")
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(
        .rename(from: fixture.current, to: fixture.tree.path("Vol/Moved/GameHub")))
    }
    #expect(fixture.tree.exists("Vol/GameHub/Hub/hub.json"))
  }

  @Test func aRenameIsMovedBackWhenTheSettingsCannotBeSaved() throws {
    let fixture = try Fixture()
    // A directory where the settings file belongs makes the save fail after the rename.
    try fixture.tree.makeDirectory("Library/Application Support/GameHub/settings.json")
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(
        .rename(from: fixture.current, to: fixture.tree.path("Vol/Moved/GameHub")))
    }
    #expect(fixture.tree.exists("Vol/GameHub/Hub/hub.json"), "moved back")
    #expect(!fixture.tree.exists("Vol/Moved/GameHub"))
  }

  // MARK: Copy

  private func copyFixture(sealedFolder: Bool = false) throws -> (Fixture, DataStoreRelocationPlan)
  {
    var fixture = try Fixture()
    if sealedFolder {
      try fixture.tree.write("Vol/GameHub/Sealed/file.txt", "sealed")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: fixture.tree.path("Vol/GameHub/Sealed"))
    }
    fixture.capabilities.otherDevicePrefixes = [fixture.tree.path("Vol/Moved")]
    let plan = try fixture.relocation.plan(
      current: fixture.current, chosen: fixture.tree.path("Vol/Moved"))
    return (fixture, plan)
  }

  @Test func aCopyNeedsConfirmation() throws {
    let (fixture, plan) = try copyFixture()
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(plan)
    }
    #expect(!fixture.tree.exists("Vol/Moved/GameHub"))
    #expect(!fixture.tree.exists("Vol/Moved/GameHub.staging-4242"))
  }

  @Test func copiesTheStoreAndKeepsTheSource() throws {
    let (fixture, plan) = try copyFixture(sealedFolder: true)
    defer {
      for folder in ["Vol/GameHub/Sealed", "Vol/Moved/GameHub/Sealed"] {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: fixture.tree.path(folder))
      }
    }

    final class Latest: @unchecked Sendable {
      // Written only by the copying call, read after it returns.
      var value: DataStoreCopyProgress?
    }
    let latest = Latest()
    let outcome = try fixture.relocation.perform(
      plan, confirmedCopy: true,
      progress: { latest.value = $0 }, isCancelled: { false })

    guard case .done(let result) = outcome else {
      Issue.record("expected done")
      return
    }
    let copy = "Vol/Moved/GameHub"
    #expect(fixture.tree.contents("\(copy)/Library/Steam/steam.exe")?.count == 5000)
    #expect(fixture.tree.contents("\(copy)/EA Games/Game/data.bin")?.count == 3000)
    #expect(fixture.tree.contents("\(copy)/Sealed/file.txt") == "sealed")
    let link = try FileManager.default.destinationOfSymbolicLink(
      atPath: fixture.tree.path("\(copy)/Library/EA"))
    #expect(link == "../EA Games", "a symlink is copied as a symlink")
    var info = stat()
    #expect(lstat(fixture.tree.path("\(copy)/Sealed"), &info) == 0)
    #expect(info.st_mode & 0o777 == 0o555, "directory permissions are applied last")

    // The source is intact and nothing was left behind.
    #expect(fixture.tree.contents("Vol/GameHub/Library/Steam/steam.exe")?.count == 5000)
    #expect(fixture.tree.exists("Vol/GameHub/Hub/hub.json"))
    #expect(!fixture.tree.exists("Vol/Moved/GameHub.staging-4242"))
    #expect(fixture.tree.names("Vol/Moved") == ["GameHub"])

    #expect(result.settings.dataStoreRoot == fixture.tree.path(copy))
    #expect(try fixture.savedSettings().dataStoreRoot == fixture.tree.path(copy))
    #expect(result.summary.contains("kept"))
    #expect(latest.value?.fraction == 1)
    #expect(latest.value?.entriesDone == latest.value?.entriesTotal)
  }

  @Test func aFailedCopyRemovesOnlyItsStagingFolder() throws {
    let (base, plan) = try copyFixture()
    var fixture = base
    fixture.faults = DataStoreRelocation.Faults(failCopyAfterEntries: 3)
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(plan, confirmedCopy: true)
    }
    #expect(fixture.tree.names("Vol/Moved") == [], "the staging folder is gone, no target exists")
    #expect(fixture.tree.contents("Vol/GameHub/Prefix/system.reg") == "registry")
    #expect(!fixture.tree.exists("Library"), "the settings were not written")
  }

  @Test func cancellingACopyRemovesTheStagingFolderAndChangesNothing() throws {
    let (fixture, plan) = try copyFixture()
    let outcome = try fixture.relocation.perform(plan, confirmedCopy: true, isCancelled: { true })
    #expect(outcome == .cancelled)
    #expect(fixture.tree.names("Vol/Moved") == [])
    #expect(fixture.tree.exists("Vol/GameHub/Hub/hub.json"))
    #expect(!fixture.tree.exists("Library"))
  }

  @Test func aCopyIsBlockedWhileTheStoreIsInUse() throws {
    let (base, plan) = try copyFixture()
    var fixture = base
    fixture.probe = QuietProbe(openFiles: [fixture.current + "/Prefix/system.reg"])
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(plan, confirmedCopy: true)
    }
    #expect(fixture.tree.names("Vol/Moved") == [])
  }

  @Test func aCopyRefusesWhenSpaceRanOutSincePlanning() throws {
    let (base, plan) = try copyFixture()
    var fixture = base
    fixture.capabilities.capacity = DataStoreCapacity(free: 100, total: 1 << 40)
    #expect(throws: HubError.self) {
      try fixture.relocation.perform(plan, confirmedCopy: true)
    }
    #expect(fixture.tree.names("Vol/Moved") == [])
  }
}
