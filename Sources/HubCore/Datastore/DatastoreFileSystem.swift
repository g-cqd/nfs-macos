import CryptoKit
import Darwin
import Foundation

/// The kind of a filesystem node, as `lstat` reports it.
package enum DatastoreNodeKind: String, Codable, Equatable, Sendable {
  case directory, file, symlink, other
}

/// What a check or a precondition needs to know about one node.
package struct DatastoreNodeInfo: Equatable, Sendable {
  package var kind: DatastoreNodeKind
  package var device: Int64
  package var inode: UInt64
  /// The permission bits (`st_mode & 0o7777`).
  package var mode: UInt16
  package var size: Int64
  /// Seconds since 1970 of the last content change (0 for a simulated node).
  package var modified: Double
  /// Seconds since 1970 of the last inode change (0 for a simulated node).
  package var changed: Double

  package init(
    kind: DatastoreNodeKind, device: Int64, inode: UInt64, mode: UInt16, size: Int64,
    modified: Double = 0, changed: Double = 0
  ) {
    self.kind = kind
    self.device = device
    self.inode = inode
    self.mode = mode
    self.size = size
    self.modified = modified
    self.changed = changed
  }

  init(_ info: Darwin.stat) {
    let kind: DatastoreNodeKind
    switch info.st_mode & S_IFMT {
    case S_IFDIR: kind = .directory
    case S_IFREG: kind = .file
    case S_IFLNK: kind = .symlink
    default: kind = .other
    }
    self.init(
      kind: kind, device: Int64(info.st_dev), inode: UInt64(info.st_ino),
      mode: UInt16(info.st_mode & 0o7777), size: Int64(info.st_size),
      modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
      changed: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9)
  }
}

/// The size of a tree, measured without following symlinks. Equal measurements before and after a
/// rename show that nothing was copied, lost or added.
package struct DatastoreMeasurement: Codable, Equatable, Sendable {
  /// Every node below the root (files, directories, symlinks and the rest), not the root itself.
  package var entries: Int
  /// The summed size of the regular files.
  package var bytes: Int64
  package var symlinks: Int
  /// `st_dev` and `st_ino` of the root.
  package var device: Int64
  package var inode: UInt64

  package init(entries: Int, bytes: Int64, symlinks: Int, device: Int64, inode: UInt64) {
    self.entries = entries
    self.bytes = bytes
    self.symlinks = symlinks
    self.device = device
    self.inode = inode
  }

  /// Whether the two trees have the same content counts, ignoring the root's identity.
  package func sameContent(as other: DatastoreMeasurement) -> Bool {
    entries == other.entries && bytes == other.bytes && symlinks == other.symlinks
  }
}

/// The filesystem as the plan sees it: the real one, or a simulation laid over it.
///
/// Every method is read-only. `nil` means the thing is not there (`ENOENT` or `ENOTDIR`); any
/// other failure throws.
package protocol DatastoreFileSystem: Sendable {
  /// The node at `path`, not following a final symlink.
  func lstatNode(_ path: String) throws(HubError) -> DatastoreNodeInfo?
  /// The node at `path`, following symlinks.
  func statNode(_ path: String) throws(HubError) -> DatastoreNodeInfo?
  /// The target of the symlink at `path`; nil when `path` is absent or not a symlink.
  func linkTarget(_ path: String) throws(HubError) -> String?
  /// The bytes of the regular file at `path` (at most `limit`); nil when it is absent.
  func contents(of path: String, limit: Int) throws(HubError) -> Data?
  /// The names in the directory at `path`; nil when it is absent or not a directory.
  func childNames(of path: String) throws(HubError) -> [String]?
  /// `realpath` of the directory at `path`; nil when it is absent.
  func canonicalDirectory(_ path: String) throws(HubError) -> String?
  /// A real path from which the file's bytes can be read directly; nil when they exist only in a
  /// simulation.
  func realFilePath(_ path: String) throws(HubError) -> String?
  /// Whether nothing is simulated, so the view equals the real filesystem.
  var isPristine: Bool { get }
}

