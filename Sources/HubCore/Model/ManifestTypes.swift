import Foundation

// MARK: - Runtime Manifest

/// Information about the runtime source.
package struct RuntimeSource: Codable, Equatable, Sendable {
  package let origin: String
  package let revision: String?
  package let patchSeries: [String]

  package init(origin: String, revision: String? = nil, patchSeries: [String] = []) {
    self.origin = origin
    self.revision = revision
    self.patchSeries = patchSeries
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["origin", "revision", "patchSeries"], type: "RuntimeSource")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.origin = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "origin"))
    self.revision = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "revision"))
    self.patchSeries = try container.decode(
      [String].self, forKey: AnyCodingKey(stringValue: "patchSeries"))
  }
}

/// Evidence for a capability.
package struct CapabilityEvidence: Codable, Equatable, Sendable {
  package let id: Capability
  package let evidence: String

  package init(id: Capability, evidence: String) {
    self.id = id
    self.evidence = evidence
  }

  /// Validates this capability evidence.
  package func validate() throws(HubError) {
    if evidence.hasPrefix("file:") {
      let path = String(evidence.dropFirst(5))
      try Check.relativePath(path, field: "CapabilityEvidence.evidence")
    } else if evidence.hasPrefix("knob:") {
      let rest = String(evidence.dropFirst(5))
      if let atIndex = rest.firstIndex(of: "@") {
        let knobName = String(rest[..<atIndex])
        let path = String(rest[rest.index(after: atIndex)...])
        guard Check.ascii(knobName, 2...64, first: { b in
          b >= 0x41 && b <= 0x5a  // A-Z
        }, rest: { b in
          (b >= 0x41 && b <= 0x5a) || (b >= 0x30 && b <= 0x39) || b == 0x5f  // A-Z, 0-9, _
        }) else {
          throw HubError.invalid("CapabilityEvidence.evidence: invalid knob name")
        }
        try Check.relativePath(path, field: "CapabilityEvidence.evidence")
      } else {
        throw HubError.invalid("CapabilityEvidence.evidence: knob format must have @")
      }
    } else if evidence.hasPrefix("doc:") {
      let text = String(evidence.dropFirst(4))
      guard text.utf8.count <= 200 else {
        throw HubError.invalid("CapabilityEvidence.evidence: doc text must be at most 200 bytes")
      }
    } else {
      throw HubError.invalid("CapabilityEvidence.evidence: must start with file:, knob:, or doc:")
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["id", "evidence"], type: "CapabilityEvidence")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.id = try container.decode(Capability.self, forKey: AnyCodingKey(stringValue: "id"))
    self.evidence = try container.decode(
      String.self, forKey: AnyCodingKey(stringValue: "evidence"))
  }
}

/// A helper binary.
package struct Helper: Codable, Equatable, Sendable {
  package let path: String
  package let sha256: String

  package init(path: String, sha256: String) {
    self.path = path
    self.sha256 = sha256
  }

  /// Validates this helper.
  package func validate() throws(HubError) {
    try Check.relativePath(path, field: "Helper.path")
    try Check.sha256(sha256, field: "Helper.sha256")
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["path", "sha256"], type: "Helper")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.path = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "path"))
    self.sha256 = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "sha256"))
  }
}

/// A runtime manifest.
package struct RuntimeManifest: Codable, Equatable, Sendable {
  package let id: String
  package let title: String
  package let wineVersion: String
  package let source: RuntimeSource
  package let manifestSHA256: String
  package let keyFiles: [String: String]
  package let capabilities: [CapabilityEvidence]
  package let helpers: [String: Helper]

  package init(
    id: String, title: String, wineVersion: String, source: RuntimeSource,
    manifestSHA256: String, keyFiles: [String: String], capabilities: [CapabilityEvidence],
    helpers: [String: Helper]
  ) {
    self.id = id
    self.title = title
    self.wineVersion = wineVersion
    self.source = source
    self.manifestSHA256 = manifestSHA256
    self.keyFiles = keyFiles
    self.capabilities = capabilities
    self.helpers = helpers
  }

  /// Validates this runtime manifest.
  package func validate() throws(HubError) {
    try Check.id(id, field: "RuntimeManifest.id")
    try Check.text(title, field: "RuntimeManifest.title", max: .max)
    try Check.text(wineVersion, field: "RuntimeManifest.wineVersion", max: .max)
    try Check.sha256(manifestSHA256, field: "RuntimeManifest.manifestSHA256")

    guard (1...64).contains(keyFiles.count) else {
      throw HubError.invalid("RuntimeManifest.keyFiles: must have 1 to 64 entries")
    }
    for (key, value) in keyFiles {
      try Check.relativePath(key, field: "RuntimeManifest.keyFiles key")
      try Check.sha256(value, field: "RuntimeManifest.keyFiles value")
    }

    for evidence in capabilities {
      try evidence.validate()
    }

    for (key, helper) in helpers {
      try Check.id(key, field: "RuntimeManifest.helpers key")
      try helper.validate()
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder,
      allowed: [
        "id", "title", "wineVersion", "source", "manifestSHA256", "keyFiles", "capabilities",
        "helpers"
      ],
      type: "RuntimeManifest")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id"))
    self.title = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "title"))
    self.wineVersion = try container.decode(
      String.self, forKey: AnyCodingKey(stringValue: "wineVersion"))
    self.source = try container.decode(
      RuntimeSource.self, forKey: AnyCodingKey(stringValue: "source"))
    self.manifestSHA256 = try container.decode(
      String.self, forKey: AnyCodingKey(stringValue: "manifestSHA256"))
    self.keyFiles = try container.decode(
      [String: String].self, forKey: AnyCodingKey(stringValue: "keyFiles"))
    self.capabilities = try container.decode(
      [CapabilityEvidence].self, forKey: AnyCodingKey(stringValue: "capabilities"))
    self.helpers = try container.decode(
      [String: Helper].self, forKey: AnyCodingKey(stringValue: "helpers"))
  }
}

