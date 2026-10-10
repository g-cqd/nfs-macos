import Foundation

/// The shared vocabulary of the Game Hub: one catalog of games, one set of locations, and the
/// types that describe an internal-disk instance. Everything here is `Sendable` and pure data.

/// A stable identifier for a game, such as `cod4` or `steam-228980`.
package struct GameID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
  package let rawValue: String
  package init(_ rawValue: String) { self.rawValue = rawValue }
  package init(stringLiteral value: String) { self.rawValue = value }
  package var description: String { rawValue }
}

/// Where a game's files come from.
package enum GameSource: String, Codable, Sendable, CaseIterable {
  case bundle, steam, epic, ea, ubisoft, folder
}

/// One game the Hub knows about.
package struct CatalogEntry: Identifiable, Codable, Equatable, Sendable {
  package var id: GameID
  package var title: String
  package var source: GameSource
  /// The folder that holds the game's files (for a bundle, `Contents/Resources/Game`).
  package var root: URL
  /// The main executable, relative to `root`, when it is known.
  package var executable: String?
  /// The size of `root` in bytes, when it was measured.
  package var sizeBytes: Int64?
  /// A short note for the user: the bundle name, the store app id, or the install folder.
  package var detail: String
  /// The recipe identifier (a `GameKind` raw value such as `cod4`) taken from the bundle manifest
  /// before `id` was made unique, so two wrapped builds of one game share it. `nil` when the entry
  /// names no known game.
  package var kindID: String?

  package init(
    id: GameID, title: String, source: GameSource, root: URL, executable: String? = nil,
    sizeBytes: Int64? = nil, detail: String = "", kindID: String? = nil
  ) {
    self.id = id
    self.title = title
    self.source = source
    self.root = root
    self.executable = executable
    self.sizeBytes = sizeBytes
    self.detail = detail
    self.kindID = kindID
  }
}

