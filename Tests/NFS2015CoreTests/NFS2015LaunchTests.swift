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
    #expect(plan.readinessEvidence.count == 1)
    #expect(plan.readinessChildren == 1)
    #expect(plan.readinessSeconds == 120)
  }

  @Test
  func `returns as soon as the client has helpers and touches its own folder`() throws {
    let readiness = ClientReadiness(
      evidence: [URL(fileURLWithPath: "/tmp/logs")], children: 2, deadline: 10)
    let start = Date()
    var slept = 0
    let waited = try readiness.wait(
      since: start, modified: { _ in slept >= 3 ? start.addingTimeInterval(1) : nil },
      isRunning: { true }, helpers: { slept >= 2 ? 2 : 0 }, wait: { slept += $0 })
    #expect(waited == 3)
  }

  @Test
  func `refuses to send a request to a client that is still wedged`() throws {
    let readiness = ClientReadiness(
      evidence: [URL(fileURLWithPath: "/tmp/logs")], children: 2, deadline: 4)
    var slept = 0
    #expect(throws: LauncherError.self) {
      try readiness.wait(
        since: Date(), modified: { _ in Date() }, isRunning: { true }, helpers: { 0 },
        wait: { slept += $0 })
    }
    #expect(slept == 5)
  }

  @Test
  func `tells the player to open the client when it exits early`() throws {
    let readiness = ClientReadiness(
      evidence: [URL(fileURLWithPath: "/tmp/logs")], children: 0, deadline: 10)
    let error = #expect(throws: LauncherError.self) {
      try readiness.wait(
        since: Date(), modified: { _ in nil }, isRunning: { false }, helpers: { 0 },
        wait: { _ in })
    }
    #expect(error?.localizedDescription.contains("stopped before it was ready") == true)
  }

  @Test
  func `refuses a plan with no way to tell the client is ready`() throws {
    #expect(throws: LauncherError.self) {
      try ClientReadiness(evidence: [], children: 1, deadline: 10).wait(
        since: Date(), modified: { _ in nil }, isRunning: { true }, helpers: { 4 }, wait: { _ in })
    }
  }

  @Test
  func `rejects a launch request that is not a bounded store URL`() throws {
    for url in ["https://example.invalid/{offer}", "origin2://game/launch/?offerIds=1024486"] {
      let plan = StoreClientPlan(
        name: "EA app", installRoot: "a", clientExecutable: "b", clientArguments: [],
        launcherExecutable: "c", launchURL: url, offerID: "1", signInEvidence: ["d"],
        readinessEvidence: ["e"], readinessChildren: 0, readinessSeconds: 10, gameRoot: "f")
      #expect(throws: LauncherError.self) { try plan.validate() }
    }
  }

  @Test
  func `rejects a client argument that is not a plain switch`() throws {
    let plan = StoreClientPlan(
      name: "EA app", installRoot: "a", clientExecutable: "b",
      clientArguments: ["--in-process-gpu; rm -rf /"], launcherExecutable: "c",
      launchURL: "origin2://game/launch/?offerIds={offer}", offerID: "1", signInEvidence: ["d"],
      readinessEvidence: ["e"], readinessChildren: 0, readinessSeconds: 10, gameRoot: "f")
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
