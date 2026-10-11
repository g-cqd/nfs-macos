import Darwin
import Foundation
import Testing

@testable import HubCore

@Suite struct HubSettingsTests {
  @Test func aMissingFileGivesTheDefaults() throws {
    let tree = try TempTree()
    let settings = try HubSettings.load(home: tree.url)
    #expect(settings == HubSettings.defaults(home: tree.url))
    #expect(settings.dataStoreRoot == "/Volumes/ExT2/GameHub")
    #expect(settings.runtimeApp == tree.path("Applications/GameHub Runtime hub-0.app"))
    #expect(!tree.exists("Library"), "loading must not create the file")
  }

  @Test func savesAndLoadsAtomically() throws {
    let tree = try TempTree()
    let settings = HubSettings(
      dataStoreRoot: "/Volumes/Other/Store", runtimeApp: "/Applications/Runtime.app")
    try settings.save(home: tree.url)
    #expect(try HubSettings.load(home: tree.url) == settings)

    let changed = try settings.movingDataStore(to: "/Volumes/Third/Store")
    try changed.save(home: tree.url)
    #expect(try HubSettings.load(home: tree.url) == changed)
    let folder = "Library/Application Support/GameHub"
    #expect(tree.names(folder) == ["settings.json"], "no temporary file is left behind")
  }

  @Test func rejectsUnknownKeysAndBadValues() throws {
    let tree = try TempTree()
    let file = "Library/Application Support/GameHub/settings.json"
    let valid = #""schemaVersion": 1, "dataStoreRoot": "/a/b", "runtimeApp": "/x/R.app""#

    try tree.write(file, "{\(valid), \"extra\": 1}")
    #expect(throws: HubError.self) { try HubSettings.load(home: tree.url) }

    for bad in [
      #"{"schemaVersion": 2, "dataStoreRoot": "/a/b", "runtimeApp": "/x/R.app"}"#,
      #"{"schemaVersion": 1, "dataStoreRoot": "relative", "runtimeApp": "/x/R.app"}"#,
      #"{"schemaVersion": 1, "dataStoreRoot": "/a/../b", "runtimeApp": "/x/R.app"}"#,
      #"{"schemaVersion": 1, "dataStoreRoot": "/a/b/", "runtimeApp": "/x/R.app"}"#,
      #"{"schemaVersion": 1, "dataStoreRoot": "/a/b", "runtimeApp": "/x/Runtime"}"#,
      #"{"schemaVersion": 1, "dataStoreRoot": "/a/b"}"#,
      "not json",
    ] {
      try tree.write(file, bad)
      #expect(throws: HubError.self, "\(bad)") { try HubSettings.load(home: tree.url) }
    }

    try tree.write(file, "{\(valid)}")
    #expect(try HubSettings.load(home: tree.url).dataStoreRoot == "/a/b")
  }

