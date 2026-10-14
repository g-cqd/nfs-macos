import Foundation
import Testing

@testable import HubCore

@Suite struct ModelAmendmentTests {
  // MARK: - A1: Fix.optIn

  @Test func fixOptInDefaultsFalse() throws {
    let json = """
    {
      "id": "test-fix",
      "title": "Test Fix",
      "reason": "Testing",
      "status": "verified",
      "evidence": ["evidence 1"],
      "appliesWhen": {"all": [{"kind": "always", "value": ""}]},
      "requires": [],
      "actions": [{"kind": "sidecar", "enabled": true}],
      "parameters": []
    }
    """
    let data = json.data(using: .utf8)!
    let fix = try JSONDecoder().decode(Fix.self, from: data)
    #expect(fix.optIn == false)
    try fix.validate()
  }

  @Test func fixOptInCanBeTrue() throws {
    let json = """
    {
      "id": "test-fix",
      "title": "Test Fix",
      "reason": "Testing",
      "status": "verified",
      "evidence": ["evidence 1"],
      "appliesWhen": {"all": [{"kind": "always", "value": ""}]},
      "requires": [],
      "actions": [{"kind": "sidecar", "enabled": true}],
      "parameters": [],
      "optIn": true
    }
    """
    let data = json.data(using: .utf8)!
    let fix = try JSONDecoder().decode(Fix.self, from: data)
    #expect(fix.optIn == true)
    try fix.validate()
  }

  // MARK: - A2: Readiness.log and ReadinessEvent.log validation

  @Test func readinessLogValidWithPrefix() throws {
    let json = """
    {
      "log": "{prefix}/output.log",
      "startMarker": null,
      "events": [],
      "ports": [8080],
      "timeoutSeconds": 10
    }
    """
    let data = json.data(using: .utf8)!
    let readiness = try JSONDecoder().decode(Readiness.self, from: data)
    try readiness.validate()
  }

  @Test func readinessLogValidWithProviderRoot() throws {
    let json = """
    {
      "log": "{providerRoot}/app.log",
      "startMarker": null,
      "events": [],
      "ports": [8080],
      "timeoutSeconds": 10
    }
    """
    let data = json.data(using: .utf8)!
    let readiness = try JSONDecoder().decode(Readiness.self, from: data)
    try readiness.validate()
  }

