import CryptoKit
import Foundation

/// Streaming SHA-256 for files that can be gigabytes long.
package enum FileDigest {
  /// Hashes exactly `size` bytes; a file that grows or shrinks while being read is rejected.
  package static func sha256(of url: URL, size: Int) throws(LauncherError) -> String {
    do {
      let input = try FileHandle(forReadingFrom: url)
      defer { do { try input.close() } catch { print("Could not close \(url.lastPathComponent)") } }
      var hash = SHA256()
      var remaining = size
      while let chunk = try input.read(upToCount: min(1_048_576, remaining + 1)), !chunk.isEmpty {
        guard chunk.count <= remaining else {
          throw LauncherError.operation("\(url.lastPathComponent) changed while it was read.")
        }
        remaining -= chunk.count
        hash.update(data: chunk)
      }
      guard remaining == 0 else {
        throw LauncherError.operation("\(url.lastPathComponent) changed while it was read.")
      }
      return hash.finalize().map { String(format: "%02x", $0) }.joined()
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }
}