  @Test func refusesASymlinkedSettingsFile() throws {
    let tree = try TempTree()
    try tree.write(
      "elsewhere.json", #"{"schemaVersion":1,"dataStoreRoot":"/a","runtimeApp":"/b.app"}"#)
    try tree.symlink(
      "Library/Application Support/GameHub/settings.json", to: tree.path("elsewhere.json"))
    #expect(throws: HubError.self) { try HubSettings.load(home: tree.url) }
    #expect(throws: HubError.self) {
      try HubSettings.defaults(home: tree.url).save(home: tree.url)
    }
    #expect(
      tree.contents("elsewhere.json")?.contains("\"/a\"") == true,
      "the file behind the link is untouched")
  }

  @Test func refusesToSaveInvalidSettings() throws {
    let tree = try TempTree()
    let bad = HubSettings(dataStoreRoot: "not/absolute", runtimeApp: "/x/R.app")
    #expect(throws: HubError.self) { try bad.save(home: tree.url) }
    #expect(!tree.exists("Library"))
  }

  @Test func updatingChangesOnlyItsFieldOfTheLatestSavedSettings() throws {
    let tree = try TempTree()
    let sha = try makeFakeRuntimeApp(in: tree, at: "R.app")
    let stale = HubSettings(dataStoreRoot: "/Volumes/A/Store", runtimeApp: "/x/Old.app")
    try stale.save(home: tree.url)
    // Another writer changed the runtime after `stale` was read.
    try HubSettings(dataStoreRoot: "/Volumes/A/Store", runtimeApp: "/x/Newer.app")
      .save(home: tree.url)

    let moved = try HubSettings.updateDataStore(home: tree.url, to: "/Volumes/B/Store")
    #expect(moved.settings.runtimeApp == "/x/Newer.app", "the stale runtime is not written back")
    #expect(moved.settings.dataStoreRoot == "/Volumes/B/Store")

    // And the other way round: choosing a runtime keeps the data store saved meanwhile.
    try HubSettings(dataStoreRoot: "/Volumes/C/Store", runtimeApp: "/x/Newer.app")
      .save(home: tree.url)
    let chosen = try HubSettings.updateRuntimeApp(
      home: tree.url, to: tree.path("R.app"), expectedSHA256: sha)
    #expect(chosen.settings.dataStoreRoot == "/Volumes/C/Store")
    #expect(chosen.settings.runtimeApp == tree.path("R.app"))
    #expect(try HubSettings.load(home: tree.url) == chosen.settings)
  }

  @Test func updatingFromNothingStartsFromTheDefaults() throws {
    let tree = try TempTree()
    let saved = try HubSettings.updateDataStore(home: tree.url, to: "/Volumes/B/S")
    #expect(saved.settings.runtimeApp == HubSettings.defaults(home: tree.url).runtimeApp)
    #expect(saved.warning == nil)
  }

  @Test func updatingReplacesAnUnreadableFileButNotALink() throws {
    let tree = try TempTree()
    let file = "Library/Application Support/GameHub/settings.json"
    try tree.write(file, "{ broken")
    let saved = try HubSettings.updateDataStore(home: tree.url, to: "/Volumes/B/S")
    #expect(try HubSettings.load(home: tree.url) == saved.settings)

    try FileManager.default.removeItem(atPath: tree.path(file))
    try tree.write("elsewhere.json", "{}")
    try tree.symlink(file, to: tree.path("elsewhere.json"))
    #expect(throws: HubError.self) {
      try HubSettings.updateDataStore(home: tree.url, to: "/Volumes/C/S")
    }
    #expect(tree.contents("elsewhere.json") == "{}")
  }

  @Test func selectingARuntimeNeedsAUsableApp() throws {
    let tree = try TempTree()
    let sha = try makeFakeRuntimeApp(in: tree, at: "R.app")
    let settings = HubSettings.defaults(home: tree.url)

    let chosen = try settings.selectingRuntimeApp(at: tree.path("R.app"), expectedSHA256: sha)
    #expect(chosen.runtimeApp == tree.path("R.app"))
    #expect(chosen.dataStoreRoot == settings.dataStoreRoot)

    #expect(throws: HubError.self) {
      try settings.selectingRuntimeApp(at: tree.path("Missing.app"), expectedSHA256: nil)
    }
    let wrongHash = String(repeating: "0", count: 64)
    #expect(throws: HubError.self) {
      try settings.selectingRuntimeApp(at: tree.path("R.app"), expectedSHA256: wrongHash)
    }
  }
}

@Suite struct DataStoreStatusTests {
  private func store(_ tree: TempTree) throws -> String {
    try tree.writeHubConfig(in: "GameHub")
    return tree.path("GameHub")
  }

  @Test func okCarriesFreeSpaceAndTheConfig() throws {
    let tree = try TempTree()
    let root = try store(tree)
    let report = DataStoreStatus.check(root: root, capabilities: FakeCapabilities())
    guard case .ok(let info) = report.status else {
      Issue.record("expected ok, got \(report.status)")
      return
    }
    #expect(info.root == root)
    #expect(info.freeBytes == 500 << 30)
    #expect(info.totalBytes == 1000 << 30)
    #expect(info.hubConfig.runtime == "hub-0")
    #expect(report.isCaseSensitive == true)
    #expect(report.freeBytes == 500 << 30)
  }

