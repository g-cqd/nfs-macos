import Darwin
import Foundation

/// A datastore move manifest: a typed, ordered list of steps that reorganise a data volume.
///
/// The plan is data. Loading it rejects unknown keys everywhere, then validates every path and
/// operation (see ``validationErrors()``), so a plan that loads can only mutate what it declares.
package struct DatastorePlan: Equatable, Sendable {
  package var schemaVersion: Int
  package var id: String
  package var volume: String
  package var protected: [String]
  package var allowedRoots: [String]
  package var backupDir: String
  package var journal: String
  package var steps: [DatastoreStep]

  /// The largest plan file the loader reads.
  package static let maxFileBytes = 1024 * 1024

  package init(
    schemaVersion: Int = 1, id: String, volume: String, protected: [String],
    allowedRoots: [String], backupDir: String, journal: String, steps: [DatastoreStep]
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.volume = volume
    self.protected = protected
    self.allowedRoots = allowedRoots
    self.backupDir = backupDir
    self.journal = journal
    self.steps = steps
  }

  /// Reads, decodes and validates the plan at `path`.
  ///
  /// The file is opened with `O_NOFOLLOW`, must be a regular file of at most 1 MiB, and may hold
  /// no key the schema does not name.
  /// - Throws: `.io` when the file cannot be read, `.invalid` when it does not decode or fails
  ///   validation (every validation error is listed in the message).
  package static func load(path: String) throws(HubError) -> DatastorePlan {
    guard let data = try DatastoreIO.readBounded(path, limit: maxFileBytes) else {
      throw .io("Plan file does not exist: \(path)")
    }
    return try decode(data)
  }

  /// Decodes and validates a plan from JSON bytes.
  /// - Throws: `.invalid` when the bytes do not decode or the plan fails validation.
  package static func decode(_ data: Data) throws(HubError) -> DatastorePlan {
    guard data.count <= maxFileBytes else { throw .invalid("The plan is larger than 1 MiB.") }
    let plan: DatastorePlan
    do {
      plan = try JSONDecoder().decode(DatastorePlan.self, from: data)
    } catch let error as DecodingError {
      throw .invalid("Cannot decode the plan: \(DatastoreDecoding.describe(error))")
    } catch {
      throw .invalid("Cannot decode the plan: \(error)")
    }
    let errors = plan.validationErrors()
    guard errors.isEmpty else {
      throw .invalid(errors.joined(separator: "\n"))
    }
    return plan
  }

  /// The step with `id`, or nil.
  package func step(_ id: String) -> DatastoreStep? {
    steps.first { $0.id == id }
  }
}

/// One ordered unit of a plan. Steps run only in listed order, one at a time.
package struct DatastoreStep: Equatable, Sendable {
  package var id: String
  package var title: String
  package var notes: String?
  package var requiresNoWine: Bool
  package var preconditions: [DatastoreCheck]
  package var operations: [DatastoreOp]
  package var verify: [DatastoreCheck]

  package init(
    id: String, title: String, notes: String? = nil, requiresNoWine: Bool = false,
    preconditions: [DatastoreCheck] = [], operations: [DatastoreOp],
    verify: [DatastoreCheck] = []
  ) {
    self.id = id
    self.title = title
    self.notes = notes
    self.requiresNoWine = requiresNoWine
    self.preconditions = preconditions
    self.operations = operations
    self.verify = verify
  }
}

/// The fields of a `writeHubConfig` operation.
package struct DatastoreHubConfigSpec: Equatable, Sendable {
  package var path: String
  package var prefix: String
  package var runtime: String
  package var runtimeManifest: String
  package var runtimeManifestSHA256: String
  package var generation: Int

  package init(
    path: String, prefix: String, runtime: String, runtimeManifest: String,
    runtimeManifestSHA256: String, generation: Int
  ) {
    self.path = path
    self.prefix = prefix
    self.runtime = runtime
    self.runtimeManifest = runtimeManifest
    self.runtimeManifestSHA256 = runtimeManifestSHA256
    self.generation = generation
  }

  /// The configuration the operation writes.
  package var config: HubConfig {
    HubConfig(
      schemaVersion: 1, prefix: prefix, runtime: runtime,
      runtimeManifestSHA256: runtimeManifestSHA256, generation: generation)
  }
}

/// A filesystem operation of a step.
package enum DatastoreOp: Equatable, Sendable {
  case mkdir(path: String, mode: Int)
  case rename(from: String, to: String)
  case symlink(path: String, target: String)
  case replaceSymlink(path: String, target: String, expectedTarget: String)
  case backup(path: String)
  case rewriteText(path: String, find: String, replace: String, expectedCount: Int)
  case writeHubConfig(DatastoreHubConfigSpec)
}

