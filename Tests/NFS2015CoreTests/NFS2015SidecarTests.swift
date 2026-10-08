import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015SidecarTests {
  private let on = NFS2015SidecarPreference(enabled: true)

  // MARK: The default

  @Test
  func `is off unless the player turned it on`() throws {
    #expect(NFS2015SidecarPreference.standard == NFS2015SidecarPreference(enabled: false))
    let scratch = try Scratch()
    defer { scratch.remove() }
    let loaded = NFS2015SidecarStore(support: scratch.root).load()
    #expect(loaded.preference == .standard && loaded.notice == nil)
    #expect(NFS2015SidecarState().preference == .standard)
  }

  // MARK: The saved file

  @Test
  func `keeps a choice as a small validated file, reads it back, and writes nothing twice`()
    throws
  {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015SidecarStore(support: scratch.root)
    #expect(try store.save(on))
    #expect(store.load() == NFS2015SidecarStore.Loaded(preference: on, notice: nil))
    #expect(try !store.save(on))
    let text = try scratch.text(NFS2015SidecarStore.fileName)
    #expect(text.utf8.count < 200 && text.contains("\"enabled\" : true"))
    #expect(text.contains("\"version\" : 1"))
    // The write is one atomic replacement: no temporary file stays beside the saved one.
    let names = try FileManager.default.contentsOfDirectory(atPath: scratch.root.path)
    #expect(names == [NFS2015SidecarStore.fileName])
    #expect(try store.save(.standard))
    #expect(store.load().preference == .standard)
  }

  @Test(arguments: [
    "not json", "", "{}", #"{"version":1}"#, #"{"enabled":true}"#,
    #"{"version":2,"enabled":true}"#, #"{"version":0,"enabled":true}"#,
    #"{"version":1,"enabled":"yes"}"#, #"{"version":1,"enabled":1}"#,
    #"{"version":"1","enabled":true}"#, "[]", "true",
    #"{"version":1,"enabled":true,"padding":""# + String(repeating: "x", count: 5000) + #""}"#,
  ])
  func `a damaged, foreign or oversized file means the sidecar is off, and says why`(
    text: String
  ) throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.write(NFS2015SidecarStore.fileName, text)
    let loaded = NFS2015SidecarStore(support: scratch.root).load()
    #expect(loaded.preference == .standard)
    #expect(loaded.notice?.contains("could not be used") == true)
    #expect(loaded.notice?.contains("the sidecar is off") == true)
  }

  @Test
  func `a symbolic link in place of the file is not followed`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.write("elsewhere.json", #"{"version":1,"enabled":true}"#)
    try FileManager.default.createSymbolicLink(
      at: scratch.url(NFS2015SidecarStore.fileName),
      withDestinationURL: scratch.url("elsewhere.json"))
    let loaded = NFS2015SidecarStore(support: scratch.root).load()
    #expect(loaded.preference == .standard && loaded.notice != nil)
  }

  @Test
  func `reset forgets the choice, including a file that could not be used`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015SidecarStore(support: scratch.root)
    #expect(try !store.reset())
    _ = try store.save(on)
    #expect(try store.reset())
    #expect(store.load() == NFS2015SidecarStore.Loaded(preference: .standard, notice: nil))
    try scratch.write(NFS2015SidecarStore.fileName, "garbage")
    #expect(try store.reset())
    #expect(store.load().notice == nil)
  }

  @Test
  func `answers a request with an outcome, and refuses a malformed one`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015SidecarStore(support: scratch.root)
    #expect(store.apply(.init(action: .save, preference: on)) == .saved)
    #expect(store.apply(.init(action: .save, preference: on)) == .unchanged)
    #expect(store.apply(.init(action: .reset)) == .reset)
    #expect(store.apply(.init(action: .reset)) == .unchanged)
    #expect(
      store.apply(.init(action: .save)) == .refused("A sidecar save needs the choice to keep."))
    #expect(
      store.apply(.init(action: .reset, preference: on))
        == .refused("A sidecar reset cannot also carry a choice."))
    #expect(store.load().preference == .standard)
  }

  @Test
  func `refuses, rather than failing, when the file cannot be written`() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("nowhere")
    let outcome = NFS2015SidecarStore(support: missing).apply(.init(action: .save, preference: on))
    #expect(outcome.refusal?.contains("Could not save the x87 sidecar choice") == true)
  }

  @Test
  func `a request survives the file the starter hands to the helper`() throws {
    for request in [
      NFS2015SidecarRequest(action: .save, preference: on),
      NFS2015SidecarRequest(action: .reset),
    ] {
      let decoded = try JSONDecoder().decode(
        NFS2015SidecarRequest.self, from: JSONEncoder().encode(request))
      #expect(decoded == request)
    }
  }

  // MARK: Choosing between the saved choice and a developer override

  @Test(arguments: [
    (false, nil as Bool?, false, "off (default)"),
    (true, nil, true, "on (saved setting)"),
    (false, true, true, "on (experiment override)"),
    (false, false, false, "off (experiment override)"),
    (true, true, true, "on (experiment override)"),
    (true, false, false, "off (experiment override)"),
  ])
  func `joins the saved choice with a developer override, which wins`(
    saved: Bool, forced: Bool?, enabled: Bool, line: String
  ) {
    var experiment = NFS2015ExperimentOverrides()
    experiment.sidecar = forced
    let choice = NFS2015SidecarChoice(
      preference: NFS2015SidecarPreference(enabled: saved), experiment: experiment)
    #expect(choice.enabled == enabled && choice.line == line)
  }

  @Test
  func `the override variable reaches the choice`() throws {
    for (value, enabled) in [("on", true), ("off", false)] {
      let experiment = try NFS2015ExperimentOverrides(environment: ["NFS2015_AB_SIDECAR": value])
      #expect(
        NFS2015SidecarChoice(preference: .standard, experiment: experiment).enabled == enabled)
    }
  }

  // MARK: The launch environment each state gives

  private func environment(_ choice: NFS2015SidecarChoice) throws -> [String: String] {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Need for Speed.app"),
      support: URL(fileURLWithPath: "/tmp/NFS Player"), game: .nfs2015)
    return try LaunchEnvironment.make(
      paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support,
      usesSidecar: choice.enabled)
  }

  @Test
  func `the default session has no sidecar variable, and MetalFX stays out of it`() throws {
    let environment = try environment(
      NFS2015SidecarChoice(preference: .standard, experiment: NFS2015ExperimentOverrides()))
    #expect(environment["ROSETTA_X87_PATH"] == nil)
    #expect(environment.keys.allSatisfy { !$0.hasPrefix("DXMT_") })
    #expect(environment["WINE_COMPATDB"]?.contains("DXMT_") == false)
  }

  @Test
  func `a saved on gives the variable, pointing inside the app, and changes nothing else`() throws {
    let off = try environment(
      NFS2015SidecarChoice(preference: .standard, experiment: NFS2015ExperimentOverrides()))
    var withSidecar = try environment(
      NFS2015SidecarChoice(preference: on, experiment: NFS2015ExperimentOverrides()))
    #expect(
      withSidecar["ROSETTA_X87_PATH"]
        == "/Applications/Need for Speed.app/Contents/Helpers/x87sidecar")
    withSidecar["ROSETTA_X87_PATH"] = nil
    #expect(withSidecar == off)
  }

  // MARK: The launcher state

  @Test
  func `round trips through the launcher state, and an older state file reads as off`() throws {
    let state = NFS2015SidecarState(preference: on, notice: "n", outcome: .refused("why"))
    let decoded = try JSONDecoder().decode(
      NFS2015Snapshot.self, from: JSONEncoder().encode(NFS2015Snapshot(sidecar: state)))
    #expect(decoded.sidecar == state)
    let older = try JSONDecoder().decode(
      NFS2015Snapshot.self, from: Data(#"{"hasOptionsFile":false,"settings":{"values":{}}}"#.utf8))
    #expect(older.sidecar == nil)
  }
}
