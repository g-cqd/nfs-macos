import Foundation

// MARK: - Foundational Enums

/// A capability the runtime provides.
package enum Capability: String, Codable, Sendable, CaseIterable {
  case trapFlagEmulation
  case rosettaRwxWxEmulation
  case rosettaRwxWxPageLog
  case crashContextBlock
  case crashContextCodeWindows
  case rosettaPageExperiments
  case x87Sidecar
  case dxmtDXGI
  case compatdb
  case wined3dDXGI
  case mtld3dD3D9
  case mtld3dD3D8
  case dsoundSSE2
  case caseFoldCache
  case exeListSwitches
}

/// A game provider.
package enum ProviderID: String, Codable, Sendable, CaseIterable {
  case ea
  case steam
  case epic
  case ubisoft
  case none
}

/// One condition in a predicate.
package struct Condition: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case exe
    case exeSHA256
    case machine
    case imports
    case subsystem
    case marker
    case provider
    case runtimeHas
    case target
    case always
  }

  package let kind: Kind
  package let value: String

  package init(kind: Kind, value: String) {
    self.kind = kind
    self.value = value
  }

  /// Validates this condition's value against its kind.
  package func validate() throws(HubError) {
    switch kind.rawValue {
    case "exe":
      try Check.exe(value, field: "Condition.exe")
    case "exeSHA256":
      try Check.sha256(value, field: "Condition.exeSHA256")
    case "machine":
      guard value == "i386" || value == "x86_64" else {
        throw HubError.invalid("Condition.machine: must be i386 or x86_64")
      }
    case "imports":
      // Strip optional ".dll" suffix (case-insensitive)
      var base = value
      if value.lowercased().hasSuffix(".dll") {
        base = String(value.dropLast(4))
      }
      // Validate: 1...40 bytes of [a-z0-9_] only
      guard Check.ascii(base, 1...40, first: { b in
        (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x5f
      }, rest: { b in
        (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x5f
      }) else {
        throw HubError.invalid("Condition.imports: invalid format")
      }
    case "subsystem":
      guard value == "gui" || value == "console" else {
        throw HubError.invalid("Condition.subsystem: must be gui or console")
      }
    case "marker":
      try Check.relativePath(value, field: "Condition.marker")
    case "provider":
      guard ProviderID(rawValue: value) != nil else {
        throw HubError.invalid("Condition.provider: unknown provider")
      }
    case "runtimeHas":
      guard Capability(rawValue: value) != nil else {
        throw HubError.invalid("Condition.runtimeHas: unknown capability")
      }
    case "target":
      try Check.id(value, field: "Condition.target")
    case "always":
      guard value == "" else {
        throw HubError.invalid("Condition.always: value must be empty string")
      }
    default:
      throw HubError.invalid("Condition.kind: unknown kind")
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(decoder, allowed: ["kind", "value"], type: "Condition")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.kind = try container.decode(Kind.self, forKey: AnyCodingKey(stringValue: "kind"))
    self.value = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "value"))
  }
}

/// A predicate: a logical combination of conditions.
package enum Predicate: Codable, Equatable, Sendable {
  case all([Condition])
  case any([Condition])

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let keys = container.allKeys.map { $0.stringValue }
    guard keys.count == 1 else {
      throw HubError.invalid("Predicate: must have exactly one key (all or any)")
    }

    if let key = keys.first {
      if key == "all" {
        let values = try container.decode([Condition].self, forKey: AnyCodingKey(stringValue: "all"))
        self = .all(values)
      } else if key == "any" {
        let values = try container.decode([Condition].self, forKey: AnyCodingKey(stringValue: "any"))
        self = .any(values)
      } else {
        throw HubError.invalid("Predicate: key must be 'all' or 'any'")
      }
    } else {
      throw HubError.invalid("Predicate: must have exactly one key")
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: AnyCodingKey.self)
    switch self {
    case .all(let conditions):
      try container.encode(conditions, forKey: AnyCodingKey(stringValue: "all"))
    case .any(let conditions):
      try container.encode(conditions, forKey: AnyCodingKey(stringValue: "any"))
    }
  }

  /// Validates this predicate.
  package func validate() throws(HubError) {
    let conditions = switch self {
    case .all(let c), .any(let c):
      c
    }
    guard (1...16).contains(conditions.count) else {
      throw HubError.invalid("Predicate: must have 1 to 16 conditions")
    }
    for condition in conditions {
      try condition.validate()
    }
  }

  /// Checks whether this predicate matches the given facts.
  package func matches(_ facts: TargetFacts) -> Bool {
    switch self {
    case .all(let conditions):
      guard !conditions.isEmpty else { return false }
      return conditions.allSatisfy { condition in
        conditionMatches(condition, facts: facts)
      }
    case .any(let conditions):
      guard !conditions.isEmpty else { return false }
      return conditions.contains { condition in
        conditionMatches(condition, facts: facts)
      }
    }
  }

  private func conditionMatches(_ condition: Condition, facts: TargetFacts) -> Bool {
    switch condition.kind.rawValue {
    case "exe":
      guard let exe = facts.exe else { return false }
      return exe.lowercased() == condition.value.lowercased()
    case "exeSHA256":
      guard let hash = facts.exeSHA256 else { return false }
      return hash == condition.value
    case "machine":
      guard let machine = facts.machine else { return false }
      return machine == condition.value
    case "imports":
      var condDll = condition.value.lowercased()
      if condDll.hasSuffix(".dll") {
        condDll = String(condDll.dropLast(4))
      }
      return facts.imports.contains { imp in
        var impDll = imp.lowercased()
        if impDll.hasSuffix(".dll") {
          impDll = String(impDll.dropLast(4))
        }
        return impDll == condDll
      }
    case "subsystem":
      guard let subsystem = facts.subsystem else { return false }
      return subsystem == condition.value
    case "marker":
      return facts.markers.contains(condition.value)
    case "provider":
      return facts.provider.rawValue == condition.value
    case "runtimeHas":
      return facts.runtime.contains { cap in cap.rawValue == condition.value }
    case "target":
      return facts.targetID == condition.value
    default:
      return false
    }
  }
}

