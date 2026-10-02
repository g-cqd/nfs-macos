import CryptoKit
import Darwin
import Foundation

/// Installs one entry of a client layer into a prefix, verifying every byte it writes.
///
/// Folders are created one component at a time without following a link, so a prefix that holds
/// a link where a folder should be cannot send a write outside it. A file is an APFS clone of the
/// layer's blob when both sit on one volume, and a copy otherwise; either way the result is hashed
/// against the manifest, so a blob altered in the app, or a copy that went wrong, is caught.
enum ClientLayerFile {
  /// Failures of a clone that mean "this volume cannot clone", where a copy is the right fallback.
  private static let cloneUnsupported: Set<Int32> = [ENOTSUP, EXDEV, ENOSYS, EINVAL]

  /// - Parameters:
  ///   - entry: A validated entry.
  ///   - blobs: The layer's `blobs` folder.
  ///   - driveC: The prefix's `drive_c`, which must be a real folder.
  /// - Throws: A failure when anything exists where the entry goes, a link is in the way, a blob is
  ///   missing or does not match its digest, or the system refuses a write.
  static func install(
    _ entry: ClientLayerManifest.Entry, blobs: URL, into driveC: URL
  ) throws(LauncherError) {
    let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
    let target = driveC.path + "/" + entry.path
    switch entry.kind {
    case .directory:
      try ensureDirectory(components[...], under: driveC.path)
    case .file:
      try ensureDirectory(components.dropLast(), under: driveC.path)
      guard let digest = entry.sha256, let size = entry.size else {
        throw .operation("The EA app's files hold a malformed file: \(entry.path)")
      }
      var existing = stat()
      guard lstat(target, &existing) != 0, errno == ENOENT else {
        throw .operation("The Windows folder already has a file the EA app adds: \(entry.path)")
      }
      try place(
        blob: blobs.appendingPathComponent(digest).path, at: target, size: size, digest: digest,
        name: entry.path)
    }
    guard chmod(target, mode_t(entry.mode)) == 0 else {
      throw .operation("Could not set the permissions of \(entry.path) (\(errno)).")
    }
    try setAttributes(entry.xattrs ?? [:], at: target, name: entry.path)
  }

  /// Creates the folder chain below `root`, refusing a link or a file anywhere on it.
  private static func ensureDirectory(_ components: ArraySlice<Substring>, under root: String)
    throws(LauncherError)
  {
    var path = root
    for component in components {
      path += "/" + component
      var info = stat()
      if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR else {
          throw .operation("The Windows folder has a link or file where \(component) goes.")
        }
      } else if errno == ENOENT {
        guard mkdir(path, 0o755) == 0 else {
          throw .operation("Could not create \(component) (\(errno)).")
        }
      } else {
        throw .operation("Could not inspect \(component) (\(errno)).")
      }
    }
  }

  /// Clones the blob to the target, or copies it, and proves the result has the pinned digest.
  private static func place(
    blob: String, at target: String, size: Int, digest: String, name: String
  ) throws(LauncherError) {
    var info = stat()
    guard lstat(blob, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) == size
    else {
      throw .operation("The EA app's file is missing or has the wrong size: \(name)")
    }
    if clonefileat(AT_FDCWD, blob, AT_FDCWD, target, UInt32(CLONE_NOFOLLOW)) == 0 {
      try stripAttributes(at: target)
      guard try FileDigest.sha256(of: URL(fileURLWithPath: target), size: size) == digest else {
        throw .operation("The EA app's file does not match its digest: \(name)")
      }
      return
    }
    let failure = errno
    guard cloneUnsupported.contains(failure) else {
      throw .operation("Could not place \(name) (\(failure)).")
    }
    try copy(blob: blob, to: target, size: size, digest: digest, name: name)
  }

  /// A hashing copy for volumes that cannot clone: the bytes written are the bytes verified.
  static func copy(blob: String, to target: String, size: Int, digest: String, name: String)
    throws(LauncherError)
  {
    do {
      let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: blob))
      defer { do { try input.close() } catch { print("Could not close \(name): \(error)") } }
      let descriptor = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else {
        throw LauncherError.operation("Could not create \(name) (\(errno)).")
      }
      let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      var closed = false
      defer {
        if !closed {
          do { try output.close() } catch { print("Could not close \(name): \(error)") }
        }
      }
      var hash = SHA256()
      var remaining = size
      while let chunk = try input.read(upToCount: min(1_048_576, remaining + 1)), !chunk.isEmpty {
        guard chunk.count <= remaining else {
          throw LauncherError.operation("The EA app's file grew while it was copied: \(name)")
        }
        remaining -= chunk.count
        hash.update(data: chunk)
        try output.write(contentsOf: chunk)
      }
      try output.close()
      closed = true
      let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
      guard remaining == 0, actual == digest else {
        throw LauncherError.operation("The EA app's file does not match its digest: \(name)")
      }
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not copy \(name): \(error.localizedDescription)")
    }
  }

  /// A clone carries the blob's attributes, among them macOS's quarantine and provenance marks of
  /// the Mac the app was downloaded to. None of them belongs in the prefix, so all are removed
  /// before the entry's own Wine attributes are set.
  private static func stripAttributes(at path: String) throws(LauncherError) {
    let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return }
    var names = [CChar](repeating: 0, count: size)
    guard listxattr(path, &names, size, XATTR_NOFOLLOW) >= 0 else { return }
    for bytes in names.split(separator: 0) {
      let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      if removexattr(path, name, XATTR_NOFOLLOW) != 0, !name.hasPrefix("com.apple.") {
        throw .operation("Could not clear the attribute \(name) (\(errno)).")
      }
    }
  }

  private static func setAttributes(_ attributes: [String: String], at path: String, name: String)
    throws(LauncherError)
  {
    for (attribute, encoded) in attributes.sorted(by: { $0.key < $1.key }) {
      guard let value = Data(base64Encoded: encoded) else {
        throw .operation("The EA app's files carry an unreadable attribute: \(name)")
      }
      let status = value.withUnsafeBytes {
        setxattr(path, attribute, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
      }
      guard status == 0 else {
        throw .operation("Could not set an attribute on \(name) (\(errno)).")
      }
    }
  }
}