  @Test func anUnmountedVolumeIsDriveNotConnected() {
    let capabilities = FakeCapabilities(unmountedVolumes: ["/Volumes/Gone"])
    let report = DataStoreStatus.check(root: "/Volumes/Gone/GameHub", capabilities: capabilities)
    #expect(report.status == .driveNotConnected(volume: "/Volumes/Gone"))
    #expect(report.status.message.contains("/Volumes/Gone"))
    #expect(!report.status.isUsable)
  }

  @Test func missingAndNotADirectory() throws {
    let tree = try TempTree()
    #expect(
      DataStoreStatus.check(root: tree.path("nope"), capabilities: FakeCapabilities()).status
        == .missing)
    try tree.write("file", "x")
    #expect(
      DataStoreStatus.check(root: tree.path("file"), capabilities: FakeCapabilities()).status
        == .notADirectory)
  }

  @Test func aCaseInsensitiveVolumeIsRefused() throws {
    let tree = try TempTree()
    let root = try store(tree)
    let capabilities = FakeCapabilities(caseInsensitivePrefixes: [tree.root])
    let report = DataStoreStatus.check(root: root, capabilities: capabilities)
    #expect(report.status == .notCaseSensitive)
    #expect(report.isCaseSensitive == false)
    #expect(report.freeBytes == 500 << 30, "the free space is still shown")
  }

  @Test func aReadOnlyFolderIsRefused() throws {
    let tree = try TempTree()
    let root = try store(tree)
    let capabilities = FakeCapabilities(readOnlyPrefixes: [tree.root])
    #expect(DataStoreStatus.check(root: root, capabilities: capabilities).status == .notWritable)
  }

  @Test func aFolderWithoutHubJSONIsNotInitialised() throws {
    let tree = try TempTree()
    try tree.makeDirectory("Empty")
    let report = DataStoreStatus.check(root: tree.path("Empty"), capabilities: FakeCapabilities())
    #expect(report.status == .notInitialised)
    #expect(report.freeBytes == 500 << 30)
  }

  @Test func aBrokenHubJSONIsReported() throws {
    let tree = try TempTree()
    try tree.write("Broken/Hub/hub.json", "{ nope")
    let report = DataStoreStatus.check(root: tree.path("Broken"), capabilities: FakeCapabilities())
    guard case .configInvalid = report.status else {
      Issue.record("expected configInvalid, got \(report.status)")
      return
    }
  }

  @Test func theLiveCapabilitiesAnswerForARealFolder() throws {
    let tree = try TempTree()
    let live = LiveDataStoreCapabilities()
    let nested = tree.path("not/yet/there")
    #expect(live.isWritable(at: nested), "a missing folder is judged by its nearest ancestor")
    #expect(live.capacity(at: nested)?.free ?? 0 > 0)
    #expect(live.device(of: nested) == live.device(of: tree.root))
    _ = live.isCaseSensitive(at: tree.root)  // either answer is valid on a real volume
    #expect(!live.isMounted(volumeRoot: "/Volumes/definitely-not-mounted-\(UUID().uuidString)"))
  }
}