/// The locations the Hub reads and writes. Every path can be moved with `HUB_ROOT` and friends so
/// tests run in a temporary folder.
package struct HubLayout: Equatable, Sendable {
  /// The Hub folder on the big drive, `/Volumes/ExT2/GameHub` by default.
  package var hub: URL
  /// The folder of wrapped game apps, `/Volumes/ExT2/Bundles` by default.
  package var bundles: URL
  /// A Windows Steam install (its `steamapps` folder is scanned).
  package var steam: URL
  /// Where the EA app installs games, `<hub>/EA Games` by default.
  package var eaGames: URL
  /// An Epic Games Store folder (its `Manifests` folder is scanned when present).
  package var epic: URL
  /// A Ubisoft Connect folder (its `games` folder is scanned when present).
  package var ubisoft: URL
  /// Where internal-disk instances live, `~/Library/Application Support/GameHub/Instances`.
  package var instances: URL

  package init(
    hub: URL, bundles: URL, steam: URL, eaGames: URL, epic: URL, ubisoft: URL, instances: URL
  ) {
    self.hub = hub
    self.bundles = bundles
    self.steam = steam
    self.eaGames = eaGames
    self.epic = epic
    self.ubisoft = ubisoft
    self.instances = instances
  }

  package static func standard(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> HubLayout {
    let volume = URL(fileURLWithPath: environment["HUB_VOLUME"] ?? "/Volumes/ExT2", isDirectory: true)
    let hub = URL(
      fileURLWithPath: environment["HUB_ROOT"] ?? volume.appendingPathComponent("GameHub").path,
      isDirectory: true)
    return HubLayout(
      hub: hub,
      bundles: volume.appendingPathComponent("Bundles", isDirectory: true),
      steam: volume.appendingPathComponent("Steam", isDirectory: true),
      eaGames: hub.appendingPathComponent("EA Games", isDirectory: true),
      epic: volume.appendingPathComponent("EpicGamesStore", isDirectory: true),
      ubisoft: volume.appendingPathComponent("Ubisoft Game Launcher", isDirectory: true),
      instances: home.appendingPathComponent(
        "Library/Application Support/GameHub/Instances", isDirectory: true))
  }
}

/// Errors of the Hub's own operations.
package enum HubError: Error, Equatable, Sendable {
  case invalid(String)
  /// A path was outside the folder an operation may touch.
  case unsafePath(String)
  /// An instance would leave less than the floor free on the internal disk.
  case belowFloor(needed: Int64, free: Int64, floor: Int64)
  case io(String)
}

/// Free-space policy for internal-disk instances.
package struct SpaceBudget: Equatable, Sendable {
  /// Free bytes that must remain after an instance is built (default 25 GiB).
  package var floor: Int64
  /// Free bytes on the internal disk now.
  package var free: Int64

  package static let defaultFloor: Int64 = 25 * 1024 * 1024 * 1024

  package init(floor: Int64 = SpaceBudget.defaultFloor, free: Int64) {
    self.floor = floor
    self.free = free
  }

  /// Whether `bytes` more can be written and still leave `floor` free.
  package func allows(adding bytes: Int64) -> Bool { free - bytes >= floor }

  /// The bytes still available for instances before the floor is reached (never negative).
  package var available: Int64 { max(0, free - floor) }
}

/// What a file becomes in an instance.
package enum EntryKind: String, Codable, Sendable {
  /// A real copy of the file.
  case real
  /// A zero-length file with the same name, mode and time.
  case placeholder
  /// Not present in the instance at all (another game's store records, for example).
  case omitted
  /// A symbolic link, copied as a link.
  case symlink
  case directory
}

/// One path of an instance.
package struct InstanceEntry: Codable, Equatable, Sendable {
  /// The path relative to the prefix, with its exact case.
  package var path: String
  package var kind: EntryKind
  /// The size of the original file in bytes.
  package var size: Int64
  package var mode: UInt16
  /// Whole seconds since 1970 of the original file's modification time.
  package var mtimeSeconds: Int64
  /// The nanoseconds (0..<1_000_000_000) added to `mtimeSeconds`. Kept apart from the seconds
  /// because a `Double` cannot hold a nanosecond-exact time of this century.
  package var mtimeNanos: Int32
  /// The link target when `kind` is `.symlink`: the target as the instance's link will hold it.
  package var linkTarget: String?

  package init(
    path: String, kind: EntryKind, size: Int64 = 0, mode: UInt16 = 0o644, mtimeSeconds: Int64 = 0,
    mtimeNanos: Int32 = 0, linkTarget: String? = nil
  ) {
    self.path = path
    self.kind = kind
    self.size = size
    self.mode = mode
    self.mtimeSeconds = mtimeSeconds
    self.mtimeNanos = mtimeNanos
    self.linkTarget = linkTarget
  }
}

/// A validated instance identifier: 1...64 ASCII bytes drawn from `A-Z`, `a-z`, `0-9` and `-`.
///
/// The identifier names a folder directly under the instances folder, so it can never hold a
/// separator, a dot, a NUL or a byte outside ASCII.
package struct InstanceID: Hashable, Sendable, CustomStringConvertible {
  package let rawValue: String

  /// - Throws: `.invalid` when `rawValue` is empty, longer than 64 bytes, or holds any byte
  ///   other than an ASCII letter, digit or hyphen.
  /// - Complexity: O(n) in the length of `rawValue`, which is rejected beyond 64 bytes.
  package init(_ rawValue: String) throws(HubError) {
    let bytes = rawValue.utf8
    guard !bytes.isEmpty, bytes.count <= 64 else {
      throw .invalid("An instance id must be 1 to 64 characters long.")
    }
    for byte in bytes {
      let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
      let isDigit = byte >= 0x30 && byte <= 0x39
      guard isLetter || isDigit || byte == 0x2D else {
        throw .invalid("An instance id may only hold the ASCII letters, digits and hyphens.")
      }
    }
    self.rawValue = rawValue
  }

  package var description: String { rawValue }
}

/// Which parts of a prefix stay real in an instance. All paths are relative to the prefix and are
/// matched as whole path components (`a/b` covers `a/b` and everything under it).
package struct InstanceRecipe: Codable, Equatable, Sendable {
  package var gameID: GameID
  /// The game's own files, its store client, saves and config: copied for real.
  package var realRoots: [String]
  /// Files and folders needed to boot Wine in the prefix, such as `system.reg` and `user.reg`.
  package var bootPaths: [String]
  /// Folders left out entirely: other games' store records, so no store sees a damaged game.
  package var omitRoots: [String]

  package init(gameID: GameID, realRoots: [String], bootPaths: [String], omitRoots: [String] = []) {
    self.gameID = gameID
    self.realRoots = realRoots
    self.bootPaths = bootPaths
    self.omitRoots = omitRoots
  }
}

/// The cost of building an instance, before anything is written.
package struct InstancePlan: Equatable, Sendable {
  package var recipe: InstanceRecipe
  package var entries: [InstanceEntry]
  /// Bytes the real files take, counted once per real entry (hard links included, because each
  /// one is written as its own copy).
  package var realBytes: Int64
  package var placeholderCount: Int
  /// The number of omitted entries; an omitted folder counts once, not once per file inside it.
  package var omittedCount: Int
  /// Symlinks whose target is outside the prefix (relative path to the link), shown before building.
  package var externalLinks: [String]
  /// Bytes the real files occupy on disk (blocks, not lengths): what the budget must cover.
  package var allocatedBytes: Int64
  /// Pipes, sockets and devices found and left out; they cannot be copied.
  package var skippedSpecialCount: Int

  package init(
    recipe: InstanceRecipe, entries: [InstanceEntry], realBytes: Int64, placeholderCount: Int,
    omittedCount: Int, externalLinks: [String] = [], allocatedBytes: Int64? = nil,
    skippedSpecialCount: Int = 0
  ) {
    self.recipe = recipe
    self.entries = entries
    self.realBytes = realBytes
    self.placeholderCount = placeholderCount
    self.omittedCount = omittedCount
    self.externalLinks = externalLinks
    self.allocatedBytes = allocatedBytes ?? realBytes
    self.skippedSpecialCount = skippedSpecialCount
  }
}

/// The part of `instance.json` the library list needs. Decoding only this skips building the
/// (potentially huge) `entries` array.
package struct InstanceManifestHeader: Decodable, Sendable {
  package var instanceID: String
  package var gameID: GameID
  package var createdAt: Date
  package var realBytes: Int64
}

/// The record of a built instance, stored as `instance.json` beside its `Prefix` folder.
package struct InstanceManifest: Codable, Equatable, Sendable {
  package var schemaVersion = 2
  package var instanceID: String
  package var gameID: GameID
  package var createdAt: Date
  package var sourcePrefix: String
  package var realBytes: Int64
  package var entries: [InstanceEntry]

  package init(
    instanceID: String, gameID: GameID, createdAt: Date, sourcePrefix: String, realBytes: Int64,
    entries: [InstanceEntry]
  ) {
    self.instanceID = instanceID
    self.gameID = gameID
    self.createdAt = createdAt
    self.sourcePrefix = sourcePrefix
    self.realBytes = realBytes
    self.entries = entries
  }

  /// The largest `instance.json` the Hub will read (128 MiB); a manifest lists every path of a prefix.
  package static let maxFileBytes = 128 * 1024 * 1024

  /// The one encoder for `instance.json`: ISO 8601 dates (whole seconds) and sorted keys.
  package static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  /// The one decoder for `instance.json`; the counterpart of ``encoder()``.
  package static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