  @Test func readinessLogRejectedWithoutPrefix() throws {
    let json = """
    {
      "log": "output.log",
      "startMarker": null,
      "events": [],
      "ports": [8080],
      "timeoutSeconds": 10
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("Readiness.log") {
      let readiness = try JSONDecoder().decode(Readiness.self, from: data)
      try readiness.validate()
    }
  }

  @Test func readinessEventLogValidWithPrefix() throws {
    let json = """
    {
      "state": "ready",
      "contains": "Ready",
      "log": "{prefix}/event.log"
    }
    """
    let data = json.data(using: .utf8)!
    let event = try JSONDecoder().decode(ReadinessEvent.self, from: data)
    try event.validate()
  }

  @Test func readinessEventLogRejectedWithoutPrefix() throws {
    let json = """
    {
      "state": "ready",
      "contains": "Ready",
      "log": "event.log"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("ReadinessEvent.log") {
      let event = try JSONDecoder().decode(ReadinessEvent.self, from: data)
      try event.validate()
    }
  }

  // MARK: - A3: Condition.Kind.always

  @Test func conditionAlwaysMatchesWithEmptyValue() throws {
    let json = """
    {
      "kind": "always",
      "value": ""
    }
    """
    let data = json.data(using: .utf8)!
    let condition = try JSONDecoder().decode(Condition.self, from: data)
    try condition.validate()
  }

  @Test func conditionAlwaysRejectedWithNonEmptyValue() throws {
    let json = """
    {
      "kind": "always",
      "value": "something"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("Condition.always") {
      let condition = try JSONDecoder().decode(Condition.self, from: data)
      try condition.validate()
    }
  }

  // MARK: - A5: ReadinessEvent.holdSeconds

  @Test func readinessEventHoldSecondsValid() throws {
    let json = """
    {
      "state": "needsSignIn",
      "contains": "Sign in",
      "log": "{prefix}/auth.log",
      "holdSeconds": 2
    }
    """
    let data = json.data(using: .utf8)!
    let event = try JSONDecoder().decode(ReadinessEvent.self, from: data)
    try event.validate()
  }

  @Test func readinessEventHoldSecondsOptional() throws {
    let json = """
    {
      "state": "ready",
      "contains": "Ready",
      "log": "{prefix}/ready.log"
    }
    """
    let data = json.data(using: .utf8)!
    let event = try JSONDecoder().decode(ReadinessEvent.self, from: data)
    #expect(event.holdSeconds == nil)
    try event.validate()
  }

  @Test func readinessEventHoldSecondsRejectedAbove600() throws {
    let json = """
    {
      "state": "ready",
      "contains": "Ready",
      "log": "{prefix}/ready.log",
      "holdSeconds": 601
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("holdSeconds") {
      let event = try JSONDecoder().decode(ReadinessEvent.self, from: data)
      try event.validate()
    }
  }

  // MARK: - A6: FixAction.dllOverride validation

  @Test func dllOverrideWithExeValid() throws {
    let json = """
    {
      "kind": "dllOverride",
      "exe": "game.exe",
      "dll": "d3d9",
      "mode": "disabled"
    }
    """
    let data = json.data(using: .utf8)!
    let action = try JSONDecoder().decode(FixAction.self, from: data)
    try action.validate()
  }

  @Test func dllOverrideExeLessDisabledExeValid() throws {
    let json = """
    {
      "kind": "dllOverride",
      "dll": "myprog.exe",
      "mode": "disabled"
    }
    """
    let data = json.data(using: .utf8)!
    let action = try JSONDecoder().decode(FixAction.self, from: data)
    try action.validate()
  }

  @Test func dllOverrideExeLessNotDisabledRejected() throws {
    let json = """
    {
      "kind": "dllOverride",
      "dll": "d3d9",
      "mode": "builtin"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("exe-less override") {
      let action = try JSONDecoder().decode(FixAction.self, from: data)
      try action.validate()
    }
  }

  @Test func dllOverrideExeLessDllNotExeRejected() throws {
    let json = """
    {
      "kind": "dllOverride",
      "dll": "d3d9",
      "mode": "disabled"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("exe-less override") {
      let action = try JSONDecoder().decode(FixAction.self, from: data)
      try action.validate()
    }
  }

  // MARK: - A7: FixAction.xmlAttribute

  @Test func xmlAttributeValid() throws {
    let json = """
    {
      "kind": "xmlAttribute",
      "file": "{gameRoot}/config.xml",
      "element": "platform",
      "attribute": "value",
      "value": "d3d9"
    }
    """
    let data = json.data(using: .utf8)!
    let action = try JSONDecoder().decode(FixAction.self, from: data)
    try action.validate()
  }

  @Test func xmlAttributeInvalidElement() throws {
    let json = """
    {
      "kind": "xmlAttribute",
      "file": "{gameRoot}/config.xml",
      "element": "123invalid",
      "attribute": "value",
      "value": "d3d9"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("element") {
      let action = try JSONDecoder().decode(FixAction.self, from: data)
      try action.validate()
    }
  }

  // MARK: - A8: FixAction.drive lifetime

  @Test func driveSessionLifetimeValid() throws {
    let json = """
    {
      "kind": "drive",
      "letter": "e",
      "target": "{gameRoot}",
      "lifetime": "session"
    }
    """
    let data = json.data(using: .utf8)!
    let action = try JSONDecoder().decode(FixAction.self, from: data)
    try action.validate()
  }

  @Test func drivePersistentLifetimeValid() throws {
    let json = """
    {
      "kind": "drive",
      "letter": "f",
      "target": "{hubRoot}",
      "lifetime": "persistent"
    }
    """
    let data = json.data(using: .utf8)!
    let action = try JSONDecoder().decode(FixAction.self, from: data)
    try action.validate()
  }

  @Test func driveInvalidLifetimeRejected() throws {
    let json = """
    {
      "kind": "drive",
      "letter": "e",
      "target": "{gameRoot}",
      "lifetime": "temporary"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("lifetime") {
      let action = try JSONDecoder().decode(FixAction.self, from: data)
      try action.validate()
    }
  }

  // MARK: - A9: FixAction.window virtualDesktop exe

  @Test func windowVirtualDesktopWithExeValid() throws {
    let json = """
    {
      "kind": "window",
      "mode": "virtualDesktop",
      "size": "1024x768",
      "exe": "game.exe"
    }
    """
    let data = json.data(using: .utf8)!
    let action = try JSONDecoder().decode(FixAction.self, from: data)
    try action.validate()
  }

  @Test func windowVirtualDesktopWithoutExeRejected() throws {
    let json = """
    {
      "kind": "window",
      "mode": "virtualDesktop",
      "size": "1024x768"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("exe") {
      let action = try JSONDecoder().decode(FixAction.self, from: data)
      try action.validate()
    }
  }

  @Test func windowRetinaWithoutExeValid() throws {
    let json = """
    {
      "kind": "window",
      "mode": "retina",
      "enabled": true
    }
    """
    let data = json.data(using: .utf8)!
    let action = try JSONDecoder().decode(FixAction.self, from: data)
    try action.validate()
  }

  @Test func windowRetinaWithExeRejected() throws {
    let json = """
    {
      "kind": "window",
      "mode": "retina",
      "enabled": true,
      "exe": "game.exe"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("retina must not have exe") {
      let action = try JSONDecoder().decode(FixAction.self, from: data)
      try action.validate()
    }
  }

  // MARK: - A10 & A11: Probe and LaunchStage

  @Test func probeLogValid() throws {
    let json = """
    {
      "kind": "log",
      "log": "{prefix}/startup.log",
      "contains": "Started",
      "holdSeconds": 1
    }
    """
    let data = json.data(using: .utf8)!
    let probe = try JSONDecoder().decode(Probe.self, from: data)
    try probe.validate()
  }

  @Test func probePortValid() throws {
    let json = """
    {
      "kind": "port",
      "port": 8080
    }
    """
    let data = json.data(using: .utf8)!
    let probe = try JSONDecoder().decode(Probe.self, from: data)
    try probe.validate()
  }

  @Test func probeProcessValid() throws {
    let json = """
    {
      "kind": "process",
      "exe": "game.exe",
      "present": true
    }
    """
    let data = json.data(using: .utf8)!
    let probe = try JSONDecoder().decode(Probe.self, from: data)
    try probe.validate()
  }

  @Test func launchStageClientScopeValid() throws {
    let json = """
    {
      "id": "stage-1",
      "title": "Load",
      "passWhen": [{"kind": "log", "log": "{prefix}/startup.log", "contains": "Ready"}],
      "failWhen": [],
      "timeoutSeconds": 30,
      "scope": "client"
    }
    """
    let data = json.data(using: .utf8)!
    let stage = try JSONDecoder().decode(LaunchStage.self, from: data)
    try stage.validate()
  }

  @Test func launchStageGameScopeValid() throws {
    let json = """
    {
      "id": "stage-2",
      "title": "Launch Game",
      "passWhen": [{"kind": "process", "exe": "game.exe", "present": true}],
      "failWhen": [{"kind": "process", "exe": "game.exe", "present": false}],
      "timeoutSeconds": 60,
      "scope": "game"
    }
    """
    let data = json.data(using: .utf8)!
    let stage = try JSONDecoder().decode(LaunchStage.self, from: data)
    try stage.validate()
  }

  @Test func launchStageScopeDefaultsToClient() throws {
    let json = """
    {
      "id": "stage-1",
      "title": "Load",
      "passWhen": [{"kind": "log", "log": "{prefix}/startup.log", "contains": "Ready"}],
      "failWhen": [],
      "timeoutSeconds": 30
    }
    """
    let data = json.data(using: .utf8)!
    let stage = try JSONDecoder().decode(LaunchStage.self, from: data)
    #expect(stage.scope == "client")
    try stage.validate()
  }

  @Test func launchStageRecipeValid() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test-game",
      "kind": "game",
      "title": "Test Game",
      "status": "verified",
      "evidence": ["evidence 1"],
      "provider": null,
      "ids": null,
      "location": null,
      "executable": "game.exe",
      "architecture": "x86_64",
      "processes": [],
      "leaseTarget": null,
      "launchChain": null,
      "launch": {"method": "direct", "executable": null, "arguments": [], "urlTemplate": null},
      "stop": null,
      "readiness": null,
      "fixes": [],
      "settings": [],
      "install": null,
      "legacyWrapper": null,
      "launchStages": [
        {
          "id": "load",
          "title": "Loading",
          "passWhen": [{"kind": "log", "log": "{prefix}/startup.log", "contains": "Ready"}],
          "failWhen": [],
          "timeoutSeconds": 60
        }
      ]
    }
    """
    let data = json.data(using: .utf8)!
    let recipe = try JSONDecoder().decode(Recipe.self, from: data)
    #expect(recipe.launchStages.count == 1)
    try recipe.validate()
  }

  // MARK: - T4a: Location.versionedWindowsPath

  @Test func locationVersionedWindowsPathValid() throws {
    let json = """
    {
      "kind": "versionedWindowsPath",
      "path": "C:\\\\Program Files\\\\Game",
      "child": "bin"
    }
    """
    let data = json.data(using: .utf8)!
    let location = try JSONDecoder().decode(Location.self, from: data)
    try location.validate()
  }

  @Test func locationVersionedWindowsPathNestedChildValid() throws {
    let json = """
    {
      "kind": "versionedWindowsPath",
      "path": "E:\\\\Games\\\\App",
      "child": "bin\\\\x64"
    }
    """
    let data = json.data(using: .utf8)!
    let location = try JSONDecoder().decode(Location.self, from: data)
    try location.validate()
  }

  @Test func locationVersionedWindowsPathInvalidPath() throws {
    let json = """
    {
      "kind": "versionedWindowsPath",
      "path": "relative/path",
      "child": "bin"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("drive letter") {
      let location = try JSONDecoder().decode(Location.self, from: data)
      try location.validate()
    }
  }

  @Test func locationVersionedWindowsPathInvalidChild() throws {
    let json = """
    {
      "kind": "versionedWindowsPath",
      "path": "C:\\\\Program Files",
      "child": "..\\\\etc"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("..") {
      let location = try JSONDecoder().decode(Location.self, from: data)
      try location.validate()
    }
  }
}
