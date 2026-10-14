import Foundation
import Testing

@testable import HubCore

/// Helper to assert HubError.invalid contains a field fragment.
package func expectInvalid(_ fieldFragment: String, _ body: () throws -> Void) {
  do {
    try body()
    Issue.record("Expected HubError.invalid to be thrown")
  } catch let error as HubError {
    if case let .invalid(message) = error {
      if !message.contains(fieldFragment) {
        Issue.record("Error message '\(message)' does not contain '\(fieldFragment)'")
      }
    } else {
      Issue.record("Expected HubError.invalid, got different error case")
    }
  } catch {
    Issue.record("Expected HubError, got \(type(of: error))")
  }
}

@Suite struct ModelTests {
  @Test func decodeValidFix() throws {
    let json = """
    {
      "id": "test-fix",
      "title": "Test Fix",
      "reason": "Testing the fix system",
      "status": "verified",
      "evidence": ["evidence 1"],
      "appliesWhen": {"all": [{"kind": "provider", "value": "ea"}]},
      "requires": [],
      "actions": [
        {"kind": "env", "name": "TEST_VAR", "value": "test_value", "scope": "session"},
        {"kind": "renderer", "exe": "*", "api": "d3d9", "backend": "mtld3d"},
        {"kind": "companion", "exe": "helper.exe", "after": "ready", "readiness": {"log": "{prefix}/test.log", "startMarker": null, "events": [], "ports": [8080], "timeoutSeconds": 10}}
      ],
      "parameters": [
        {"id": "test-param", "title": "Test Param", "type": "bool", "default": "true", "binds": "actions[0].value"}
      ]
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    let fix = try decoder.decode(Fix.self, from: data)
    #expect(fix.id == "test-fix")
    #expect(fix.title == "Test Fix")
    #expect(fix.status == .verified)
    #expect(fix.actions.count == 3)
    #expect(fix.parameters.count == 1)
    try fix.validate()
  }

  @Test func decodeValidRecipe() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "bf3",
      "kind": "game",
      "title": "Battlefield 3",
      "status": "verified",
      "evidence": ["evidence 1"],
      "provider": null,
      "ids": null,
      "location": null,
      "executable": "bf3.exe",
      "architecture": "x86_64",
      "processes": [],
      "leaseTarget": null,
      "launchChain": null,
      "launch": {
        "method": "direct",
        "executable": null,
        "arguments": [],
        "urlTemplate": null
      },
      "stop": null,
      "readiness": null,
      "fixes": [],
      "settings": [],
      "install": null,
      "legacyWrapper": null
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    let recipe = try decoder.decode(Recipe.self, from: data)
    #expect(recipe.id == "bf3")
    #expect(recipe.kind == .game)
    #expect(recipe.schemaVersion == 1)
    try recipe.validate()
  }

  @Test func decodeValidProviderRecipe() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "ea-provider",
      "kind": "provider",
      "title": "EA Provider",
      "status": "verified",
      "evidence": ["evidence 1"],
      "provider": "ea",
      "ids": null,
      "location": null,
      "executable": "eadesktop.exe",
      "architecture": null,
      "processes": [],
      "leaseTarget": null,
      "launchChain": null,
      "launch": {
        "method": "provider",
        "executable": null,
        "arguments": [],
        "urlTemplate": null
      },
      "stop": {
        "arguments": null,
        "taskkill": ["eadesktop.exe"]
      },
      "readiness": {
        "log": "{prefix}/log.txt",
        "startMarker": null,
        "events": [],
        "ports": [8080],
        "timeoutSeconds": 10
      },
      "fixes": [],
      "settings": [],
      "install": null,
      "legacyWrapper": null
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    let recipe = try decoder.decode(Recipe.self, from: data)
    #expect(recipe.kind == .provider)
    #expect(recipe.provider == .ea)
    try recipe.validate()
  }

  @Test func decodeValidRuntimeManifest() throws {
    let json = """
    {
      "id": "hub-0",
      "title": "Hub Runtime 0",
      "wineVersion": "wine-0011",
      "source": {"origin": "github", "revision": "abc123", "patchSeries": ["0001"]},
      "manifestSHA256": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
      "keyFiles": {"system.reg": "fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321"},
      "capabilities": [{"id": "dxmtDXGI", "evidence": "file:lib/wine/dxgi/dxmt/x86_64-windows/d3d11core.dll"}],
      "helpers": {"x87sidecar": {"path": "helpers/x87sidecar", "sha256": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"}}
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    let manifest = try decoder.decode(RuntimeManifest.self, from: data)
    #expect(manifest.id == "hub-0")
    try manifest.validate()
  }

  @Test func decodeValidPatch() throws {
    let json = """
    {
      "id": "0001",
      "title": "First patch",
      "capability": "dxmtDXGI",
      "ref": "branch-name",
      "commit": "abc1234",
      "status": "verified"
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    let patch = try decoder.decode(Patch.self, from: data)
    #expect(patch.id == "0001")
    try patch.validate()
  }

  @Test func decodeValidKnob() throws {
    let json = """
    {
      "name": "WINE_TF_EMULATION",
      "scopes": ["session"],
      "reason": "Enable TF emulation"
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    let knob = try decoder.decode(Knob.self, from: data)
    #expect(knob.name == "WINE_TF_EMULATION")
    try knob.validate()
  }

  @Test func decodeValidPrerequisite() throws {
    let json = """
    {
      "id": "wine-mono",
      "title": "Wine Mono",
      "url": "https://example.com/mono.msi",
      "sha256": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
      "kind": "msi",
      "arch": "both"
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    let prereq = try decoder.decode(Prerequisite.self, from: data)
    #expect(prereq.id == "wine-mono")
    try prereq.validate()
  }

  @Test func decodeValidProposalRule() throws {
    let json = """
    {
      "id": "test-rule",
      "when": {"all": [{"kind": "provider", "value": "ea"}]},
      "propose": {"fixes": ["test-fix"], "provider": "ea"}
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    let rule = try decoder.decode(ProposalRule.self, from: data)
    #expect(rule.id == "test-rule")
    try rule.validate()
  }

  @Test func roundTripFix() throws {
    let fix = Fix(
      id: "test-fix",
      title: "Test Fix",
      reason: "Testing",
      status: .verified,
      evidence: ["evidence"],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: [.env(name: "TEST", value: "value", scope: .session)],
      parameters: []
    )
    try fix.validate()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let encoded = try encoder.encode(fix)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(Fix.self, from: encoded)
    try decoded.validate()
    #expect(decoded.id == fix.id)
    #expect(decoded.title == fix.title)
  }

  @Test func predicateMatches() throws {
    let facts = TargetFacts(
      targetID: "bf3",
      exe: "bf3.exe",
      exeSHA256: nil,
      machine: "x86_64",
      subsystem: "gui",
      imports: Set(["d3d9.dll"]),
      markers: Set(),
      provider: .ea,
      runtime: Set([.dxmtDXGI])
    )

    let allPredicate = Predicate.all([
      Condition(kind: .exe, value: "BF3.EXE"),
      Condition(kind: .machine, value: "x86_64")
    ])
    #expect(allPredicate.matches(facts))

    let anyPredicate = Predicate.any([
      Condition(kind: .provider, value: "steam"),
      Condition(kind: .provider, value: "ea")
    ])
    #expect(anyPredicate.matches(facts))

    let importsPredicate = Predicate.any([
      Condition(kind: .imports, value: "d3d9"),
      Condition(kind: .imports, value: "d3d9.dll")
    ])
    #expect(importsPredicate.matches(facts))

    let nilFactPredicate = Predicate.all([
      Condition(kind: .exeSHA256, value: "abc123")
    ])
    #expect(!nilFactPredicate.matches(facts))
  }

  @Test func caseInsensitiveExeMatch() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: "Game.exe",
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )

    let predicate = Predicate.all([Condition(kind: .exe, value: "game.exe")])
    #expect(predicate.matches(facts))
  }

  @Test func dllImportMatch() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(["d3d9"]),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )

    let predicateWithDot = Predicate.all([Condition(kind: .imports, value: "d3d9.dll")])
    #expect(predicateWithDot.matches(facts))

    let predicateWithoutDot = Predicate.all([Condition(kind: .imports, value: "d3d9")])
    #expect(predicateWithoutDot.matches(facts))
  }
}
