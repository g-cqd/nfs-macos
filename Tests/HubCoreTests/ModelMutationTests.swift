import Foundation
import Testing

@testable import HubCore

@Suite struct ModelMutationTests {
  // MARK: - Unknown key tests
  @Test func rejectsUnknownKeyInFix() throws {
    let json = """
    {
      "id": "test-fix",
      "title": "Test Fix",
      "reason": "Testing",
      "status": "verified",
      "evidence": [],
      "appliesWhen": {"all": []},
      "requires": [],
      "actions": [{"kind": "sidecar", "enabled": true}],
      "unknownKey": "value"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Fix.self, from: data)
    }
  }

  @Test func rejectsUnknownKeyInRecipe() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "verified",
      "evidence": [],
      "launch": {"method": "direct", "arguments": []},
      "unknownKey": "value"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  @Test func rejectsUnknownKeyInFixAction() throws {
    let json = """
    {
      "id": "test-fix",
      "title": "Test Fix",
      "reason": "Testing",
      "status": "verified",
      "evidence": [],
      "appliesWhen": {"all": []},
      "requires": [],
      "actions": [{"kind": "env", "name": "TEST", "value": "val", "scope": "session", "unknownKey": "x"}]
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Fix.self, from: data)
    }
  }

  // MARK: - ID validation tests
  @Test func rejectsBadId() throws {
    let fix = Fix(
      id: "UPPERCASE",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([]),
      requires: [],
      actions: [.sidecar(enabled: true)]
    )
    expectInvalid("Fix.id") {
      try fix.validate()
    }
  }

  @Test func rejectsTooLongId() throws {
    let fix = Fix(
      id: String(repeating: "a", count: 49),
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([]),
      requires: [],
      actions: [.sidecar(enabled: true)]
    )
    expectInvalid("Fix.id") {
      try fix.validate()
    }
  }

  @Test func rejectsIdStartingWithHyphen() throws {
    let fix = Fix(
      id: "-test",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([]),
      requires: [],
      actions: [.sidecar(enabled: true)]
    )
    expectInvalid("Fix.id") {
      try fix.validate()
    }
  }

  // MARK: - Path validation tests
  @Test func rejectsPathWithDotDot() throws {
    let action = FixAction.file(
      asset: "../etc/passwd",
      destination: "{gameRoot}/file.txt",
      sha256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
    )
    expectInvalid("FixAction.file.asset") {
      try action.validate()
    }
  }

  @Test func rejectsPathStartingWithSlash() throws {
    let action = FixAction.file(
      asset: "/etc/passwd",
      destination: "{gameRoot}/file.txt",
      sha256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
    )
    expectInvalid("FixAction.file.asset") {
      try action.validate()
    }
  }

  @Test func rejectsPathWithDot() throws {
    let action = FixAction.file(
      asset: "file/./name.txt",
      destination: "{gameRoot}/file.txt",
      sha256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
    )
    expectInvalid("FixAction.file.asset") {
      try action.validate()
    }
  }

  // MARK: - SHA256 validation tests
  @Test func rejectsBadSha256Checksum() throws {
    let action = FixAction.file(
      asset: "asset.txt",
      destination: "{gameRoot}/file.txt",
      sha256: "toolong" + String(repeating: "0", count: 64)
    )
    expectInvalid("FixAction.file.sha256") {
      try action.validate()
    }
  }

  @Test func rejectsSha256WithInvalidChars() throws {
    let action = FixAction.file(
      asset: "asset.txt",
      destination: "{gameRoot}/file.txt",
      sha256: "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
    )
    expectInvalid("FixAction.file.sha256") {
      try action.validate()
    }
  }

  // MARK: - Port validation tests
  @Test func rejectsOutOfRangePort() throws {
    let readiness = Readiness(
      log: "test.log",
      startMarker: nil,
      events: [],
      ports: [0],
      timeoutSeconds: 10
    )
    expectInvalid("Readiness.ports") {
      try readiness.validate()
    }
  }

  @Test func rejectsTooManyPorts() throws {
    let readiness = Readiness(
      log: "test.log",
      startMarker: nil,
      events: [],
      ports: [1, 2, 3, 4, 5],
      timeoutSeconds: 10
    )
    expectInvalid("Readiness.ports") {
      try readiness.validate()
    }
  }

  // MARK: - Placeholder validation tests
  @Test func rejectsBogusPlaceholder() throws {
    let action = FixAction.registry(
      hive: "user",
      key: "Software\\Test",
      name: "value",
      type: "string",
      value: "{bogusPlaceholder}"
    )
    expectInvalid("placeholder") {
      try action.validate()
    }
  }

  @Test func rejectsUnbalancedBraces() throws {
    let action = FixAction.registry(
      hive: "user",
      key: "Software\\Test",
      name: "value",
      type: "string",
      value: "{prefix"
    )
    expectInvalid("braces") {
      try action.validate()
    }
  }

  // MARK: - Renderer validation tests
  @Test func rejectsInvalidRendererBackend() throws {
    let action = FixAction.renderer(exe: "*", api: "d3d9", backend: "gptk")
    expectInvalid("backend") {
      try action.validate()
    }
  }

  // MARK: - DWORD validation tests
  @Test func rejectsDwordOverflow() throws {
    let action = FixAction.registry(
      hive: "user",
      key: "Software\\Test",
      name: "value",
      type: "dword",
      value: "0x1FFFFFFFF"
    )
    expectInvalid("registry.value") {
      try action.validate()
    }
  }

  @Test func rejectsDwordOutOfRange() throws {
    let action = FixAction.registry(
      hive: "user",
      key: "Software\\Test",
      name: "value",
      type: "dword",
      value: "99999999999"
    )
    expectInvalid("registry.value") {
      try action.validate()
    }
  }

  // MARK: - Parameter binding tests
  @Test func rejectsParameterBindsIndexOutOfRange() throws {
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: [.sidecar(enabled: true)],
      parameters: [
        FixParameter(
          id: "param",
          title: "Param",
          type: .bool,
          defaultValue: "true",
          binds: "actions[5].enabled"
        )
      ]
    )
    expectInvalid("FixParameter.binds") {
      try fix.validate()
    }
  }

  @Test func rejectsParameterBindsUnbindableField() throws {
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: [.sidecar(enabled: true)],
      parameters: [
        FixParameter(
          id: "param",
          title: "Param",
          type: .bool,
          defaultValue: "true",
          binds: "actions[0].unbindableField"
        )
      ]
    )
    expectInvalid("FixParameter.binds") {
      try fix.validate()
    }
  }

  // MARK: - Fix evidence tests
  @Test func rejectsVerifiedFixWithoutEvidence() throws {
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .verified,
      evidence: [],
      appliesWhen: .all([]),
      requires: [],
      actions: [.sidecar(enabled: true)]
    )
    expectInvalid("evidence") {
      try fix.validate()
    }
  }

  @Test func rejectsRejectedFixWithoutEvidence() throws {
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .rejected,
      evidence: [],
      appliesWhen: .all([]),
      requires: [],
      actions: [.sidecar(enabled: true)]
    )
    expectInvalid("evidence") {
      try fix.validate()
    }
  }

  // MARK: - Provider recipe tests
  @Test func rejectsProviderRecipeWithoutStop() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test",
      kind: .provider,
      title: "Test",
      status: .unverified,
      provider: .ea,
      launch: Launch(method: .provider)
    )
    expectInvalid("stop") {
      try recipe.validate()
    }
  }

  @Test func rejectsProviderRecipeWithoutReadiness() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test",
      kind: .provider,
      title: "Test",
      status: .unverified,
      provider: .ea,
      launch: Launch(method: .provider),
      stop: Stop(taskkill: ["test.exe"])
    )
    expectInvalid("readiness") {
      try recipe.validate()
    }
  }

  @Test func rejectsProviderRecipeWithoutExecutable() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test",
      kind: .provider,
      title: "Test",
      status: .unverified,
      provider: .ea,
      launch: Launch(method: .provider),
      stop: Stop(taskkill: ["test.exe"]),
      readiness: Readiness(log: "test.log", startMarker: nil, events: [], ports: [8080], timeoutSeconds: 10)
    )
    expectInvalid("executable") {
      try recipe.validate()
    }
  }

  // MARK: - URL template tests
  @Test func rejectsHttpUrlTemplate() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test",
      kind: .game,
      title: "Test",
      status: .unverified,
      launch: Launch(
        method: .browser,
        urlTemplate: "http://example.com"
      )
    )
    expectInvalid("urlTemplate") {
      try recipe.validate()
    }
  }

  // MARK: - Windows path tests
  @Test func rejectsRelativeWindowsPath() throws {
    let location = Location.windowsPath(path: "C:relative\\path")
    expectInvalid("Location.windowsPath") {
      try location.validate()
    }
  }

  @Test func rejectsWindowsPathWithDotDot() throws {
    let location = Location.windowsPath(path: "C:\\Program Files\\..\\test")
    expectInvalid("Location.windowsPath") {
      try location.validate()
    }
  }

  @Test func acceptsWindowsPathWithCDrive() throws {
    let location = Location.windowsPath(path: "C:\\Program Files\\x")
    try location.validate()
  }

  @Test func acceptsWindowsPathWithEDrive() throws {
    let location = Location.windowsPath(path: "E:\\EA Games")
    try location.validate()
  }

  @Test func acceptsWindowsPathWithZDrive() throws {
    let location = Location.windowsPath(path: "Z:\\Volumes\\ExT2\\Steam")
    try location.validate()
  }

  @Test func acceptsWindowsPathWithCDriveMinimal() throws {
    let location = Location.windowsPath(path: "C:\\")
    try location.validate()
  }

  @Test func rejectsWindowsPathWithADrive() throws {
    let location = Location.windowsPath(path: "A:\\x")
    expectInvalid("Location.windowsPath") {
      try location.validate()
    }
  }

  // MARK: - Registry key tests
  @Test func rejectsRegistryKeyInUserHiveWithSystem() throws {
    let location = Location.registry(
      hive: "user",
      key: "System\\CurrentControlSet\\Control\\Session Manager\\Environment",
      name: "test"
    )
    expectInvalid("Location.registry") {
      try location.validate()
    }
  }

  // MARK: - Host path tests
  @Test func rejectsHostPathWithDotDot() throws {
    let location = Location.hostPath(path: "/some/../path")
    expectInvalid("Location.hostPath") {
      try location.validate()
    }
  }

  @Test func rejectsRelativeHostPath() throws {
    let location = Location.hostPath(path: "relative/path")
    expectInvalid("Location.hostPath") {
      try location.validate()
    }
  }

  // MARK: - Condition count tests
  @Test func rejectsTooManyConditions() throws {
    var conditions = [Condition]()
    for _ in 0..<17 {
      conditions.append(Condition(kind: .provider, value: "ea"))
    }
    let predicate = Predicate.all(conditions)
    expectInvalid("Predicate") {
      try predicate.validate()
    }
  }

  @Test func rejectsZeroConditions() throws {
    let predicate = Predicate.all([])
    expectInvalid("Predicate") {
      try predicate.validate()
    }
  }

  // MARK: - Action count tests
  @Test func rejectsTooManyActions() throws {
    var actions = [FixAction]()
    for _ in 0..<33 {
      actions.append(.sidecar(enabled: true))
    }
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: actions
    )
    expectInvalid("Fix.actions") {
      try fix.validate()
    }
  }

  @Test func rejectsZeroActions() throws {
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: []
    )
    expectInvalid("Fix.actions") {
      try fix.validate()
    }
  }

  // MARK: - Evidence count tests
  @Test func rejectsTooManyEvidence() throws {
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: Array(repeating: "evidence", count: 9),
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: [.sidecar(enabled: true)]
    )
    expectInvalid("Fix.evidence") {
      try fix.validate()
    }
  }

  // MARK: - Window mode tests
  @Test func rejectsWindowModeWithoutSize() throws {
    let action = FixAction.window(mode: "virtualDesktop", size: nil, enabled: nil)
    expectInvalid("FixAction.window") {
      try action.validate()
    }
  }

  @Test func rejectsRetinaWithSize() throws {
    let action = FixAction.window(mode: "retina", size: "1920x1080", enabled: true)
    expectInvalid("FixAction.window") {
      try action.validate()
    }
  }

  @Test func rejectsRetinaWithoutEnabled() throws {
    let action = FixAction.window(mode: "retina", size: nil, enabled: nil)
    expectInvalid("FixAction.window") {
      try action.validate()
    }
  }

  // MARK: - B3 mutations: comprehensive field validation

  // Environment name with newline
  @Test func rejectsEnvNameWithNewline() throws {
    let action = FixAction.env(name: "TEST\nVAR", value: "val", scope: .session)
    expectInvalid("env.name") {
      try action.validate()
    }
  }

  // Drive letter validation
  @Test func rejectsDriveLetterInvalid() throws {
    let action = FixAction.drive(letter: "a", target: "{hubRoot}")
    expectInvalid("drive.letter") {
      try action.validate()
    }
  }

  @Test func rejectsDriveLetterZ() throws {
    let action = FixAction.drive(letter: "z", target: "{hubRoot}")
    expectInvalid("drive.letter") {
      try action.validate()
    }
  }

  // DWORD validation
  @Test func rejectsDwordWithLeadingPlus() throws {
    let action = FixAction.registry(hive: "user", key: "Software\\Test", name: "val", type: "dword", value: "+5")
    expectInvalid("registry.value") {
      try action.validate()
    }
  }

  // DLL validation
  @Test func rejectsDllOverrideInvalid() throws {
    let action = FixAction.dllOverride(exe: "*", dll: "d3d9", mode: "invalid_mode")
    expectInvalid("dllOverride") {
      try action.validate()
    }
  }

  // Patch ID validation (not 4 digits)
  @Test func rejectsPatchIdTooShort() throws {
    let patch = Patch(id: "001", title: "Test", capability: .dxmtDXGI, ref: "ref", commit: "abc1234", status: .experimental)
    expectInvalid("Patch.id") {
      try patch.validate()
    }
  }

  @Test func rejectsPatchIdWithLetters() throws {
    let patch = Patch(id: "00ab", title: "Test", capability: .dxmtDXGI, ref: "ref", commit: "abc1234", status: .experimental)
    expectInvalid("Patch.id") {
      try patch.validate()
    }
  }

  // Steam App ID (must be decimal digits)
  @Test func rejectsSteamAppIdWithHex() throws {
    let storeIds = StoreIDs(steamAppID: "0x123")
    expectInvalid("steamAppID") {
      try storeIds.validate()
    }
  }

  // Destination path: double slash after prefix/drive_c/
  @Test func rejectsDestinationWithDoubleSlash() throws {
    let action = FixAction.file(asset: "test.txt", destination: "{prefix}/drive_c//x", sha256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
    expectInvalid("destination") {
      try action.validate()
    }
  }

  // Destination path: control character in path
  @Test func rejectsDestinationWithControlChar() throws {
    let action = FixAction.file(asset: "test.txt", destination: "{prefix}/drive_c/\u{0001}x", sha256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
    expectInvalid("destination") {
      try action.validate()
    }
  }

  // Destination path: normal path should be accepted
  @Test func acceptsDestinationNormal() throws {
    let action = FixAction.file(asset: "test.txt", destination: "{prefix}/drive_c/a", sha256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
    try action.validate()
  }

  // Unknown nested keys in Condition
  @Test func rejectsUnknownKeyInCondition() throws {
    let json = """
    {
      "id": "test",
      "title": "Test",
      "when": {"all": [{"kind": "provider", "value": "ea", "unknown": "key"}]},
      "propose": {"fixes": []}
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(ProposalRule.self, from: data)
    }
  }

  // Unknown key in Readiness
  @Test func rejectsUnknownKeyInReadiness() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified",
      "launch": {"method": "direct", "arguments": []},
      "readiness": {"log": "test.log", "ports": [8080], "events": [], "timeoutSeconds": 10, "unknown": "key"}
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // Unknown key in ReadinessEvent
  @Test func rejectsUnknownKeyInReadinessEvent() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified",
      "launch": {"method": "direct", "arguments": []},
      "readiness": {"log": "test.log", "ports": [8080], "events": [{"state": "ready", "unknown": "key"}], "timeoutSeconds": 10}
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // Unknown key in Location (windowsPath variant)
  @Test func rejectsUnknownKeyInLocationWindowsPath() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified",
      "launch": {"method": "direct", "arguments": []},
      "location": {"kind": "windowsPath", "path": "C:\\\\test", "unknown": "key"}
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // Unknown key in FixAction (env variant)
  @Test func rejectsUnknownKeyInFixActionEnv() throws {
    let json = """
    {
      "id": "test",
      "title": "Test",
      "reason": "Test",
      "status": "experimental",
      "evidence": [],
      "appliesWhen": {"all": [{"kind": "provider", "value": "ea"}]},
      "requires": [],
      "actions": [{"kind": "env", "name": "TEST", "value": "v", "scope": "session", "unknown": "key"}]
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Fix.self, from: data)
    }
  }

  // Unknown key in Stop
  @Test func rejectsUnknownKeyInStop() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified",
      "launch": {"method": "direct", "arguments": []},
      "stop": {"taskkill": ["test.exe"], "unknown": "key"}
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // Unknown key in Install
  @Test func rejectsUnknownKeyInInstall() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified",
      "launch": {"method": "direct", "arguments": []},
      "install": {"url": "https://example.com/file.exe", "command": ["arg"], "unknown": "key"}
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // Unknown key in Checksum
  @Test func rejectsUnknownKeyInChecksum() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified",
      "launch": {"method": "direct", "arguments": []},
      "install": {
        "url": "https://example.com/file.exe",
        "page": "https://example.com/page.html",
        "command": ["arg"],
        "checksum": {"kind": "pinned", "sha256": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", "unknown": "key"}
      }
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // Unknown key in StoreIDs
  @Test func rejectsUnknownKeyInStoreIDs() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified",
      "launch": {"method": "direct", "arguments": []},
      "ids": {"steamAppID": "123", "unknown": "key"}
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // Unknown key in Setting
  @Test func rejectsUnknownKeyInSetting() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified",
      "launch": {"method": "direct", "arguments": []},
      "settings": [{"id": "s1", "title": "S1", "group": "g1", "type": "bool", "store": "hub", "unknown": "key"}]
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // Unknown key in RuntimeManifest
  @Test func rejectsUnknownKeyInRuntimeManifest() throws {
    let json = """
    {
      "id": "hub-0",
      "title": "Hub Runtime",
      "wineVersion": "wine-0011",
      "source": {"origin": "github", "revision": "abc123", "patchSeries": []},
      "manifestSHA256": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
      "keyFiles": {"system.reg": "fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321"},
      "unknown": "key"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(RuntimeManifest.self, from: data)
    }
  }

  // Unknown key in Patch
  @Test func rejectsUnknownKeyInPatch() throws {
    let json = """
    {
      "id": "0001",
      "title": "Patch",
      "capability": "cap",
      "ref": "branch",
      "commit": "abc1234",
      "status": "experimental",
      "unknown": "key"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Patch.self, from: data)
    }
  }

  // Unknown key in Knob
  @Test func rejectsUnknownKeyInKnob() throws {
    let json = """
    {
      "name": "TEST_VAR",
      "scopes": ["session"],
      "reason": "Test",
      "unknown": "key"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Knob.self, from: data)
    }
  }

  // Unknown key in Prerequisite
  @Test func rejectsUnknownKeyInPrerequisite() throws {
    let json = """
    {
      "id": "p1",
      "title": "Prereq",
      "url": "https://example.com/file.msi",
      "sha256": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
      "kind": "msi",
      "arch": "both",
      "unknown": "key"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Prerequisite.self, from: data)
    }
  }

  // Unknown key in ProposalRule
  @Test func rejectsUnknownKeyInProposalRule() throws {
    let json = """
    {
      "id": "rule",
      "when": {"all": [{"kind": "provider", "value": "ea"}]},
      "propose": {"fixes": []},
      "unknown": "key"
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(ProposalRule.self, from: data)
    }
  }

  // Reason field with tab
  @Test func rejectsReasonWithTab() throws {
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "reason:\t",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: [.sidecar(enabled: true)]
    )
    expectInvalid("reason") {
      try fix.validate()
    }
  }

  // Long whitespace text
  @Test func rejectsLongWhitespaceText() throws {
    let longText = String(repeating: " ", count: 513)
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: longText,
      status: .experimental,
      evidence: [],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: [.sidecar(enabled: true)]
    )
    expectInvalid("reason") {
      try fix.validate()
    }
  }

  // Evidence: file:../x (relative path)
  @Test func rejectsEvidenceFileRelativePath() throws {
    let evidence = CapabilityEvidence(id: .dxmtDXGI, evidence: "file:../x")
    expectInvalid("evidence") {
      try evidence.validate()
    }
  }

  // Evidence: file:/abs (absolute path)
  @Test func rejectsEvidenceFileAbsolutePath() throws {
    let evidence = CapabilityEvidence(id: .dxmtDXGI, evidence: "file:/abs/path")
    expectInvalid("evidence") {
      try evidence.validate()
    }
  }

  // Evidence: knob:FOO@../x (relative path in knob evidence)
  @Test func rejectsEvidenceKnobRelativePath() throws {
    let evidence = CapabilityEvidence(id: .dxmtDXGI, evidence: "knob:WINE_TEST@../x")
    expectInvalid("evidence") {
      try evidence.validate()
    }
  }

  // Registry Setting key with backslash (Windows\x pattern)
  @Test func rejectsRegistrySettingKeyWindowsBackslash() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified",
      "launch": {"method": "direct", "arguments": []},
      "settings": [{
        "id": "s1",
        "title": "S1",
        "group": "g1",
        "type": "string",
        "store": "registry",
        "defaultValue": "default",
        "key": "Software\\\\Windows\\\\Test",
        "section": "value"
      }]
    }
    """
    let data = json.data(using: .utf8)!
    expectInvalid("unknown key") {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // Machine registry root: key ending with EnvironmentX instead of Environment
  @Test func rejectsRegistryKeyMachineMisaligned() throws {
    let location = Location.registry(
      hive: "machine",
      key: "System\\CurrentControlSet\\Control\\Session Manager\\EnvironmentX",
      name: "TEST"
    )
    expectInvalid("registry") {
      try location.validate()
    }
  }

  // Game recipe method provider without provider field
  @Test func rejectsGameRecipeMethodProviderWithoutProvider() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test",
      kind: .game,
      title: "Test",
      status: .unverified,
      launch: Launch(method: .provider)
    )
    expectInvalid("launch method provider") {
      try recipe.validate()
    }
  }

  // Provider recipe with method direct and complete fields (should pass)
  @Test func acceptsProviderRecipeMethodDirect() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test",
      kind: .provider,
      title: "Test",
      status: .unverified,
      provider: .ea,
      executable: "test.exe",
      launch: Launch(method: .direct, arguments: []),
      stop: Stop(taskkill: ["test.exe"]),
      readiness: Readiness(
        log: "{prefix}/drive_c/x.log",
        startMarker: nil,
        events: [],
        ports: [],
        timeoutSeconds: 60
      )
    )
    try recipe.validate()
  }

  // Condition.imports validation: invalid format with dot
  @Test func rejectsConditionImportsWithDot() throws {
    let predicate = Predicate.all([Condition(kind: .imports, value: "a.b")])
    expectInvalid("Condition.imports: invalid format") {
      try predicate.validate()
    }
  }

  // Condition.imports validation: valid cases (d3d9 and d3d9.dll)
  @Test func acceptsConditionImportsValidCases() throws {
    let predicate1 = Predicate.all([Condition(kind: .imports, value: "d3d9")])
    try predicate1.validate()

    let predicate2 = Predicate.all([Condition(kind: .imports, value: "d3d9.dll")])
    try predicate2.validate()
  }

  // Location.windowsPath validation: may not contain .. component
  @Test func rejectsLocationWindowsPathWithDotDot() throws {
    let location = Location.windowsPath(path: "C:\\a/../b")
    expectInvalid("Location.windowsPath: may not contain .. component") {
      try location.validate()
    }
  }

  // Location.hostPath validation: may not contain control characters
  @Test func rejectsLocationHostPathWithControlChar() throws {
    let location = Location.hostPath(path: "/a\u{1}b")
    expectInvalid("Location.hostPath: may not contain control characters") {
      try location.validate()
    }
  }

  // Location.registry validation: value name with quote
  @Test func rejectsLocationRegistryNameWithQuote() throws {
    let location = Location.registry(hive: "user", key: "Software\\Test", name: "a\"b")
    expectInvalid("Location.registry.name: invalid character") {
      try location.validate()
    }
  }

  // Stop.arguments validation: unknown placeholder
  @Test func rejectsStopArgumentsUnknownPlaceholder() throws {
    let stop = Stop(arguments: ["{bogus}"], taskkill: ["test.exe"])
    expectInvalid("Stop.arguments[0]: unknown placeholder bogus") {
      try stop.validate()
    }
  }

  // FixParameter.choices validation: control character in choice
  @Test func rejectsFixParameterChoicesWithControlChar() throws {
    let param = FixParameter(
      id: "test",
      title: "Test",
      type: .choice,
      defaultValue: "a\u{1}",
      choices: ["a\u{1}", "b"],
      binds: "actions[0].value"
    )
    expectInvalid("FixParameter.choices: may not contain control characters") {
      try param.validate(actionCount: 1)
    }
  }

  // Setting.defaultValue validation: int type with float value
  @Test func rejectsSettingIntDefaultFloat() throws {
    let setting = Setting(
      id: "test",
      title: "Test",
      group: "Test",
      store: .ini,
      file: "{gameRoot}/test.ini",
      section: "Section",
      key: "Key",
      type: .int,
      defaultValue: "1.5",
      range: [0, 10]
    )
    expectInvalid("Setting.defaultValue: must be a valid integer") {
      try setting.validate()
    }
  }

  // FixAction.drive validation: letter D (uppercase, invalid)
  @Test func rejectsFixActionDriveLetterUppercaseD() throws {
    let action = FixAction.drive(letter: "D", target: "{hubRoot}")
    expectInvalid("FixAction.drive.letter: must be d-y") {
      try action.validate()
    }
  }

  // FixAction.env validation: name with newline
  @Test func rejectsFixActionEnvNameWithNewline() throws {
    let action = FixAction.env(name: "FOO_BAR\n", value: "test", scope: .session)
    expectInvalid("FixAction.env.name: must match") {
      try action.validate()
    }
  }

  // FixAction.registry validation: dword with newline in hex
  @Test func rejectsFixActionDwordHexWithNewline() throws {
    let action = FixAction.registry(hive: "machine", key: "Software\\Test", name: "Value", type: "dword", value: "0xFF\n")
    expectInvalid("FixAction.registry.value: invalid hex") {
      try action.validate()
    }
  }

  // urlTemplate validation: /bin/sh (no colon)
  @Test func rejectsUrlTemplateNoColon() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test",
      kind: .game,
      title: "Test",
      status: .unverified,
      launch: Launch(method: .browser, urlTemplate: "/bin/sh")
    )
    expectInvalid("urlTemplate") {
      try recipe.validate()
    }
  }

  // urlTemplate validation: steam://x\n (with newline)
  @Test func rejectsUrlTemplateWithNewline() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test",
      kind: .game,
      title: "Test",
      status: .unverified,
      launch: Launch(method: .browser, urlTemplate: "steam://x\n")
    )
    expectInvalid("urlTemplate") {
      try recipe.validate()
    }
  }

  // ReadinessEvent state: running (not in allowed set)
  @Test func rejectsReadinessEventStateRunning() throws {
    let event = ReadinessEvent(state: .running, contains: "text", log: nil)
    expectInvalid("ReadinessEvent.state") {
      try event.validate()
    }
  }

  // Parameter binds: actions[0].size on env (size not bindable)
  @Test func rejectsBindsUnbindableFieldSize() throws {
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: [.env(name: "TEST", value: "val", scope: .session)],
      parameters: [
        FixParameter(
          id: "p",
          title: "P",
          type: .bool,
          defaultValue: "true",
          binds: "actions[0].size"
        )
      ]
    )
    expectInvalid("binds") {
      try fix.validate()
    }
  }

  // Parameter binds: .value on sidecar (sidecar doesn't have value)
  @Test func rejectsBindsInvalidFieldSidecar() throws {
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: [.sidecar(enabled: true)],
      parameters: [
        FixParameter(
          id: "p",
          title: "P",
          type: .bool,
          defaultValue: "true",
          binds: "actions[0].value"
        )
      ]
    )
    expectInvalid("binds") {
      try fix.validate()
    }
  }

  // DWORD with leading plus
  @Test func rejectsDwordLeadingPlus() throws {
    let action = FixAction.registry(hive: "user", key: "Software\\Test", name: "val", type: "dword", value: "+5")
    expectInvalid("registry.value") {
      try action.validate()
    }
  }

  // Int parameter default: 1.5 (not a valid int)
  @Test func rejectsIntParameterDefaultFloat() throws {
    let param = FixParameter(
      id: "p",
      title: "P",
      type: .int,
      defaultValue: "1.5",
      range: [-10, 10],
      binds: "actions[0].enabled"
    )
    let fix = Fix(
      id: "test",
      title: "Test",
      reason: "Test",
      status: .experimental,
      evidence: [],
      appliesWhen: .all([Condition(kind: .provider, value: "ea")]),
      requires: [],
      actions: [.sidecar(enabled: true)],
      parameters: [param]
    )
    expectInvalid("defaultValue") {
      try fix.validate()
    }
  }

  // Path: C:\a/../b (relative .. in windows path)
  @Test func rejectsWindowsPathWithDotDotComponent() throws {
    let location = Location.windowsPath(path: "C:\\a\\..\\b")
    expectInvalid("windowsPath") {
      try location.validate()
    }
  }

  // Relative path with backslash
  @Test func rejectsRelativePathWithBackslash() throws {
    let action = FixAction.file(
      asset: "test\\file.txt",
      destination: "{gameRoot}/file.txt",
      sha256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
    )
    expectInvalid("asset") {
      try action.validate()
    }
  }

  // Relative path with colon
  @Test func rejectsRelativePathWithColon() throws {
    let action = FixAction.file(
      asset: "test:file.txt",
      destination: "{gameRoot}/file.txt",
      sha256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
    )
    expectInvalid("asset") {
      try action.validate()
    }
  }

  // Missing required arrays
  @Test func acceptsReadinessWithEmptyPorts() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test",
      kind: .provider,
      title: "Test",
      status: .unverified,
      provider: .ea,
      executable: "test.exe",
      launch: Launch(method: .provider),
      stop: Stop(taskkill: ["test.exe"]),
      readiness: Readiness(log: "test.log", startMarker: nil, events: [], ports: [], timeoutSeconds: 10)
    )
    try recipe.validate()
  }

  @Test func rejectsReadinessJsonWithoutPorts() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "provider",
      "title": "Test",
      "status": "unverified",
      "provider": "ea",
      "executable": "test.exe",
      "launch": {"method": "provider", "arguments": []},
      "stop": {"taskkill": ["test.exe"]},
      "readiness": {"log": "test.log", "startMarker": null, "events": [], "timeoutSeconds": 10}
    }
    """
    let data = json.data(using: .utf8)!
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  @Test func rejectsRecipeWithoutLaunch() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "test",
      "kind": "game",
      "title": "Test",
      "status": "unverified"
    }
    """
    let data = json.data(using: .utf8)!
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(Recipe.self, from: data)
    }
  }

  // MARK: - B4: Round-trip tests
  @Test func roundTripRecipe() throws {
    let recipe = Recipe(
      schemaVersion: 1,
      id: "test-recipe",
      kind: .game,
      title: "Test Recipe",
      status: .verified,
      evidence: ["evidence"],
      launch: Launch(method: .direct, arguments: ["arg1"])
    )
    try recipe.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let encoded = try encoder.encode(recipe)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(Recipe.self, from: encoded)
    try decoded.validate()
    #expect(decoded.id == recipe.id)
    #expect(decoded.kind == recipe.kind)
  }

  @Test func roundTripReadiness() throws {
    let readiness = Readiness(
      log: "test.log",
      startMarker: "Started",
      events: [ReadinessEvent(state: .ready, contains: "ready", log: nil)],
      ports: [8080],
      timeoutSeconds: 30
    )
    try readiness.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let encoded = try encoder.encode(readiness)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(Readiness.self, from: encoded)
    try decoded.validate()
    #expect(decoded.log == readiness.log)
    #expect(decoded.ports == readiness.ports)
  }

  @Test func roundTripLocation() throws {
    let location = Location.windowsPath(path: "d:\\Program Files\\Game")
    try location.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let encoded = try encoder.encode(location)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(Location.self, from: encoded)
    try decoded.validate()
    if case let .windowsPath(path: decodedPath) = decoded {
      #expect(decodedPath == "d:\\Program Files\\Game")
    } else {
      Issue.record("Location kind mismatch")
    }
  }

  @Test func roundTripCondition() throws {
    let condition = Condition(kind: .provider, value: "ea")
    try condition.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let encoded = try encoder.encode(condition)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(Condition.self, from: encoded)
    try decoded.validate()
    #expect(decoded.kind == condition.kind)
    #expect(decoded.value == condition.value)
  }

  // MARK: - B4: Predicate.matches table
  @Test func predicateMatchesMarker() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(["marker1"]),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.all([Condition(kind: .marker, value: "marker1")])
    #expect(predicate.matches(facts))
  }

  @Test func predicateMatchesRuntimeHas() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set([.dxmtDXGI])
    )
    let predicate = Predicate.all([Condition(kind: .runtimeHas, value: "dxmtDXGI")])
    #expect(predicate.matches(facts))
  }

  @Test func predicateMatchesTarget() throws {
    let facts = TargetFacts(
      targetID: "game123",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.all([Condition(kind: .target, value: "game123")])
    #expect(predicate.matches(facts))
  }

  @Test func predicateMatchesSubsystem() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: "console",
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.all([Condition(kind: .subsystem, value: "console")])
    #expect(predicate.matches(facts))
  }

  @Test func predicateMatchesShaEqual() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: "abc123",
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.all([Condition(kind: .exeSHA256, value: "abc123")])
    #expect(predicate.matches(facts))
  }

  @Test func predicateAnyFalse() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.any([
      Condition(kind: .provider, value: "steam"),
      Condition(kind: .provider, value: "epic")
    ])
    #expect(!predicate.matches(facts))
  }

  @Test func predicateAllPartialFail() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: "game.exe",
      exeSHA256: nil,
      machine: "x86_64",
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.all([
      Condition(kind: .exe, value: "game.exe"),
      Condition(kind: .machine, value: "i386")
    ])
    #expect(!predicate.matches(facts))
  }

  @Test func predicateEmptyListFalse() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.all([])
    #expect(!predicate.matches(facts))
  }

  @Test func predicateNilFactFalse() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.all([Condition(kind: .exeSHA256, value: "abc")])
    #expect(!predicate.matches(facts))
  }

  // Additional predicate.matches rows
  @Test func predicateMatchesMachine() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: "x86_64",
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.all([Condition(kind: .machine, value: "x86_64")])
    #expect(predicate.matches(facts))
  }

  @Test func predicateMatchesProvider() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .steam,
      runtime: Set()
    )
    let predicate = Predicate.all([Condition(kind: .provider, value: "steam")])
    #expect(predicate.matches(facts))
  }

  @Test func predicateMatchesImports() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(["d3d11"]),
      markers: Set(),
      provider: .none,
      runtime: Set()
    )
    let predicate = Predicate.all([Condition(kind: .imports, value: "d3d11")])
    #expect(predicate.matches(facts))
  }

  @Test func predicateAnyMatches() throws {
    let facts = TargetFacts(
      targetID: "test",
      exe: nil,
      exeSHA256: nil,
      machine: nil,
      subsystem: nil,
      imports: Set(),
      markers: Set(),
      provider: .steam,
      runtime: Set()
    )
    let predicate = Predicate.any([
      Condition(kind: .provider, value: "ea"),
      Condition(kind: .provider, value: "steam")
    ])
    #expect(predicate.matches(facts))
  }
}