/// Target facts for matching predicates.
package struct TargetFacts: Sendable, Equatable {
  package let targetID: String
  package let exe: String?
  package let exeSHA256: String?
  package let machine: String?
  package let subsystem: String?
  package let imports: Set<String>
  package let markers: Set<String>
  package let provider: ProviderID
  package let runtime: Set<Capability>

  package init(
    targetID: String, exe: String?, exeSHA256: String?, machine: String?,
    subsystem: String?, imports: Set<String>, markers: Set<String>,
    provider: ProviderID, runtime: Set<Capability>
  ) {
    self.targetID = targetID
    self.exe = exe
    self.exeSHA256 = exeSHA256
    self.machine = machine
    self.subsystem = subsystem
    self.imports = imports
    self.markers = markers
    self.provider = provider
    self.runtime = runtime
  }
}

// MARK: - Environment and Knob

/// Where an environment variable applies.
package enum EnvScope: String, Codable, Sendable, CaseIterable {
  case session
  case prefixMachine
}

/// An environment variable definition.
package struct Knob: Codable, Equatable, Sendable {
  package let name: String
  package let scopes: [EnvScope]
  package let reason: String

  package init(name: String, scopes: [EnvScope], reason: String) {
    self.name = name
    self.scopes = scopes
    self.reason = reason
  }

  /// Validates this knob.
  package func validate() throws(HubError) {
    guard Check.ascii(name, 2...64, first: { b in
      b >= 0x41 && b <= 0x5a  // A-Z
    }, rest: { b in
      (b >= 0x41 && b <= 0x5a) || (b >= 0x30 && b <= 0x39) || b == 0x5f  // A-Z, 0-9, _
    }) else {
      throw HubError.invalid("Knob.name: must match ^[A-Z][A-Z0-9_]{1,63}$")
    }
    guard !scopes.isEmpty else {
      throw HubError.invalid("Knob.scopes: must not be empty")
    }
    try Check.text(reason, field: "Knob.reason", max: 200)
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(decoder, allowed: ["name", "scopes", "reason"], type: "Knob")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.name = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "name"))
    self.scopes = try container.decode([EnvScope].self, forKey: AnyCodingKey(stringValue: "scopes"))
    self.reason = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "reason"))
  }
}

// MARK: - Prerequisite

/// An installable prerequisite.
package struct Prerequisite: Codable, Equatable, Sendable {
  package let id: String
  package let title: String
  package let url: String
  package let sha256: String
  package let kind: PrerequisiteKind
  package let arch: PrerequisiteArch

  package enum PrerequisiteKind: String, Codable, Sendable, CaseIterable {
    case msi
    case exe
  }

  package enum PrerequisiteArch: String, Codable, Sendable, CaseIterable {
    case i386
    case x86_64
    case both
  }

  package init(
    id: String, title: String, url: String, sha256: String, kind: PrerequisiteKind,
    arch: PrerequisiteArch
  ) {
    self.id = id
    self.title = title
    self.url = url
    self.sha256 = sha256
    self.kind = kind
    self.arch = arch
  }

  /// Validates this prerequisite.
  package func validate() throws(HubError) {
    try Check.id(id, field: "Prerequisite.id")
    try Check.text(title, field: "Prerequisite.title", max: .max)
    guard url.hasPrefix("https://") else {
      throw HubError.invalid("Prerequisite.url: must start with https://")
    }
    guard url.utf8.count <= 400 else {
      throw HubError.invalid("Prerequisite.url: must be at most 400 bytes")
    }
    for scalar in url.unicodeScalars {
      let v = scalar.value
      if (v >= 0x0000 && v <= 0x001f) || v == 0x007f || v == 0x20 {
        throw HubError.invalid("Prerequisite.url: may not contain control characters or spaces")
      }
    }
    try Check.sha256(sha256, field: "Prerequisite.sha256")
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["id", "title", "url", "sha256", "kind", "arch"], type: "Prerequisite")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id"))
    self.title = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "title"))
    self.url = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "url"))
    self.sha256 = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "sha256"))
    self.kind = try container.decode(
      PrerequisiteKind.self, forKey: AnyCodingKey(stringValue: "kind"))
    self.arch = try container.decode(
      PrerequisiteArch.self, forKey: AnyCodingKey(stringValue: "arch"))
  }
}