extension DatastoreFileSystem {
  /// The siblings of `path` named `<name>.datastore-tmp-*`: temporary files a crashed run left.
  package func leftoverTemporaries(for path: String) throws(HubError) -> [String] {
    let directory = DatastorePath.parent(of: path)
    let prefix = DatastorePath.name(of: path) + DatastoreIO.temporaryMarker
    let names = try childNames(of: directory) ?? []
    return names.filter { $0.hasPrefix(prefix) }.sorted().map {
      DatastorePath.join(directory, $0)
    }
  }

  /// Measures the tree at `path` with `lstat` only, never following a symlink.
  /// - Returns: nil when `path` is absent.
  /// - Complexity: O(n) in the number of nodes below `path`; iterative, with an explicit stack.
  package func measure(_ path: String) throws(HubError) -> DatastoreMeasurement? {
    guard let root = try lstatNode(path) else { return nil }
    var entries = 0
    var bytes: Int64 = 0
    var symlinks = 0
    var pending: [String] = root.kind == .directory ? [path] : []
    while let directory = pending.popLast() {
      for name in try childNames(of: directory) ?? [] {
        let child = DatastorePath.join(directory, name)
        guard let info = try lstatNode(child) else { continue }
        entries += 1
        switch info.kind {
        case .directory: pending.append(child)
        case .file: bytes += info.size
        case .symlink: symlinks += 1
        case .other: break
        }
      }
    }
    return DatastoreMeasurement(
      entries: entries, bytes: bytes, symlinks: symlinks, device: root.device, inode: root.inode)
  }
}

// MARK: - The real filesystem

/// The real filesystem, read with POSIX calls.
package struct RealDatastoreFileSystem: DatastoreFileSystem {
  package init() {}

  package var isPristine: Bool { true }

  package func lstatNode(_ path: String) throws(HubError) -> DatastoreNodeInfo? {
    var info = stat()
    guard Darwin.lstat(path, &info) == 0 else {
      if errno == ENOENT || errno == ENOTDIR { return nil }
      throw posixFailure("lstat", path)
    }
    return DatastoreNodeInfo(info)
  }

  package func statNode(_ path: String) throws(HubError) -> DatastoreNodeInfo? {
    var info = stat()
    guard stat(path, &info) == 0 else {
      if errno == ENOENT || errno == ENOTDIR { return nil }
      throw posixFailure("stat", path)
    }
    return DatastoreNodeInfo(info)
  }

  package func linkTarget(_ path: String) throws(HubError) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let length = Darwin.readlink(path, &buffer, Int(PATH_MAX))
    guard length >= 0 else {
      if errno == ENOENT || errno == ENOTDIR || errno == EINVAL { return nil }
      throw posixFailure("readlink", path)
    }
    let bytes = buffer[0..<length].map { UInt8(bitPattern: $0) }
    guard let text = String(bytes: bytes, encoding: .utf8) else {
      throw .unsafePath("The symlink \(path) has a target that is not UTF-8.")
    }
    return text
  }

  package func contents(of path: String, limit: Int) throws(HubError) -> Data? {
    try DatastoreIO.readBounded(path, limit: limit)
  }

  package func childNames(of path: String) throws(HubError) -> [String]? {
    guard let directory = Darwin.opendir(path) else {
      if errno == ENOENT || errno == ENOTDIR { return nil }
      throw posixFailure("opendir", path)
    }
    defer { Darwin.closedir(directory) }
    var names: [String] = []
    while let entry = Darwin.readdir(directory) {
      let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." { names.append(name) }
    }
    return names
  }

  package func canonicalDirectory(_ path: String) throws(HubError) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    guard Darwin.realpath(path, &buffer) != nil else {
      if errno == ENOENT || errno == ENOTDIR { return nil }
      throw posixFailure("realpath", path)
    }
    return String(cString: buffer)
  }

  package func realFilePath(_ path: String) throws(HubError) -> String? { path }
}

