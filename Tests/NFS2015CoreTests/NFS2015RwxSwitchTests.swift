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
  func `is on by default, and the saved file keeps either choice`() throws {
    #expect(NFS2015WineExperimentsPreference.standard.rwxWxEmulation)
    #expect(!NFS2015WineExperimentsPreference.allOff.rwxWxEmulation)
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015WineExperimentsStore(support: scratch.root)
    #expect(try store.save(rwx))
    #expect(store.load() == .init(preference: rwx, notice: nil))
    #expect(try scratch.text("experiments.json").contains("\"rwxWxEmulation\" : true"))
    #expect(try !store.save(rwx))
    #expect(try store.save(.allOff))
    #expect(try scratch.text("experiments.json").contains("\"rwxWxEmulation\" : false"))
    #expect(store.load() == .init(preference: .allOff, notice: nil))
  }

  @Test
  func `a file the -0007 apps wrote, with no such key, gets the default (on) and is not damaged`()
    throws
  {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.write(
      "experiments.json",
      #"{"version":1,"flushToggle":true,"protectToggle":false,"tracePage":true}"#)
    let loaded = NFS2015WineExperimentsStore(support: scratch.root).load()
    #expect(loaded.notice == nil)
    #expect(loaded.preference == .init(flushToggle: true, tracePage: true, rwxWxEmulation: true))
    // A file that says off keeps saying off.
    try scratch.write(
      "experiments.json",
      #"{"version":1,"flushToggle":false,"protectToggle":false,"tracePage":false,"rwxWxEmulation":false}"#
    )
    #expect(NFS2015WineExperimentsStore(support: scratch.root).load().preference == .allOff)
    try scratch.write(
      "experiments.json",
      #"{"version":1,"flushToggle":true,"protectToggle":false,"tracePage":true,"rwxWxEmulation":"yes"}"#
    )
    #expect(NFS2015WineExperimentsStore(support: scratch.root).load().notice != nil)
  }

  @Test
  func `the saved switch becomes the variable and a line that names where it came from`() {
    let choice = NFS2015WineExperimentsChoice(preference: rwx, experiment: .init())
    #expect(
      choice.environment == [
        "WINE_RWX_WX_EMULATION": "1", "WINE_RWX_WX_LOG": "1B30000-1B31000",
      ])
    #expect(choice.emulatesWriteXorExecute && choice.isActive && !choice.tracesPages)
    #expect(
      choice.line == "WINE_RWX_WX_EMULATION=1 (default), WINE_RWX_WX_LOG=1B30000-1B31000 (default)")
    let everything = NFS2015WineExperimentsChoice(
      preference: .init(
        flushToggle: true, protectToggle: true, tracePage: true, rwxWxEmulation: true),
      experiment: .init())
    #expect(everything.environment.count == 5)
    #expect(everything.line.contains("WINE_RWX_WX_EMULATION=1 (saved setting)"))
    #expect(NFS2015WineExperimentsChoice.standard.emulatesWriteXorExecute)
    #expect(!NFS2015WineExperimentsChoice.allOff.emulatesWriteXorExecute)
  }

  @Test
  func `a developer override wins on or off, and the hot limit comes only from the developer`()
    throws
  {
    let force = try overrides([
      "NFS2015_AB_WINE_RWX_WX_EMULATION": "1", "NFS2015_AB_WINE_RWX_WX_HOT_LIMIT": "0",
    ])
    let over = NFS2015WineExperimentsChoice(preference: .standard, experiment: force)
    #expect(
      over.environment == [
        "WINE_RWX_WX_EMULATION": "1", "WINE_RWX_WX_HOT_LIMIT": "0",
        "WINE_RWX_WX_LOG": "1B30000-1B31000",
      ])
    #expect(
      over.line
        == "WINE_RWX_WX_EMULATION=1 (experiment override), WINE_RWX_WX_HOT_LIMIT=0 (experiment override), WINE_RWX_WX_LOG=1B30000-1B31000 (default)"
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
  func `with nothing saved the developer override 0 turns the default off, and 1 keeps it`() throws
  {
    let off = NFS2015WineExperimentsChoice(
      preference: .standard,
      experiment: try overrides(["NFS2015_AB_WINE_RWX_WX_EMULATION": "0"]))
    #expect(off.environment.isEmpty && !off.emulatesWriteXorExecute)
    #expect(off.line == "WINE_RWX_WX_EMULATION off (experiment override)")
    let on = NFS2015WineExperimentsChoice(
      preference: .standard,
      experiment: try overrides(["NFS2015_AB_WINE_RWX_WX_EMULATION": "1"]))
    #expect(
      on.environment == [
        "WINE_RWX_WX_EMULATION": "1", "WINE_RWX_WX_LOG": "1B30000-1B31000",
      ])
    #expect(
      on.line
        == "WINE_RWX_WX_EMULATION=1 (experiment override), WINE_RWX_WX_LOG=1B30000-1B31000 (default)"
    )
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
    let off = try environment(.allOff)
    #expect(off["WINE_RWX_WX_EMULATION"] == nil && off["WINE_RWX_WX_HOT_LIMIT"] == nil)
    #expect(try environment(.standard)["WINE_RWX_WX_EMULATION"] == "1")
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

struct NFS2015RwxLogSwitchTests {
  private func overrides(_ environment: [String: String]) throws -> NFS2015ExperimentOverrides {
    try NFS2015ExperimentOverrides(environment: environment)
  }