// MARK: - Readiness

/// A state a provider or game can be in.
package enum ProviderState: String, Codable, Sendable, CaseIterable {
  case notInstalled
  case stopped
  case starting
  case needsSignIn
  case ready
  case launching
  case running
  case stopping
  case failed
  case blocked
}

/// An event that indicates readiness progress.
package struct ReadinessEvent: Codable, Equatable, Sendable {
  package let state: ProviderState
  package let contains: String
  package let log: String?
  package let holdSeconds: Int?

  package init(state: ProviderState, contains: String, log: String?, holdSeconds: Int? = nil) {
    self.state = state
    self.contains = contains
    self.log = log
    self.holdSeconds = holdSeconds
  }

  /// Validates this readiness event.
  package func validate() throws(HubError) {
    let allowedStates: Set<ProviderState> = [.starting, .needsSignIn, .ready, .launching, .failed]
    guard allowedStates.contains(state) else {
      throw HubError.invalid("ReadinessEvent.state: must be starting, needsSignIn, ready, launching, or failed")
    }
    try Check.text(contains, field: "ReadinessEvent.contains", max: 200)
    if let log = log {
      try validateLog(log, field: "ReadinessEvent.log")
    }
    if let holdSeconds = holdSeconds {
      guard (0...600).contains(holdSeconds) else {
        throw HubError.invalid("ReadinessEvent.holdSeconds: must be 0 to 600")
      }
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["state", "contains", "log", "holdSeconds"], type: "ReadinessEvent")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.state = try container.decode(
      ProviderState.self, forKey: AnyCodingKey(stringValue: "state"))
    self.contains = try container.decode(
      String.self, forKey: AnyCodingKey(stringValue: "contains"))
    self.log = try container.decodeIfPresent(String.self, forKey: AnyCodingKey(stringValue: "log"))
    self.holdSeconds = try container.decodeIfPresent(
      Int.self, forKey: AnyCodingKey(stringValue: "holdSeconds"))
  }
}

/// Helper to validate logs that must start with {prefix}/ or {providerRoot}/ followed by a relative path.
package func validateLog(_ log: String, field: String) throws(HubError) {
  if log.hasPrefix("{prefix}/") {
    let rest = String(log.dropFirst(9))
    try Check.relativePath(rest, field: field)
  } else if log.hasPrefix("{providerRoot}/") {
    let rest = String(log.dropFirst(15))
    try Check.relativePath(rest, field: field)
  } else {
    throw HubError.invalid("\(field): must start with {prefix}/ or {providerRoot}/")
  }
}

/// Readiness configuration for a provider or game.
package struct Readiness: Codable, Equatable, Sendable {
  package let log: String
  package let startMarker: String?
  package let events: [ReadinessEvent]
  package let ports: [Int]
  package let timeoutSeconds: Int

  package init(
    log: String, startMarker: String?, events: [ReadinessEvent], ports: [Int],
    timeoutSeconds: Int
  ) {
    self.log = log
    self.startMarker = startMarker
    self.events = events
    self.ports = ports
    self.timeoutSeconds = timeoutSeconds
  }

  /// Validates this readiness configuration.
  package func validate() throws(HubError) {
    try validateLog(log, field: "Readiness.log")
    if let startMarker = startMarker {
      try Check.text(startMarker, field: "Readiness.startMarker", max: 200)
    }
    guard (0...16).contains(events.count) else {
      throw HubError.invalid("Readiness.events: must have 0 to 16 events")
    }
    for event in events {
      try event.validate()
    }
    guard (0...4).contains(ports.count) else {
      throw HubError.invalid("Readiness.ports: must have 0 to 4 ports")
    }
    for port in ports {
      guard (1...65535).contains(port) else {
        throw HubError.invalid("Readiness.ports: port must be 1 to 65535")
      }
    }
    guard (1...900).contains(timeoutSeconds) else {
      throw HubError.invalid("Readiness.timeoutSeconds: must be 1 to 900")
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["log", "startMarker", "events", "ports", "timeoutSeconds"],
      type: "Readiness")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.log = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "log"))
    self.startMarker = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "startMarker"))
    self.events = try container.decode(
      [ReadinessEvent].self, forKey: AnyCodingKey(stringValue: "events"))
    self.ports = try container.decode(
      [Int].self, forKey: AnyCodingKey(stringValue: "ports"))
    self.timeoutSeconds = try container.decode(
      Int.self, forKey: AnyCodingKey(stringValue: "timeoutSeconds"))
  }
}