/// What a check expects of a path.
package enum DatastoreExpectedKind: String, Equatable, Sendable {
  case directory, file, symlink, any
}

/// A read-only assertion about the filesystem or the running system.
package enum DatastoreCheck: Equatable, Sendable {
  case exists(path: String, kind: DatastoreExpectedKind)
  case absent(path: String)
  /// The path exists and is not a symlink (`lstat`).
  case notSymlink(path: String)
  case symlinkTarget(path: String, target: String)
  case sameFile(a: String, b: String)
  case textContains(path: String, text: String, count: Int)
  case vdfParses(path: String)
  case shellSyntax(path: String)
  case hubConfigValid(path: String, prefix: String)
  case prefixLocates(path: String, allowedRoots: [String], resolved: String)
  case noWineProcess
  case noOpenFiles(path: String)
  /// The Wine prefix at `path` is not in use: no open file under it or an alias, no process
  /// holding its Wine server socket, no process command line naming it. Other Wine processes on
  /// the machine do not matter.
  case prefixNotInUse(path: String, aliases: [String])
  /// Nothing under `path` has changed (mtime or ctime) in the last `minutes` minutes.
  case quietFor(path: String, minutes: Int)
}

// MARK: - Strict decoding

/// A coding key built from any string, used to read every key of an object.
struct DatastoreKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ stringValue: String) { self.stringValue = stringValue }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

/// An object whose keys are limited to a known set; reading a key outside the set fails.
struct DatastoreObject {
  let container: KeyedDecodingContainer<DatastoreKey>

  /// - Throws: `DecodingError.dataCorrupted` naming every key not in `allowed`.
  init(_ decoder: any Decoder, allowed: [String]) throws {
    container = try decoder.container(keyedBy: DatastoreKey.self)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
    guard unknown.isEmpty else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Unknown keys: \(unknown.sorted().joined(separator: ", "))"))
    }
  }

  func string(_ key: String) throws -> String {
    try container.decode(String.self, forKey: DatastoreKey(key))
  }

  func int(_ key: String) throws -> Int {
    try container.decode(Int.self, forKey: DatastoreKey(key))
  }

  func optionalString(_ key: String) throws -> String? {
    try container.decodeIfPresent(String.self, forKey: DatastoreKey(key))
  }

  func bool(_ key: String, default value: Bool) throws -> Bool {
    try container.decodeIfPresent(Bool.self, forKey: DatastoreKey(key)) ?? value
  }

  func strings(_ key: String) throws -> [String] {
    try container.decode([String].self, forKey: DatastoreKey(key))
  }

  func list<T: Decodable>(_ key: String, as type: T.Type) throws -> [T] {
    try container.decodeIfPresent([T].self, forKey: DatastoreKey(key)) ?? []
  }
}

/// Helpers for the strict decoders.
package enum DatastoreDecoding {
  /// A readable one-line form of a decoding error, with its path in the document.
  package static func describe(_ error: DecodingError) -> String {
    func path(_ context: DecodingError.Context) -> String {
      let text = context.codingPath.map { key in
        key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
      }.joined()
      return text.isEmpty ? "(root)" : text
    }
    switch error {
    case .dataCorrupted(let context):
      return "\(path(context)): \(context.debugDescription)"
    case .keyNotFound(let key, let context):
      return "\(path(context)): missing key \"\(key.stringValue)\""
    case .typeMismatch(_, let context), .valueNotFound(_, let context):
      return "\(path(context)): \(context.debugDescription)"
    @unknown default:
      return "\(error)"
    }
  }
}

extension DatastorePlan: Decodable {
  package init(from decoder: any Decoder) throws {
    let object = try DatastoreObject(
      decoder,
      allowed: [
        "schemaVersion", "id", "volume", "protected", "allowedRoots", "backupDir", "journal",
        "steps",
      ])
    self.init(
      schemaVersion: try object.int("schemaVersion"),
      id: try object.string("id"),
      volume: try object.string("volume"),
      protected: try object.strings("protected"),
      allowedRoots: try object.strings("allowedRoots"),
      backupDir: try object.string("backupDir"),
      journal: try object.string("journal"),
      steps: try object.container.decode([DatastoreStep].self, forKey: DatastoreKey("steps")))
  }
}

extension DatastoreStep: Decodable {
  package init(from decoder: any Decoder) throws {
    let object = try DatastoreObject(
      decoder,
      allowed: [
        "id", "title", "notes", "requiresNoWine", "preconditions", "operations", "verify",
      ])
    self.init(
      id: try object.string("id"),
      title: try object.string("title"),
      notes: try object.optionalString("notes"),
      requiresNoWine: try object.bool("requiresNoWine", default: false),
      preconditions: try object.list("preconditions", as: DatastoreCheck.self),
      operations: try object.container.decode(
        [DatastoreOp].self, forKey: DatastoreKey("operations")),
      verify: try object.list("verify", as: DatastoreCheck.self))
  }
}

