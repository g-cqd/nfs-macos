import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015LaunchTests {
  private func plan() throws -> (SyntheticPrefix, NFS2015LaunchPlan) {
    let prefix = try SyntheticPrefix.complete()
    let install = try #require(
      try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan).install)
    return (prefix, try NFS2015LaunchPlan.make(install: install, plan: SyntheticPrefix.plan))
  }

  @Test
  func `starts the client directly with the argument its interface needs`() throws {
    let (prefix, plan) = try plan()
    defer { prefix.remove() }
    #expect(plan.client.windowsPath.hasSuffix(#"\EA Desktop\EADesktop.exe"#))
    #expect(plan.client.arguments == ["--in-process-gpu"])
    #expect(plan.client.wineArguments.count == 2)
    #expect(plan.client.windowsPath.contains("13.796.0.6309"))
  }

  @Test
  func `hands the launch request to the stub, not the client`() throws {
    let (prefix, plan) = try plan()
    defer { prefix.remove() }
    #expect(plan.request.windowsPath.hasSuffix(#"\EA Desktop\EALauncher.exe"#))
    #expect(plan.request.arguments == ["origin2://game/launch/?offerIds=1024486"])
    #expect(plan.workingDirectory.lastPathComponent == "Need for Speed")
    #expect(plan.readiness.startMarker == "[STARTUP]")
    #expect(plan.readiness.readyEvents == ["login", "client.boot.ready"])
    #expect(plan.readinessSeconds == 120)
  }

  @Test
  func `rejects a launch request that is not a bounded store URL`() throws {
    for url in ["https://example.invalid/{offer}", "origin2://game/launch/?offerIds=1024486"] {
      let plan = StoreClientPlan(
        name: "EA app", installRoot: "a", clientExecutable: "b", clientArguments: [],
        launcherExecutable: "c", launchURL: url, offerID: "1", signInEvidence: ["d"],
        readinessLog: "e", startMarker: "[STARTUP]", readyEvents: ["login"], readinessSeconds: 10,
        gameRoot: "f")
      #expect(throws: LauncherError.self) { try plan.validate() }
    }
  }

  @Test(arguments: [
    ("", ["login"]), ("[STARTUP]\n[x]", ["login"]), ("[STARTUP]", []),
    ("[STARTUP]", ["login; id"]), ("[STARTUP]", ["Login"]),
    ("[STARTUP]", [String](repeating: "a", count: 9)),
  ])
  func `rejects a readiness marker or event that is not plain`(marker: String, events: [String])
    throws
  {
    let plan = StoreClientPlan(
      name: "EA app", installRoot: "a", clientExecutable: "b", clientArguments: [],
      launcherExecutable: "c", launchURL: "origin2://game/launch/?offerIds={offer}", offerID: "1",
      signInEvidence: ["d"], readinessLog: "e", startMarker: marker, readyEvents: events,
      readinessSeconds: 10, gameRoot: "f")
    #expect(throws: LauncherError.self) { try plan.validate() }
  }

  @Test
  func `rejects a readiness log that leaves the Windows folder`() throws {
    let plan = StoreClientPlan(
      name: "EA app", installRoot: "a", clientExecutable: "b", clientArguments: [],
      launcherExecutable: "c", launchURL: "origin2://game/launch/?offerIds={offer}", offerID: "1",
      signInEvidence: ["d"], readinessLog: "ProgramData/../../escape.log",
      startMarker: "[STARTUP]", readyEvents: ["login"], readinessSeconds: 10, gameRoot: "f")
    #expect(throws: LauncherError.self) { try plan.validate() }
  }

  @Test
  func `finds the client log case-insensitively and before it exists`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let existing = try prefix.file("PROGRAMDATA/ea desktop/Logs/EADesktop.log")
    let found = try NFS2015LaunchPlan.logLocation(
      "ProgramData/EA Desktop/Logs/EADesktop.log", in: prefix.driveC)
    #expect(found.resolvingSymlinksInPath() == existing.resolvingSymlinksInPath())
    let absent = try SyntheticPrefix()
    defer { absent.remove() }
    let pending = try NFS2015LaunchPlan.logLocation(
      "ProgramData/EA Desktop/Logs/EADesktop.log", in: absent.driveC)
    #expect(pending.path.hasSuffix("/drive_c/ProgramData/EA Desktop/Logs/EADesktop.log"))
  }

  @Test
  func `rejects a client argument that is not a plain switch`() throws {
    let plan = StoreClientPlan(
      name: "EA app", installRoot: "a", clientExecutable: "b",
      clientArguments: ["--in-process-gpu; rm -rf /"], launcherExecutable: "c",
      launchURL: "origin2://game/launch/?offerIds={offer}", offerID: "1", signInEvidence: ["d"],
      readinessLog: "e", startMarker: "[STARTUP]", readyEvents: ["login"], readinessSeconds: 10,
      gameRoot: "f")
    #expect(throws: LauncherError.self) { try plan.validate() }
  }

  @Test
  func `builds the controller key for each declared device`() throws {
    let text = try NFS2015Controller.registry(devices: ["054C/05C4", "054c/0ce6"])
    #expect(text.hasPrefix("REGEDIT4\n"))
    #expect(text.contains(#"\WineBus\Devices\054C/05C4]"#))
    #expect(text.contains(#"\WineBus\Devices\054C/0CE6]"#))
    #expect(text.components(separatedBy: "\"Hidraw\"=dword:00000000").count == 3)
  }

  @Test(arguments: ["054C", "054C/05C", "054C/05C4/1", "ZZZZ/05C4"])
  func `rejects an invalid controller device`(device: String) {
    #expect(throws: LauncherError.self) { try NFS2015Controller.registry(devices: [device]) }
  }

  @Test
  func `counts no descendants for a process that has none`() {
    #expect(ProcessFamily.descendants(of: ProcessInfo.processInfo.processIdentifier) >= 0)
  }
}