@Suite struct RuntimeStatusTests {
  @Test func mapsTheStatesOfTheRuntimeApp() throws {
    let tree = try TempTree()
    let sha = try makeFakeRuntimeApp(in: tree, at: "R.app")

    guard case .ok(let info) = RuntimeStatus.check(app: tree.path("R.app"), expectedSHA256: sha)
    else {
      Issue.record("expected ok")
      return
    }
    #expect(info.id == "hub-0")
    #expect(RuntimeStatus.check(app: tree.path("R.app"), expectedSHA256: nil).isUsable)

    #expect(RuntimeStatus.check(app: tree.path("Missing.app"), expectedSHA256: nil) == .notFound)

    try tree.write("Broken.app/Contents/Info.plist", "x")
    guard case .invalid = RuntimeStatus.check(app: tree.path("Broken.app"), expectedSHA256: nil)
    else {
      Issue.record("expected invalid")
      return
    }

    let other = String(repeating: "0", count: 64)
    #expect(
      RuntimeStatus.check(app: tree.path("R.app"), expectedSHA256: other)
        == .mismatch(expected: other, actual: sha))
  }

  @Test func locationsCompareTheRuntimeWithHubJSON() throws {
    let tree = try TempTree()
    let sha = try makeFakeRuntimeApp(in: tree, at: "R.app")
    try tree.writeHubConfig(in: "GameHub", runtimeSHA: sha)
    let settings = HubSettings(dataStoreRoot: tree.path("GameHub"), runtimeApp: tree.path("R.app"))

    let good = HubLocationsStatus.check(settings, capabilities: FakeCapabilities())
    #expect(good.dataStore.status.isUsable)
    #expect(good.runtime.isUsable)
    #expect(!good.needsAttention)

    try tree.writeHubConfig(in: "Other", runtimeSHA: String(repeating: "0", count: 64))
    var other = settings
    other.dataStoreRoot = tree.path("Other")
    let mismatch = HubLocationsStatus.check(other, capabilities: FakeCapabilities())
    #expect(mismatch.needsAttention)
    guard case .mismatch = mismatch.runtime else {
      Issue.record("expected a mismatch, got \(mismatch.runtime)")
      return
    }

    let unplugged = HubLocationsStatus.check(
      HubSettings(dataStoreRoot: "/Volumes/Gone/GameHub", runtimeApp: tree.path("Missing.app")),
      capabilities: FakeCapabilities(unmountedVolumes: ["/Volumes/Gone"]))
    #expect(unplugged.dataStore.status == .driveNotConnected(volume: "/Volumes/Gone"))
    #expect(unplugged.runtime == .notFound)
  }
}

@Suite struct HubLayoutSettingsTests {
  private let noEnvironment: [String: String] = [:]