  @Test
  func `the default session asks for the stub page's history, and only that window`() throws {
    let choice = NFS2015WineExperimentsChoice.standard
    #expect(choice.environment["WINE_RWX_WX_LOG"] == "1B30000-1B31000")
    #expect(WineExperimentSwitches.isTraceWindow(choice.environment["WINE_RWX_WX_LOG"] ?? ""))
    #expect(choice.environment["WINE_RWX_WX_NEAR_LIMIT"] == nil)
    #expect(choice.environment["WINE_RWX_WX_TF_RELEASE"] == nil)
    #expect(choice.environment["WINE_RWX_WX_HOT_LIMIT"] == nil)
  }

  @Test
  func `the developer can name another window, all pages, or turn the log off`() throws {
    let other = NFS2015WineExperimentsChoice(
      preference: .standard,
      experiment: try overrides(["NFS2015_AB_WINE_RWX_WX_LOG": "50000000-50010000"]))
    #expect(other.environment["WINE_RWX_WX_LOG"] == "50000000-50010000")
    #expect(other.line.contains("WINE_RWX_WX_LOG=50000000-50010000 (experiment override)"))
    let all = NFS2015WineExperimentsChoice(
      preference: .standard, experiment: try overrides(["NFS2015_AB_WINE_RWX_WX_LOG": "all"]))
    #expect(all.environment["WINE_RWX_WX_LOG"] == "all" && all.rwxLogWindow == "all")
    let off = NFS2015WineExperimentsChoice(
      preference: .standard, experiment: try overrides(["NFS2015_AB_WINE_RWX_WX_LOG": "off"]))
    #expect(off.environment == ["WINE_RWX_WX_EMULATION": "1"] && off.rwxLogWindow == nil)
    #expect(
      off.line == "WINE_RWX_WX_EMULATION=1 (default), WINE_RWX_WX_LOG off (experiment override)")
    // An override of the log when the workaround is saved off is still honoured: it is explicit.
    let explicit = NFS2015WineExperimentsChoice(
      preference: .allOff, experiment: try overrides(["NFS2015_AB_WINE_RWX_WX_LOG": "all"]))
    #expect(explicit.environment == ["WINE_RWX_WX_LOG": "all"])
  }

  @Test
  func `the near limit and the trap-flag release come only from the developer`() throws {
    let force = try overrides([
      "NFS2015_AB_WINE_RWX_WX_NEAR_LIMIT": "0", "NFS2015_AB_WINE_RWX_WX_TF_RELEASE": "1",
    ])
    let choice = NFS2015WineExperimentsChoice(preference: .standard, experiment: force)
    #expect(choice.environment["WINE_RWX_WX_NEAR_LIMIT"] == "0")
    #expect(choice.environment["WINE_RWX_WX_TF_RELEASE"] == "1")
    #expect(force.summary == "WINE_RWX_WX_NEAR_LIMIT=0, WINE_RWX_WX_TF_RELEASE=1")
    // A TF release of 0 sets nothing.
    let zero = NFS2015WineExperimentsChoice(
      preference: .standard,
      experiment: try overrides(["NFS2015_AB_WINE_RWX_WX_TF_RELEASE": "0"]))
    #expect(zero.environment["WINE_RWX_WX_TF_RELEASE"] == nil)
    // Without the prefix the helper's own environment sets nothing.
    #expect(try !overrides(["WINE_RWX_WX_LOG": "all", "WINE_RWX_WX_NEAR_LIMIT": "5"]).isActive)
  }

  @Test
  func
    `refuses a typo in the new developer variables, and the launch environment refuses bad values`()
  {
    for bad in [
      ["NFS2015_AB_WINE_RWX_WX_LOG": ""], ["NFS2015_AB_WINE_RWX_WX_LOG": "2-1"],
      ["NFS2015_AB_WINE_RWX_WX_LOG": "ALL"], ["NFS2015_AB_WINE_RWX_WX_LOG": "1B30000"],
      ["NFS2015_AB_WINE_RWX_WX_NEAR_LIMIT": ""], ["NFS2015_AB_WINE_RWX_WX_NEAR_LIMIT": "-1"],
      ["NFS2015_AB_WINE_RWX_WX_NEAR_LIMIT": "12345678"],
      ["NFS2015_AB_WINE_RWX_WX_TF_RELEASE": "yes"], ["NFS2015_AB_WINE_RWX_WX_TF_RELEASE": "2"],
    ] {
      #expect(throws: LauncherError.self) { try NFS2015ExperimentOverrides(environment: bad) }
    }
    for bad in [
      ["WINE_RWX_WX_LOG": "ALL"], ["WINE_RWX_WX_LOG": "off"], ["WINE_RWX_WX_NEAR_LIMIT": "x"],
      ["WINE_RWX_WX_TF_RELEASE": "0"],
    ] {
      #expect(throws: LauncherError.self) { try WineExperimentSwitches.validate(bad) }
    }
    #expect(throws: Never.self) {
      try WineExperimentSwitches.validate([
        "WINE_RWX_WX_LOG": "all", "WINE_RWX_WX_NEAR_LIMIT": "0", "WINE_RWX_WX_TF_RELEASE": "1",
      ])
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
    let plain = try environment(.allOff)
    var withLog = try environment(.standard)
    #expect(withLog["WINE_RWX_WX_LOG"] == "1B30000-1B31000")
    for name in WineExperimentSwitches.names { withLog[name] = nil }
    #expect(withLog == plain)
  }
}