extension DatastoreOp: Decodable {
  package init(from decoder: any Decoder) throws {
    let tagContainer = try decoder.container(keyedBy: DatastoreKey.self)
    let tag = try tagContainer.decode(String.self, forKey: DatastoreKey("op"))
    func object(_ fields: [String]) throws -> DatastoreObject {
      try DatastoreObject(decoder, allowed: ["op"] + fields)
    }
    switch tag {
    case "mkdir":
      let o = try object(["path", "mode"])
      self = .mkdir(path: try o.string("path"), mode: try o.int("mode"))
    case "rename":
      let o = try object(["from", "to"])
      self = .rename(from: try o.string("from"), to: try o.string("to"))
    case "symlink":
      let o = try object(["path", "target"])
      self = .symlink(path: try o.string("path"), target: try o.string("target"))
    case "replaceSymlink":
      let o = try object(["path", "target", "expectedTarget"])
      self = .replaceSymlink(
        path: try o.string("path"), target: try o.string("target"),
        expectedTarget: try o.string("expectedTarget"))
    case "backup":
      let o = try object(["path"])
      self = .backup(path: try o.string("path"))
    case "rewriteText":
      let o = try object(["path", "find", "replace", "expectedCount"])
      self = .rewriteText(
        path: try o.string("path"), find: try o.string("find"), replace: try o.string("replace"),
        expectedCount: try o.int("expectedCount"))
    case "writeHubConfig":
      let o = try object([
        "path", "prefix", "runtime", "runtimeManifest", "runtimeManifestSHA256", "generation",
      ])
      self = .writeHubConfig(
        DatastoreHubConfigSpec(
          path: try o.string("path"), prefix: try o.string("prefix"),
          runtime: try o.string("runtime"), runtimeManifest: try o.string("runtimeManifest"),
          runtimeManifestSHA256: try o.string("runtimeManifestSHA256"),
          generation: try o.int("generation")))
    default:
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unknown op \"\(tag)\""))
    }
  }
}

extension DatastoreCheck: Decodable {
  package init(from decoder: any Decoder) throws {
    let tagContainer = try decoder.container(keyedBy: DatastoreKey.self)
    let tag = try tagContainer.decode(String.self, forKey: DatastoreKey("check"))
    func object(_ fields: [String]) throws -> DatastoreObject {
      try DatastoreObject(decoder, allowed: ["check"] + fields)
    }
    switch tag {
    case "exists":
      let o = try object(["path", "kind"])
      let kindText = try o.string("kind")
      guard let kind = DatastoreExpectedKind(rawValue: kindText) else {
        throw DecodingError.dataCorrupted(
          .init(
            codingPath: decoder.codingPath,
            debugDescription: "kind must be directory, file, symlink or any, got \"\(kindText)\""))
      }
      self = .exists(path: try o.string("path"), kind: kind)
    case "absent":
      self = .absent(path: try object(["path"]).string("path"))
    case "notSymlink":
      self = .notSymlink(path: try object(["path"]).string("path"))
    case "symlinkTarget":
      let o = try object(["path", "target"])
      self = .symlinkTarget(path: try o.string("path"), target: try o.string("target"))
    case "sameFile":
      let o = try object(["a", "b"])
      self = .sameFile(a: try o.string("a"), b: try o.string("b"))
    case "textContains":
      let o = try object(["path", "text", "count"])
      self = .textContains(
        path: try o.string("path"), text: try o.string("text"), count: try o.int("count"))
    case "vdfParses":
      self = .vdfParses(path: try object(["path"]).string("path"))
    case "shellSyntax":
      self = .shellSyntax(path: try object(["path"]).string("path"))
    case "hubConfigValid":
      let o = try object(["path", "prefix"])
      self = .hubConfigValid(path: try o.string("path"), prefix: try o.string("prefix"))
    case "prefixLocates":
      let o = try object(["path", "allowedRoots", "resolved"])
      self = .prefixLocates(
        path: try o.string("path"), allowedRoots: try o.strings("allowedRoots"),
        resolved: try o.string("resolved"))
    case "noWineProcess":
      _ = try object([])
      self = .noWineProcess
    case "noOpenFiles":
      self = .noOpenFiles(path: try object(["path"]).string("path"))
    case "prefixNotInUse":
      let o = try object(["path", "aliases"])
      self = .prefixNotInUse(
        path: try o.string("path"),
        aliases: try o.container.decodeIfPresent([String].self, forKey: DatastoreKey("aliases"))
          ?? [])
    case "quietFor":
      let o = try object(["path", "minutes"])
      self = .quietFor(path: try o.string("path"), minutes: try o.int("minutes"))
    default:
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unknown check \"\(tag)\""))
    }
  }
}
