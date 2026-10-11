import Foundation

/// Where an installed runtime app keeps its parts.
package struct RuntimeAppInfo: Equatable, Sendable {
  package let id: String
  package let manifestSHA256: String
  /// `Contents/SharedSupport/Wine`: the Wine tree (`bin`, `lib`, `share`).
  package let wine: URL
  /// `Contents/SharedSupport/Wine/bin/wine`.
  package let wineBinary: URL
  /// `Contents/Helpers`: tools that live beside the runtime, not in it.
  package let helpersDir: URL
  /// `Contents/Helpers/x87sidecar`, when the app has one.
  package let x87sidecar: URL?
}

/// What `RuntimeApp.locate` found at a path.
package enum RuntimeAppState: Equatable, Sendable {
  case ok(RuntimeAppInfo)
  case notFound
  case invalid(String)
  /// The app is intact, but its manifest is not the one that was asked for.
  case mismatch(expected: String, actual: String)
}

/// The result of checking an installed runtime app against its own manifest.
package struct RuntimeVerifyReport: Equatable, Sendable {
  package let state: RuntimeAppState
  /// Regular files whose SHA-256 was compared (Wine tree and helpers).
  package let checkedFiles: Int
  /// What is wrong inside an app that was located; at most `maxProblems` lines.
  package let problems: [String]

  package static let maxProblems = 50

  package var isOK: Bool {
    if case .ok = state { return problems.isEmpty }
    return false
  }
}

/// `Contents/Resources/runtime/runtime.json`: what the installer recorded about the install.
package struct RuntimeRecord: Codable, Equatable, Sendable {
  package let schemaVersion: Int
  package let id: String
  package let manifestSHA256: String
  /// The absolute path of the Wine tree this app was copied from.
  package let source: String
  package let installedAt: Date
  /// SHA-256 of each file in `Contents/Helpers`, by file name.
  package let helpers: [String: String]

  private enum CodingKeys: String, CaseIterable, CodingKey {
    case schemaVersion, id, manifestSHA256, source, installedAt, helpers
  }

  package init(
    id: String, manifestSHA256: String, source: String, installedAt: Date,
    helpers: [String: String]
  ) {
    self.schemaVersion = 1
    self.id = id
    self.manifestSHA256 = manifestSHA256
    self.source = source
    self.installedAt = installedAt
    self.helpers = helpers
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)), type: "runtime.json")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    id = try container.decode(String.self, forKey: .id)
    manifestSHA256 = try container.decode(String.self, forKey: .manifestSHA256)
    source = try container.decode(String.self, forKey: .source)
    installedAt = try container.decode(Date.self, forKey: .installedAt)
    helpers = try container.decode([String: String].self, forKey: .helpers)
    try validate()
  }

  /// - Throws: `.invalid` for an unknown schema version, a malformed id or hash, or a helper
  ///   name that is not a single path component.
  package func validate() throws(HubError) {
    guard schemaVersion == 1 else {
      throw .invalid("runtime.json: schemaVersion must be 1, got \(schemaVersion).")
    }
    try Check.id(id, field: "runtime.json id")
    try Check.sha256(manifestSHA256, field: "runtime.json manifestSHA256")
    guard source.hasPrefix("/") else { throw .invalid("runtime.json: source must be absolute.") }
    for (name, hash) in helpers {
      guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0)
      else {
        throw .invalid("runtime.json: bad helper name \(name).")
      }
      try Check.sha256(hash, field: "runtime.json helper \(name)")
    }
  }

  package static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  package static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// Reads and validates the record at `path`.
  /// - Throws: `.invalid` when the file is missing, too large, not strict JSON, or fails ``validate()``.
  package static func read(at path: String) throws(HubError) -> RuntimeRecord {
    guard let data = try DatastoreIO.readBounded(path, limit: 64 * 1024) else {
      throw .invalid("runtime.json is missing.")
    }
    do {
      return try decoder().decode(RuntimeRecord.self, from: data)
    } catch {
      throw .invalid("Cannot read runtime.json: \(error)")
    }
  }
}