// MARK: - The simulated filesystem

/// The real filesystem with a plan's operations laid over it, in memory. Nothing is written: the
/// simulation answers "what would be there if the earlier operations had run".
///
/// A path with no override reads through to the base. An override is keyed by the path in the
/// simulated namespace: an alias says "the object that lives at this real path now sits here", so
/// a renamed tree is never copied or read twice.
package struct SimulatedDatastoreFileSystem: DatastoreFileSystem {
  enum Override: Sendable {
    case absent
    case alias(String)
    case directory(DatastoreNodeInfo)
    case symlink(String, DatastoreNodeInfo)
    case file(Data, DatastoreNodeInfo)

    var info: DatastoreNodeInfo? {
      switch self {
      case .absent, .alias: nil
      case .directory(let info), .symlink(_, let info), .file(_, let info): info
      }
    }
  }

  private enum Location {
    case absent
    case real(String)
    case virtual(Override)
  }

  private let base: any DatastoreFileSystem
  private var overrides: [String: Override] = [:]
  private var nextInode: UInt64 = 1 << 62

  package init(over base: any DatastoreFileSystem) {
    self.base = base
  }

  package var isPristine: Bool { overrides.isEmpty && base.isPristine }

  // MARK: Resolution

  /// Follows overrides (and the symlinks among them) to where `path` really is.
  private func locate(
    _ path: String, followFinal: Bool
  ) throws(HubError) -> (location: Location, path: String) {
    var current = path
    for _ in 0..<40 {
      var key = current
      var match: Override?
      while true {
        if let hit = overrides[key] {
          match = hit
          break
        }
        if key == "/" { break }
        key = DatastorePath.parent(of: key)
      }
      guard let override = match else { return (.real(current), current) }
      let rest = String(current.dropFirst(key.count))
      switch override {
      case .absent:
        return (.absent, current)
      case .alias(let real):
        return (.real(real + rest), current)
      case .directory, .file:
        return rest.isEmpty ? (.virtual(override), current) : (.absent, current)
      case .symlink(let target, _):
        if rest.isEmpty && !followFinal { return (.virtual(override), current) }
        current = DatastorePath.resolve(target, in: DatastorePath.parent(of: key))
        if !rest.isEmpty { current = DatastorePath.join(current, String(rest.dropFirst())) }
      }
    }
    throw .io("Too many levels of symbolic links: \(path)")
  }

  /// `path` with the symlinks of its parent directory expanded: the key an override uses.
  private func key(for path: String) throws(HubError) -> String {
    let parent = try locate(DatastorePath.parent(of: path), followFinal: true).path
    return DatastorePath.join(parent, DatastorePath.name(of: path))
  }

  // MARK: Reading

  package func lstatNode(_ path: String) throws(HubError) -> DatastoreNodeInfo? {
    switch try locate(path, followFinal: false).location {
    case .absent: return nil
    case .real(let real): return try base.lstatNode(real)
    case .virtual(let override): return override.info
    }
  }

  package func statNode(_ path: String) throws(HubError) -> DatastoreNodeInfo? {
    switch try locate(path, followFinal: true).location {
    case .absent: return nil
    case .real(let real): return try base.statNode(real)
    case .virtual(let override): return override.info
    }
  }

  package func linkTarget(_ path: String) throws(HubError) -> String? {
    switch try locate(path, followFinal: false).location {
    case .absent: return nil
    case .real(let real): return try base.linkTarget(real)
    case .virtual(let override):
      if case .symlink(let target, _) = override { return target }
      return nil
    }
  }

  package func contents(of path: String, limit: Int) throws(HubError) -> Data? {
    switch try locate(path, followFinal: true).location {
    case .absent: return nil
    case .real(let real): return try base.contents(of: real, limit: limit)
    case .virtual(let override):
      if case .file(let data, _) = override { return data }
      throw .unsafePath("\(path) is not a regular file.")
    }
  }

  package func childNames(of path: String) throws(HubError) -> [String]? {
    let (location, resolved) = try locate(path, followFinal: true)
    var names: Set<String>
    switch location {
    case .absent:
      return nil
    case .real(let real):
      guard let listed = try base.childNames(of: real) else { return nil }
      names = Set(listed)
    case .virtual(let override):
      guard case .directory = override else { return nil }
      names = []
    }
    for (key, override) in overrides where DatastorePath.parent(of: key) == resolved && key != "/" {
      let name = DatastorePath.name(of: key)
      if case .absent = override { names.remove(name) } else { names.insert(name) }
    }
    return Array(names)
  }

  package func canonicalDirectory(_ path: String) throws(HubError) -> String? {
    let (location, resolved) = try locate(path, followFinal: true)
    switch location {
    case .absent: return nil
    case .real(let real): return try base.canonicalDirectory(real)
    case .virtual: return resolved
    }
  }

  package func realFilePath(_ path: String) throws(HubError) -> String? {
    if case .real(let real) = try locate(path, followFinal: true).location { return real }
    return nil
  }

  // MARK: Simulating operations

  private mutating func freshInode() -> UInt64 {
    nextInode += 1
    return nextInode
  }

  private func requireParent(of key: String) throws(HubError) -> DatastoreNodeInfo {
    let parent = DatastorePath.parent(of: key)
    guard let info = try statNode(parent), info.kind == .directory else {
      throw .invalid("The parent directory \(parent) does not exist.")
    }
    return info
  }

  /// Simulates `mkdir` followed by `chmod`.
  package mutating func makeDirectory(_ path: String, mode: Int) throws(HubError) {
    let key = try key(for: path)
    let parent = try requireParent(of: key)
    overrides[key] = .directory(
      DatastoreNodeInfo(
        kind: .directory, device: parent.device, inode: freshInode(), mode: UInt16(mode), size: 0))
  }

  /// Simulates creating, or atomically replacing, a symlink.
  package mutating func placeSymlink(_ path: String, target: String) throws(HubError) {
    let key = try key(for: path)
    let parent = try requireParent(of: key)
    overrides[key] = .symlink(
      target,
      DatastoreNodeInfo(
        kind: .symlink, device: parent.device, inode: freshInode(), mode: 0o755,
        size: Int64(target.utf8.count)))
  }

  /// Simulates writing a regular file in place of whatever was at `path`.
  package mutating func placeFile(_ path: String, data: Data, mode: UInt16) throws(HubError) {
    let key = try key(for: path)
    let parent = try requireParent(of: key)
    overrides[key] = .file(
      data,
      DatastoreNodeInfo(
        kind: .file, device: parent.device, inode: freshInode(), mode: mode,
        size: Int64(data.count)))
  }

  /// Simulates `rename(from, to)`: the node, and everything simulated below it, moves.
  package mutating func rename(from: String, to: String) throws(HubError) {
    let fromKey = try key(for: from)
    let toKey = try key(for: to)
    _ = try requireParent(of: toKey)
    let moved: Override
    switch try locate(fromKey, followFinal: false).location {
    case .absent: throw .invalid("Cannot move \(from): it does not exist.")
    case .real(let real): moved = .alias(real)
    case .virtual(let override): moved = override
    }
    let below = overrides.filter { $0.key.hasPrefix(fromKey + "/") }
    for (key, override) in below {
      overrides[key] = nil
      overrides[toKey + key.dropFirst(fromKey.count)] = override
    }
    overrides[fromKey] = .absent
    overrides[toKey] = moved
  }
}

