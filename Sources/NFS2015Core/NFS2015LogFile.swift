import Darwin
import Foundation

/// Finds and reads the session log the helper's own output goes to.
package enum NFS2015LogFile {
  /// The most one read returns, so a very large log is taken in pieces.
  package static let readLimit = 8 * 1_048_576

  /// The path of the regular file a handle writes to, or nil for a terminal, a pipe or anything
  /// else. The starter opens the log and gives it to the helper as standard output, so this is
  /// how the helper learns where its own log is without a new command-line option.
  package static func path(of handle: FileHandle) -> URL? {
    let descriptor = handle.fileDescriptor
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
    let path = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
  }

  /// What the file holds from `offset`, at most `readLimit` bytes, and where the next read starts.
  /// A file that is shorter than `offset` (replaced or truncated) is read from its start.
  package static func read(_ url: URL, from offset: UInt64) -> (text: String, next: UInt64)? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size < offset ? 0 : offset
    do {
      try handle.seek(toOffset: start)
      let data = try handle.read(upToCount: readLimit) ?? Data()
      return (String(decoding: data, as: UTF8.self), start + UInt64(data.count))
    } catch { return nil }
  }

  /// The last `bytes` bytes of a file as text, for the newest part of a rotating log.
  package static func tail(_ url: URL, bytes: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    do {
      let size = try handle.seekToEnd()
      try handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
      return String(decoding: try handle.read(upToCount: bytes) ?? Data(), as: UTF8.self)
    } catch { return nil }
  }
}