// MARK: - Patch

/// A patch to the runtime.
package struct Patch: Codable, Equatable, Sendable {
  package let id: String
  package let title: String
  package let capability: Capability?
  package let ref: String
  package let commit: String?
  package let status: FixStatus

  package init(
    id: String, title: String, capability: Capability? = nil, ref: String,
    commit: String? = nil, status: FixStatus
  ) {
    self.id = id
    self.title = title
    self.capability = capability
    self.ref = ref
    self.commit = commit
    self.status = status
  }

  /// Validates this patch.
  package func validate() throws(HubError) {
    guard Check.ascii(id, 4...4, first: { b in
      b >= 0x30 && b <= 0x39
    }, rest: { b in
      b >= 0x30 && b <= 0x39
    }) else {
      throw HubError.invalid("Patch.id: must match ^[0-9]{4}$")
    }

    try Check.text(title, field: "Patch.title", max: .max)

    guard ref.utf8.count <= 120 else {
      throw HubError.invalid("Patch.ref: must be at most 120 bytes")
    }
    for scalar in ref.unicodeScalars {
      let value = scalar.value
      if (value >= 0x0000 && value <= 0x001f) || value == 0x007f {
        throw HubError.invalid("Patch.ref: may not contain control characters")
      }
    }

    if let commit = commit {
      guard Check.ascii(commit, 7...40, first: { b in
        (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66)
      }, rest: { b in
        (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66)
      }) else {
        throw HubError.invalid("Patch.commit: must match ^[0-9a-f]{7,40}$")
      }
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["id", "title", "capability", "ref", "commit", "status"],
      type: "Patch")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id"))
    self.title = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "title"))
    self.capability = try container.decodeIfPresent(
      Capability.self, forKey: AnyCodingKey(stringValue: "capability"))
    self.ref = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "ref"))
    self.commit = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "commit"))
    self.status = try container.decode(
      FixStatus.self, forKey: AnyCodingKey(stringValue: "status"))
  }
}

// MARK: - Proposal Rule

/// A proposal for a fix.
package struct Proposal: Codable, Equatable, Sendable {
  package let fixes: [String]
  package let provider: ProviderID?

  package init(fixes: [String], provider: ProviderID? = nil) {
    self.fixes = fixes
    self.provider = provider
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["fixes", "provider"], type: "Proposal")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.fixes = try container.decode(
      [String].self, forKey: AnyCodingKey(stringValue: "fixes"))
    self.provider = try container.decodeIfPresent(
      ProviderID.self, forKey: AnyCodingKey(stringValue: "provider"))
  }
}

/// A rule that proposes fixes.
package struct ProposalRule: Codable, Equatable, Sendable {
  package let id: String
  package let when: Predicate
  package let propose: Proposal

  package init(id: String, when: Predicate, propose: Proposal) {
    self.id = id
    self.when = when
    self.propose = propose
  }

  /// Validates this proposal rule.
  package func validate() throws(HubError) {
    try Check.id(id, field: "ProposalRule.id")
    try when.validate()
    for fixID in propose.fixes {
      try Check.id(fixID, field: "ProposalRule.propose.fixes")
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["id", "when", "propose"], type: "ProposalRule")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id"))
    self.when = try container.decode(Predicate.self, forKey: AnyCodingKey(stringValue: "when"))
    self.propose = try container.decode(
      Proposal.self, forKey: AnyCodingKey(stringValue: "propose"))
  }
}