// MARK: - Bounded file reads and hashing

/// Bounded, symlink-refusing file reads and SHA-256 hashing.
package enum DatastoreIO {
  /// Between a path and the process id in the name of a temporary file or link.
  package static let temporaryMarker = ".datastore-tmp-"

  /// Flushes `fd` through the drive's cache (`F_FULLFSYNC`), falling back to `fsync`.
  /// - Throws: `.io` when neither succeeds.
  package static func syncFile(_ fd: Int32, _ path: String) throws(HubError) {
    if fcntl(fd, F_FULLFSYNC) == 0 { return }
    guard fsync(fd) == 0 else { throw posixFailure("fsync", path) }
  }

  /// Flushes the directory at `path`, so a rename or a new entry in it survives a power cut.
  /// - Throws: `.io` when the directory cannot be opened or flushed.
  package static func syncDirectory(_ path: String) throws(HubError) {
    let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw posixFailure("open", path) }
    defer { Darwin.close(fd) }
    try syncFile(fd, path)
  }

  /// Appends `bytes` to the file at `path` (created if missing, never through a symlink) and
  /// flushes the file, and its directory when the file is new.
  /// - Throws: `.io` on any failure.
  package static func append(_ bytes: Data, to path: String) throws(HubError) {
    var info = stat()
    let isNew = lstat(path, &info) != 0 && errno == ENOENT
    let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw posixFailure("open", path) }
    defer { Darwin.close(fd) }
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        throw posixFailure("write", path)
      }
      offset += written
    }
    try syncFile(fd, path)
    if isNew { try syncDirectory(DatastorePath.parent(of: path)) }
  }

  /// The largest file a check or an operation reads whole.
  package static let contentLimit = 64 * 1024 * 1024

  /// Reads the regular file at `path`, opened with `O_NOFOLLOW`.
  /// - Returns: nil when the file does not exist.
  /// - Throws: `.unsafePath` for a symlink or a non-regular file, `.invalid` above `limit` bytes.
  package static func readBounded(_ path: String, limit: Int) throws(HubError) -> Data? {
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT || errno == ENOTDIR { return nil }
      if errno == ELOOP { throw .unsafePath("\(path) is a symbolic link; refusing to read it.") }
      throw posixFailure("open", path)
    }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw posixFailure("fstat", path) }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw .unsafePath("\(path) is not a regular file.")
    }
    guard info.st_size <= limit else { throw .invalid("\(path) is larger than \(limit) bytes.") }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(Int(info.st_size))
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw posixFailure("read", path)
      }
      if count == 0 { break }
      guard bytes.count + count <= limit else {
        throw .invalid("\(path) is larger than \(limit) bytes.")
      }
      bytes.append(contentsOf: chunk[0..<count])
    }
    return Data(bytes)
  }

  /// The lowercase hex SHA-256 of `data`.
  package static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The lowercase hex SHA-256 of the regular file at `path`, read in chunks.
  /// - Returns: nil when the file does not exist.
  package static func sha256Hex(fileAt path: String) throws(HubError) -> String? {
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT || errno == ENOTDIR { return nil }
      if errno == ELOOP { throw .unsafePath("\(path) is a symbolic link; refusing to read it.") }
      throw posixFailure("open", path)
    }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw posixFailure("fstat", path) }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw .unsafePath("\(path) is not a regular file.")
    }
    var hasher = SHA256()
    var chunk = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw posixFailure("read", path)
      }
      if count == 0 { break }
      hasher.update(data: chunk[0..<count])
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Counts the non-overlapping occurrences of `needle` in `haystack`.
  package static func occurrences(of needle: Data, in haystack: Data) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var cursor = haystack.startIndex
    while let range = haystack.range(of: needle, in: cursor..<haystack.endIndex) {
      count += 1
      cursor = range.upperBound
    }
    return count
  }

  /// `haystack` with every non-overlapping occurrence of `needle` replaced by `replacement`.
  package static func replacing(_ needle: Data, with replacement: Data, in haystack: Data) -> Data {
    guard !needle.isEmpty else { return haystack }
    var result = Data()
    var cursor = haystack.startIndex
    while let range = haystack.range(of: needle, in: cursor..<haystack.endIndex) {
      result.append(haystack[cursor..<range.lowerBound])
      result.append(replacement)
      cursor = range.upperBound
    }
    result.append(haystack[cursor..<haystack.endIndex])
    return result
  }
}