  @Test func derivesEveryPathFromTheDataStoreRoot() throws {
    let tree = try TempTree()
    let root = tree.path("Vol/GameHub")
    try tree.makeDirectory("Vol/GameHub/Library/Steam")
    let settings = HubSettings(dataStoreRoot: root, runtimeApp: "/x/R.app")
    let layout = HubLayout.from(settings: settings, environment: noEnvironment, home: tree.url)
    #expect(layout.hub.path == root)
    #expect(layout.steam.path == root + "/Library/Steam")
    #expect(layout.epic.path == root + "/Library/Epic")
    #expect(layout.ubisoft.path == root + "/Library/Ubisoft")
    #expect(layout.eaGames.path == root + "/EA Games")
    #expect(layout.bundles.path == tree.path("Vol/Bundles"), "beside the data store folder")
    #expect(
      layout.instances.path == tree.path("Library/Application Support/GameHub/Instances"))
  }

  @Test func theBundlesFolderIsOnTheVolumeOfAStoreUnderVolumes() {
    let settings = HubSettings(dataStoreRoot: "/Volumes/Big/Games/GameHub", runtimeApp: "/x/R.app")
    let layout = HubLayout.from(
      settings: settings, environment: noEnvironment, home: URL(fileURLWithPath: "/tmp/h"))
    #expect(layout.bundles.path == "/Volumes/Big/Bundles")
  }

  @Test func anUnmigratedStoreKeepsItsLegacyProviderFolders() throws {
    let tree = try TempTree()
    try tree.makeDirectory("Vol/GameHub")
    for legacy in ["Steam", "EpicGamesStore", "Ubisoft Game Launcher"] {
      try tree.makeDirectory("Vol/\(legacy)")
    }
    let settings = HubSettings(dataStoreRoot: tree.path("Vol/GameHub"), runtimeApp: "/x/R.app")
    let layout = HubLayout.from(settings: settings, environment: noEnvironment, home: tree.url)
    #expect(layout.steam.path == tree.path("Vol/Steam"))
    #expect(layout.epic.path == tree.path("Vol/EpicGamesStore"))
    #expect(layout.ubisoft.path == tree.path("Vol/Ubisoft Game Launcher"))

    // Once the new folder exists it wins, and a legacy symlink is never used in its place.
    try tree.makeDirectory("Vol/GameHub/Library/Steam")
    #expect(
      HubLayout.from(settings: settings, environment: noEnvironment, home: tree.url).steam.path
        == tree.path("Vol/GameHub/Library/Steam"))
  }

  @Test func aLegacySymlinkIsNotALegacyFolder() throws {
    let tree = try TempTree()
    try tree.makeDirectory("Vol/GameHub")
    try tree.makeDirectory("Elsewhere")
    try tree.symlink("Vol/Steam", to: tree.path("Elsewhere"))
    let settings = HubSettings(dataStoreRoot: tree.path("Vol/GameHub"), runtimeApp: "/x/R.app")
    let layout = HubLayout.from(settings: settings, environment: noEnvironment, home: tree.url)
    #expect(layout.steam.path == tree.path("Vol/GameHub/Library/Steam"))
  }

  @Test func theLegacyLookupCanBeSkipped() throws {
    let tree = try TempTree()
    try tree.makeDirectory("Vol/GameHub")
    try tree.makeDirectory("Vol/Steam")
    let settings = HubSettings(dataStoreRoot: tree.path("Vol/GameHub"), runtimeApp: "/x/R.app")
    let layout = HubLayout.from(
      settings: settings, environment: noEnvironment, home: tree.url,
      resolvingLegacyFolders: false)
    #expect(layout.steam.path == tree.path("Vol/GameHub/Library/Steam"))
  }

  @Test func theEnvironmentOverridesTheSettings() {
    let settings = HubSettings(dataStoreRoot: "/Volumes/ExT2/GameHub", runtimeApp: "/x/R.app")
    let home = URL(fileURLWithPath: "/tmp/h")
    let byVolume = HubLayout.from(
      settings: settings, environment: ["HUB_VOLUME": "/tmp/vol"], home: home)
    #expect(byVolume.hub.path == "/tmp/vol/GameHub")
    #expect(byVolume.bundles.path == "/tmp/vol/Bundles")

    let byRoot = HubLayout.from(
      settings: settings, environment: ["HUB_ROOT": "/tmp/root/Store"], home: home)
    #expect(byRoot.hub.path == "/tmp/root/Store")
    #expect(byRoot.eaGames.path == "/tmp/root/Store/EA Games")
    #expect(byRoot.bundles.path == "/tmp/root/Bundles")
  }

  @Test func standardLoadsTheSavedSettings() throws {
    let tree = try TempTree()
    let settings = HubSettings(dataStoreRoot: tree.path("Elsewhere/Store"), runtimeApp: "/x/R.app")
    try settings.save(home: tree.url)
    let layout = HubLayout.standard(environment: noEnvironment, home: tree.url)
    #expect(layout.hub.path == tree.path("Elsewhere/Store"))
    #expect(HubPaths.standard(home: tree.url).root.path == tree.path("Elsewhere/Store"))
  }

  @Test func hubPathsNameTheStoreFolders() throws {
    let tree = try TempTree()
    let paths = HubPaths(
      settings: HubSettings(dataStoreRoot: tree.path("S"), runtimeApp: "/x/R.app"))
    #expect(paths.library.path == tree.path("S/Library"))
    #expect(paths.backups.path == tree.path("S/Backups"))
    #expect(paths.apps.path == tree.path("S/Apps"))
    #expect(paths.build.path == tree.path("S/Build"))
    #expect(
      try paths.configuredPrefix().path == tree.path("S/Prefix"),
      "no hub.json: the default prefix")

    try tree.writeHubConfig(in: "S")
    let configured = HubConfig(
      schemaVersion: 1, prefix: tree.path("Elsewhere/Prefix"), runtime: "hub-0",
      runtimeManifestSHA256: String(repeating: "ab", count: 32), generation: 0)
    try configured.write(to: paths.config)
    #expect(
      try paths.configuredPrefix().path == tree.path("Elsewhere/Prefix"),
      "hub.json names the prefix")

    try tree.write("S/Hub/hub.json", "{ broken")
    #expect(throws: HubError.self) { try paths.configuredPrefix() }
  }
}
