import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015RwxSwitchTests {
  private let rwx = NFS2015WineExperimentsPreference(rwxWxEmulation: true)

  private func overrides(_ environment: [String: String]) throws -> NFS2015ExperimentOverrides {
    try NFS2015ExperimentOverrides(environment: environment)
  }

  @Test
  func `is off by default and the saved file keeps it`() throws {
    #expect(NFS2015WineExperimentsPreference.standard.rwxWxEmulation == false)
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015WineExperimentsStore(support: scratch.root)
    #expect(try store.save(rwx))
    #expect(store.load() == .init(preference: rwx, notice: nil))
    #expect(try scratch.text("experiments.json").contains("\"rwxWxEmulation\" : true"))
    #expect(try !store.save(rwx))
  }

  @Test
  func `a file the -0007 apps wrote, with no such key, reads as off and not as damaged`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.write(
      "experiments.json",
      #"{"version":1,"flushToggle":true,"protectToggle":false,"tracePage":true}"#)
    let loaded = NFS2015WineExperimentsStore(support: scratch.root).load()
    #expect(loaded.notice == nil)
    #expect(loaded.preference == .init(flushToggle: true, tracePage: true, rwxWxEmulation: false))
    try scratch.write(
      "experiments.json",
      #"{"version":1,"flushToggle":true,"protectToggle":false,"tracePage":true,"rwxWxEmulation":"yes"}"#
    )
    #expect(NFS2015WineExperimentsStore(support: scratch.root).load().notice != nil)
  }

  @Test
  func `the saved switch becomes the variable and a line that names where it came from`() {
    let choice = NFS2015WineExperimentsChoice(preference: rwx, experiment: .init())
    #expect(choice.environment == ["WINE_RWX_WX_EMULATION": "1"])
    #expect(choice.emulatesWriteXorExecute && choice.isActive && !choice.tracesPages)
    #expect(choice.line == "WINE_RWX_WX_EMULATION=1 (saved setting)")
    let everything = NFS2015WineExperimentsChoice(
      preference: .init(
        flushToggle: true, protectToggle: true, tracePage: true, rwxWxEmulation: true),
      experiment: .init())
    #expect(everything.environment.count == 4)
    #expect(everything.line.hasSuffix("WINE_RWX_WX_EMULATION=1 (saved setting)"))
    #expect(!NFS2015WineExperimentsChoice.standard.emulatesWriteXorExecute)
  }

  @Test
  func `a developer override wins on or off, and the hot limit comes only from the developer`()
    throws
  {
    let force = try overrides([
      "NFS2015_AB_WINE_RWX_WX_EMULATION": "1", "NFS2015_AB_WINE_RWX_WX_HOT_LIMIT": "0",
    ])
    let over = NFS2015WineExperimentsChoice(preference: .standard, experiment: force)
    #expect(over.environment == ["WINE_RWX_WX_EMULATION": "1", "WINE_RWX_WX_HOT_LIMIT": "0"])
    #expect(
      over.line
        == "WINE_RWX_WX_EMULATION=1 (experiment override), WINE_RWX_WX_HOT_LIMIT=0 (experiment override)"
    )
    #expect(force.summary == "WINE_RWX_WX_EMULATION=1, WINE_RWX_WX_HOT_LIMIT=0")
    let off = try overrides(["NFS2015_AB_WINE_RWX_WX_EMULATION": "0"])
    let silenced = NFS2015WineExperimentsChoice(preference: rwx, experiment: off)
    #expect(silenced.environment.isEmpty && !silenced.emulatesWriteXorExecute)
    #expect(silenced.line == "WINE_RWX_WX_EMULATION off (experiment override)")
    // A saved choice alone never carries a hot limit.
    #expect(
      NFS2015WineExperimentsChoice(preference: rwx, experiment: .init()).environment[
        "WINE_RWX_WX_HOT_LIMIT"] == nil)
    // Without the prefix the helper's own environment sets nothing.
    #expect(try !overrides(["WINE_RWX_WX_EMULATION": "1", "WINE_RWX_WX_HOT_LIMIT": "5"]).isActive)
  }

  @Test
  func `refuses a typo in the developer variables`() {
    for bad in [
      ["NFS2015_AB_WINE_RWX_WX_EMULATION": "yes"], ["NFS2015_AB_WINE_RWX_WX_EMULATION": ""],
      ["NFS2015_AB_WINE_RWX_WX_EMULATION": "2"], ["NFS2015_AB_WINE_RWX_WX_HOT_LIMIT": ""],
      ["NFS2015_AB_WINE_RWX_WX_HOT_LIMIT": "-1"], ["NFS2015_AB_WINE_RWX_WX_HOT_LIMIT": "1e3"],
      ["NFS2015_AB_WINE_RWX_WX_HOT_LIMIT": "12345678"],
      ["NFS2015_AB_WINE_RWX_WX_HOT_LIMIT": "30 0"],
    ] {
      #expect(throws: LauncherError.self) { try NFS2015ExperimentOverrides(environment: bad) }
    }
  }

  @Test
  func `reaches the launch environment, and only the switches differ`() throws {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Need for Speed.app"),
      support: URL(fileURLWithPath: "/tmp/NFS Player"), game: .nfs2015)
    func environment(_ choice: NFS2015WineExperimentsChoice) throws -> [String: String] {
      try LaunchEnvironment.make(
        paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support,
        usesSidecar: false, experiments: choice.environment)
    }
    let off = try environment(.standard)
    #expect(off["WINE_RWX_WX_EMULATION"] == nil && off["WINE_RWX_WX_HOT_LIMIT"] == nil)
    var on = try environment(
      NFS2015WineExperimentsChoice(
        preference: rwx, experiment: try overrides(["NFS2015_AB_WINE_RWX_WX_HOT_LIMIT": "500"])))
    #expect(on["WINE_RWX_WX_EMULATION"] == "1" && on["WINE_RWX_WX_HOT_LIMIT"] == "500")
    for name in WineExperimentSwitches.names { on[name] = nil }
    #expect(on == off)
    #expect(WineExperimentSwitches.names.contains("WINE_RWX_WX_EMULATION"))
  }

  @Test
  func `the crash report lists it among the switches in force`() throws {
    let force = try overrides(["NFS2015_AB_WINE_RWX_WX_EMULATION": "1"])
    var context = CrashFixtures.context(experiment: force)
    context.wineSwitches = NFS2015WineExperimentsChoice(
      preference: .init(tracePage: true), experiment: force)
    let text = try #require(
      NFS2015CrashReport(
        digest: NFS2015LogDigest(log: CrashFixtures.log), context: context,
        load: CrashFixtures.load, now: CrashFixtures.now)
    ).text
    #expect(text.contains("experiment overrides: WINE_RWX_WX_EMULATION=1"))
    #expect(
      text.contains(
        "wine experiment switches: WINE_TRACE_PAGE=1B30000-1B31000 (saved setting), WINE_RWX_WX_EMULATION=1 (experiment override)"
      ))
  }
}
