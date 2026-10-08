import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015WineExperimentsTests {
  // The three experiments, with the workaround saved off so these tests see only them.
  private let flush = NFS2015WineExperimentsPreference(flushToggle: true, rwxWxEmulation: false)
  private let all = NFS2015WineExperimentsPreference(
    flushToggle: true, protectToggle: true, tracePage: true, rwxWxEmulation: false)

  // MARK: The switch names and values

  @Test(arguments: [
    ("1B30000-1B31000", true), ("1b30000-1b31000", true), ("0-1", true),
    ("0000000000000001-FFFFFFFFFFFFFFFF", true), ("1B31000-1B30000", false),
    ("1B30000-1B30000", false), ("1B30000", false), ("-1", false), ("1-", false), ("", false),
    ("1-2-3", false), ("0x1B30000-0x1B31000", false), ("1B30000 - 1B31000", false),
    ("11111111111111111-FFFFFFFFFFFFFFFFF", false), ("G-H", false),
  ])
  func `accepts a trace window only in the form the runtime reads`(text: String, valid: Bool) {
    #expect(WineExperimentSwitches.isTraceWindow(text) == valid)
  }

  @Test
  func `validates names and values`() throws {
    try WineExperimentSwitches.validate([:])
    try WineExperimentSwitches.validate([
      "WINE_ROSETTA_FLUSH_TOGGLE": "1", "WINE_ROSETTA_PROTECT_TOGGLE": "1",
      "WINE_TRACE_PAGE": "1B30000-1B31000", "WINE_RWX_WX_EMULATION": "1",
      "WINE_RWX_WX_HOT_LIMIT": "300",
    ])
    for bad in [
      ["WINE_ROSETTA_FLUSH_TOGGLE": "0"], ["WINE_ROSETTA_FLUSH_TOGGLE": "true"],
      ["WINE_ROSETTA_PROTECT_TOGGLE": ""], ["WINE_TRACE_PAGE": "1"],
      ["WINE_TRACE_PAGE": "2-1"], ["DYLD_INSERT_LIBRARIES": "/x"], ["WINEDEBUG": "+all"],
      ["WINE_RWX_WX_EMULATION": "0"], ["WINE_RWX_WX_EMULATION": "true"],
      ["WINE_RWX_WX_HOT_LIMIT": ""], ["WINE_RWX_WX_HOT_LIMIT": "-1"],
      ["WINE_RWX_WX_HOT_LIMIT": "12345678"], ["WINE_RWX_WX_HOT_LIMIT": "3e2"],
    ] {
      #expect(throws: LauncherError.self) { try WineExperimentSwitches.validate(bad) }
    }
    #expect(WineExperimentSwitches.isTraceWindow(WineExperimentSwitches.presetTraceWindow))
  }

  // MARK: The saved file

  @Test
  func `by default only the workaround is on, and the three experiments are off`() throws {
    #expect(NFS2015WineExperimentsPreference.standard == .init())
    let standard = NFS2015WineExperimentsPreference.standard
    #expect(standard.rwxWxEmulation && !standard.flushToggle && !standard.protectToggle)
    #expect(!standard.tracePage)
    let scratch = try Scratch()
    defer { scratch.remove() }
    let loaded = NFS2015WineExperimentsStore(support: scratch.root).load()
    #expect(loaded.preference == .standard && loaded.notice == nil)
    let choice = NFS2015WineExperimentsChoice.standard
    // The workaround and the history of the stub's page, nothing else.
    #expect(
      choice.environment == [
        "WINE_RWX_WX_EMULATION": "1", "WINE_RWX_WX_LOG": "1B30000-1B31000",
      ])
    #expect(choice.isActive && !choice.tracesPages && choice.emulatesWriteXorExecute)
    #expect(choice.rwxLogWindow == "1B30000-1B31000")
    #expect(
      choice.line == "WINE_RWX_WX_EMULATION=1 (default), WINE_RWX_WX_LOG=1B30000-1B31000 (default)")
    // With the workaround saved off there is nothing to log, and nothing is set.
    #expect(NFS2015WineExperimentsChoice.allOff.rwxLogWindow == nil)
  }

  @Test
  func `a fresh state has the workaround on, and a saved off is respected`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015WineExperimentsStore(support: scratch.root)
    #expect(store.load().preference.rwxWxEmulation)
    #expect(try store.save(.allOff))
    let reloaded = store.load()
    #expect(!reloaded.preference.rwxWxEmulation && reloaded.notice == nil)
    let choice = NFS2015WineExperimentsChoice(
      preference: reloaded.preference, experiment: NFS2015ExperimentOverrides())
    #expect(choice.environment.isEmpty && !choice.isActive)
    #expect(choice.line == "WINE_RWX_WX_EMULATION off (saved setting)")
    #expect(try store.reset())
    #expect(store.load().preference.rwxWxEmulation)
  }

  @Test
  func `keeps a choice as a small validated file, reads it back, and writes nothing twice`()
    throws
  {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015WineExperimentsStore(support: scratch.root)
    #expect(try store.save(all))
    #expect(store.load() == .init(preference: all, notice: nil))
    #expect(try !store.save(all))
    let text = try scratch.text(NFS2015WineExperimentsStore.fileName)
    #expect(text.utf8.count < 300 && text.contains("\"flushToggle\" : true"))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: scratch.root.path) == ["experiments.json"]
    )
    #expect(try store.save(.standard))
    #expect(store.load().preference == .standard)
  }

  @Test(arguments: [
    "not json", "", "{}", #"{"version":1}"#,
    #"{"version":2,"flushToggle":true,"protectToggle":false,"tracePage":false}"#,
    #"{"version":1,"flushToggle":"yes","protectToggle":false,"tracePage":false}"#,
    #"{"version":1,"flushToggle":true,"protectToggle":false}"#, "[]",
    #"{"version":1,"flushToggle":true,"protectToggle":true,"tracePage":true,"pad":""#
      + String(repeating: "x", count: 5000) + #""}"#,
  ])
  func `a damaged, foreign or oversized file means the defaults, and says why`(text: String)
    throws
  {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.write(NFS2015WineExperimentsStore.fileName, text)
    let loaded = NFS2015WineExperimentsStore(support: scratch.root).load()
    #expect(loaded.preference == .standard)
    #expect(loaded.notice?.contains("could not be used") == true)
    #expect(loaded.notice?.contains("the defaults apply") == true)
    #expect(loaded.preference.rwxWxEmulation)
  }

  @Test
  func `resets, including an unusable file, and answers requests`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015WineExperimentsStore(support: scratch.root)
    #expect(try !store.reset())
    #expect(store.apply(.init(action: .save, preference: flush)) == .saved)
    #expect(store.apply(.init(action: .save, preference: flush)) == .unchanged)
    #expect(store.apply(.init(action: .reset)) == .reset)
    #expect(store.apply(.init(action: .reset)) == .unchanged)
    #expect(store.apply(.init(action: .save)).refusal != nil)
    #expect(store.apply(.init(action: .reset, preference: flush)).refusal != nil)
    try scratch.write(NFS2015WineExperimentsStore.fileName, "garbage")
    #expect(try store.reset())
    #expect(store.load().notice == nil)
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("nowhere")
    let outcome = NFS2015WineExperimentsStore(support: missing).apply(
      .init(action: .save, preference: flush))
    #expect(outcome.refusal?.contains("Could not save the Wine experiment choice") == true)
  }

  // MARK: Joining the saved choice with a developer's override

  private func overrides(_ environment: [String: String]) throws -> NFS2015ExperimentOverrides {
    try NFS2015ExperimentOverrides(environment: environment)
  }

  @Test
  func `a saved choice becomes the environment and a line that names where it came from`() throws {
    let choice = NFS2015WineExperimentsChoice(preference: all, experiment: .init())
    #expect(
      choice.environment == [
        "WINE_ROSETTA_FLUSH_TOGGLE": "1", "WINE_ROSETTA_PROTECT_TOGGLE": "1",
        "WINE_TRACE_PAGE": "1B30000-1B31000",
      ])
    #expect(choice.isActive && choice.tracesPages)
    #expect(
      choice.line
        == "WINE_ROSETTA_FLUSH_TOGGLE=1 (saved setting), WINE_ROSETTA_PROTECT_TOGGLE=1 (saved setting), WINE_TRACE_PAGE=1B30000-1B31000 (saved setting), WINE_RWX_WX_EMULATION off (saved setting)"
    )
    let one = NFS2015WineExperimentsChoice(
      preference: .init(protectToggle: true, rwxWxEmulation: false), experiment: .init())
    #expect(one.environment == ["WINE_ROSETTA_PROTECT_TOGGLE": "1"] && !one.tracesPages)
    #expect(
      (try WineExperimentSwitches.validate(choice.environment)) == ())
  }

  @Test
  func `an override wins over the saved choice, on or off, and is named in the line`() throws {
    let force = try overrides([
      "NFS2015_AB_WINE_ROSETTA_PROTECT_TOGGLE": "1",
      "NFS2015_AB_WINE_TRACE_PAGE": "50000000-50010000",
    ])
    let over = NFS2015WineExperimentsChoice(preference: flush, experiment: force)
    #expect(
      over.environment == [
        "WINE_ROSETTA_FLUSH_TOGGLE": "1", "WINE_ROSETTA_PROTECT_TOGGLE": "1",
        "WINE_TRACE_PAGE": "50000000-50010000",
      ])
    #expect(over.line.contains("WINE_ROSETTA_FLUSH_TOGGLE=1 (saved setting)"))
    #expect(over.line.contains("WINE_ROSETTA_PROTECT_TOGGLE=1 (experiment override)"))
    #expect(over.line.contains("WINE_TRACE_PAGE=50000000-50010000 (experiment override)"))
    let off = try overrides([
      "NFS2015_AB_WINE_ROSETTA_FLUSH_TOGGLE": "0", "NFS2015_AB_WINE_ROSETTA_PROTECT_TOGGLE": "0",
      "NFS2015_AB_WINE_TRACE_PAGE": "off",
    ])
    let silenced = NFS2015WineExperimentsChoice(preference: all, experiment: off)
    #expect(silenced.environment.isEmpty && !silenced.isActive)
    #expect(
      silenced.line
        == "WINE_ROSETTA_FLUSH_TOGGLE off (experiment override), WINE_ROSETTA_PROTECT_TOGGLE off (experiment override), WINE_RWX_WX_EMULATION off (saved setting), WINE_TRACE_PAGE off (experiment override)"
    )
    // An override that names a switch which is already off changes nothing.
    let untouched = NFS2015WineExperimentsChoice(preference: .allOff, experiment: off)
    #expect(untouched.line == "WINE_RWX_WX_EMULATION off (saved setting)")
  }

  @Test
  func `reads the developer overrides from the helper's environment, and refuses a typo`() throws {
    let value = try overrides([
      "NFS2015_AB_WINE_ROSETTA_FLUSH_TOGGLE": "1", "NFS2015_AB_WINE_ROSETTA_PROTECT_TOGGLE": "0",
      "NFS2015_AB_WINE_TRACE_PAGE": "1B30000-1B31000",
    ])
    #expect(value.flushToggle == true && value.protectToggle == false)
    #expect(value.tracePage == "1B30000-1B31000" && value.isActive)
    #expect(
      value.summary
        == "WINE_ROSETTA_FLUSH_TOGGLE=1, WINE_ROSETTA_PROTECT_TOGGLE=0, WINE_TRACE_PAGE=1B30000-1B31000"
    )
    #expect(try overrides([:]).flushToggle == nil && !(try overrides([:]).isActive))
    let mixed = try overrides([
      "NFS2015_AB_SIDECAR": "on", "NFS2015_AB_WINE_TF_MAX_STEPS": "5",
      "NFS2015_AB_WINE_TRACE_PAGE": "off",
    ])
    #expect(mixed.summary == "x87 sidecar on, WINE_TF_MAX_STEPS=5, WINE_TRACE_PAGE=off")
    for bad in [
      ["NFS2015_AB_WINE_ROSETTA_FLUSH_TOGGLE": "yes"], ["NFS2015_AB_WINE_ROSETTA_FLUSH_TOGGLE": ""],
      ["NFS2015_AB_WINE_ROSETTA_PROTECT_TOGGLE": "2"], ["NFS2015_AB_WINE_TRACE_PAGE": "2-1"],
      ["NFS2015_AB_WINE_TRACE_PAGE": "OFF"], ["NFS2015_AB_WINE_TRACE_PAGE": "1B30000"],
    ] {
      #expect(throws: LauncherError.self) { try NFS2015ExperimentOverrides(environment: bad) }
    }
    // Unprefixed names are not overrides: the helper's own environment cannot set them by accident.
    #expect(try !overrides(["WINE_ROSETTA_FLUSH_TOGGLE": "1", "WINE_TRACE_PAGE": "1-2"]).isActive)
  }

  // MARK: The launch environment

  private func environment(_ choice: NFS2015WineExperimentsChoice) throws -> [String: String] {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Need for Speed.app"),
      support: URL(fileURLWithPath: "/tmp/NFS Player"), game: .nfs2015)
    return try LaunchEnvironment.make(
      paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support,
      usesSidecar: false, experiments: choice.environment)
  }

  @Test
  func `the default session carries the workaround and none of the three experiments`() throws {
    let environment = try environment(.standard)
    #expect(environment["WINE_RWX_WX_EMULATION"] == "1")
    #expect(environment["WINE_RWX_WX_LOG"] == "1B30000-1B31000")
    for name in WineExperimentSwitches.names
    where name != "WINE_RWX_WX_EMULATION" && name != "WINE_RWX_WX_LOG" {
      #expect(environment[name] == nil, "\(name)")
    }
    #expect(environment["ROSETTA_X87_PATH"] == nil)
    #expect(environment.keys.allSatisfy { !$0.hasPrefix("DXMT_") })
  }

  @Test
  func `a chosen switch reaches the session, and only the switches differ`() throws {
    let off = try environment(.allOff)
    var on = try environment(NFS2015WineExperimentsChoice(preference: all, experiment: .init()))
    #expect(on["WINE_ROSETTA_FLUSH_TOGGLE"] == "1" && on["WINE_ROSETTA_PROTECT_TOGGLE"] == "1")
    #expect(on["WINE_TRACE_PAGE"] == "1B30000-1B31000")
    for name in WineExperimentSwitches.names { on[name] = nil }
    #expect(on == off)
  }

  @Test
  func `the launch environment refuses a name that is not a switch`() throws {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Need for Speed.app"),
      support: URL(fileURLWithPath: "/tmp/NFS Player"), game: .nfs2015)
    #expect(throws: LauncherError.self) {
      try LaunchEnvironment.make(
        paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support,
        experiments: ["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"])
    }
  }

  // MARK: The launcher state and the crash report

  @Test
  func `round trips through the launcher state, and an older state file reads as every switch off`()
    throws
  {
    let state = NFS2015WineExperimentsState(preference: all, notice: "n", outcome: .refused("why"))
    let decoded = try JSONDecoder().decode(
      NFS2015Snapshot.self, from: JSONEncoder().encode(NFS2015Snapshot(experiments: state)))
    #expect(decoded.experiments == state)
    let older = try JSONDecoder().decode(
      NFS2015Snapshot.self, from: Data(#"{"hasOptionsFile":false,"settings":{"values":{}}}"#.utf8))
    #expect(older.experiments == nil)
  }

  @Test
  func `the crash report lists the switches in force and the overrides`() throws {
    func text(_ switches: NFS2015WineExperimentsChoice, _ experiment: NFS2015ExperimentOverrides)
      throws -> String
    {
      var context = CrashFixtures.context(experiment: experiment)
      context.wineSwitches = switches
      return try #require(
        NFS2015CrashReport(
          digest: NFS2015LogDigest(log: CrashFixtures.log), context: context,
          load: CrashFixtures.load, now: CrashFixtures.now)
      ).text
    }
    let plain = try text(.standard, .init())
    #expect(plain.contains("experiment overrides: none"))
    #expect(plain.contains("wine experiment switches: WINE_RWX_WX_EMULATION=1 (default)"))
    #expect(
      try text(.allOff, .init()).contains(
        "wine experiment switches: WINE_RWX_WX_EMULATION off (saved setting)"))
    let force = try overrides(["NFS2015_AB_WINE_ROSETTA_FLUSH_TOGGLE": "1"])
    let set = try text(
      NFS2015WineExperimentsChoice(
        preference: .init(tracePage: true, rwxWxEmulation: false), experiment: force), force)
    #expect(set.contains("experiment overrides: WINE_ROSETTA_FLUSH_TOGGLE=1"))
    #expect(
      set.contains(
        "wine experiment switches: WINE_ROSETTA_FLUSH_TOGGLE=1 (experiment override), WINE_TRACE_PAGE=1B30000-1B31000 (saved setting), WINE_RWX_WX_EMULATION off (saved setting)"
      ))
    // Without a context choice the report derives it from the experiment, so an older caller is right too.
    let derived = NFS2015CrashContext(
      pins: CrashFixtures.pins, host: CrashFixtures.host, display: nil,
      displayPlan: NFS2015DisplaySafety.plan(
        facts: nil, hasOptionsFile: nil, preference: .standard),
      seed: nil, metalFX: .off, diagnostics: .standard, diagnosticLog: false,
      settings: NFS2015Settings(), tuning: [:], experiment: force)
    #expect(
      derived.wineSwitches.environment == [
        "WINE_ROSETTA_FLUSH_TOGGLE": "1", "WINE_RWX_WX_EMULATION": "1",
        "WINE_RWX_WX_LOG": "1B30000-1B31000",
      ])
  }

  @Test
  func `MetalFX is off by default and its page says it is experimental and known to crash`() {
    #expect(NFS2015MetalFXPreference.off.spatialUpscaling == false)
    #expect(NFS2015MetalFX.statusLabel == "experimental, known to crash NFS16")
    #expect(NFS2015MetalFX.heading == "MetalFX (experimental, known to crash NFS16)")
    #expect(NFS2015MetalFX.crashWarning.contains("Leave it off to play"))
    #expect(NFS2015MetalFX.environment(for: .off) == nil)
    #expect(NFS2015SidecarPreference.standard.enabled == false)
  }
}