struct PrefixSettingsTests {
  static let retina = RegistrySetting(
    hive: .currentUser, path: #"Software\Wine\Mac Driver"#, name: "RetinaMode", value: "Y",
    kind: .string, reason: "Wine advertises the native panel")

  @Test
  func `writes a script Wine can import for each declared hive`() throws {
    let script = try #require(
      try RegistrySetting.script([
        Self.retina,
        RegistrySetting(
          hive: .localMachine,
          path: #"System\CurrentControlSet\Services\WineBus\Devices\054C/05C4"#, name: "Hidraw",
          value: "0", kind: .dword),
      ]))
    #expect(script.hasPrefix("REGEDIT4\n"))
    #expect(script.contains(#"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#))
    #expect(script.contains("\"RetinaMode\"=\"Y\""))
    #expect(script.contains("\"Hidraw\"=dword:00000000"))
    #expect(try RegistrySetting.script([]) == nil)
  }

  @Test
  func `reads a value back out of the hive Wine actually wrote`() {
    let hive = """
      WINE REGISTRY Version 2

      [Software\\\\Wine\\\\Mac Driver] 1790447526
      #time=1dd4de555333daa
      "AllowSetGamma"=dword:00000000
      "RetinaMode"="Y"

      [Volatile Environment] 1790447302
      "RetinaMode"="N"
      """
    #expect(Self.retina.isRecorded(in: hive))
    #expect(Self.retina.hive.file == "user.reg")
    // The same name under a different key must not count.
    let elsewhere = RegistrySetting(
      hive: .currentUser, path: "Software\\Wine\\Other", name: "RetinaMode", value: "Y",
      kind: .string)
    #expect(!elsewhere.isRecorded(in: hive))
  }

  @Test
  func `treats a prefix without the key as needing it, and a prepared prefix as done`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let prefix = root.appendingPathComponent("Prefix")
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    try Data(#"[Software\\Wine\\Mac Driver] 1\n"AllowSetGamma"=dword:00000000\#n"#.utf8)
      .write(to: prefix.appendingPathComponent("user.reg"))
    let preparation = PrefixPreparation(support: root)
    #expect(try preparation.missing([Self.retina], in: prefix).count == 1)
    var imported: [URL] = []
    let applied = try preparation.apply([Self.retina], in: prefix) { imported.append($0) }
    #expect(applied.count == 1 && imported.count == 1)
    #expect(!FileManager.default.fileExists(atPath: imported[0].path), "The script is removed")
    // Wine would have written the value; prove a prepared prefix starts nothing at all.
    try Data(
      "[Software\\\\Wine\\\\Mac Driver] 1\n\"RetinaMode\"=\"Y\"\n".utf8
    ).write(to: prefix.appendingPathComponent("user.reg"))
    var second = 0
    #expect(try preparation.apply([Self.retina], in: prefix) { _ in second += 1 }.isEmpty)
    #expect(second == 0)
  }

  @Test(arguments: [
    RegistrySetting(hive: .currentUser, path: "A", name: "B", value: "x\"y", kind: .string),
    RegistrySetting(hive: .currentUser, path: "A]\nB", name: "C", value: "y", kind: .string),
    RegistrySetting(hive: .currentUser, path: "A", name: "B", value: "GG", kind: .dword),
    RegistrySetting(hive: .currentUser, path: "\\A", name: "B", value: "y", kind: .string),
    RegistrySetting(hive: .currentUser, path: "A", name: "B\\C", value: "y", kind: .string),
  ])
  func `refuses a registry value that could inject another line`(setting: RegistrySetting) {
    #expect(throws: LauncherError.self) { try setting.validate() }
  }
}
