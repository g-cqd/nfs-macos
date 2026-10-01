import Foundation

package enum BoundedFile {
  package static func read(_ url: URL, limit: Int = 1_048_576) throws(LauncherError) -> Data {
    do {
      let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard metadata.isRegularFile == true, let size = metadata.fileSize, size <= limit else {
        throw LauncherError.operation("Invalid or oversized file: \(url.lastPathComponent).")
      }
      let handle = try FileHandle(forReadingFrom: url)
      defer {
        do { try handle.close() } catch {
          print("Could not close \(url.lastPathComponent): \(error)")
        }
      }
      let data = try handle.read(upToCount: limit + 1) ?? Data()
      guard data.count <= limit else {
        throw LauncherError.operation("File grew beyond the supported size.")
      }
      return data
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }

  package static func text(_ url: URL, limit: Int = 1_048_576) throws(LauncherError) -> String {
    guard let text = String(data: try read(url, limit: limit), encoding: .utf8) else {
      throw .operation("Invalid UTF-8 configuration: \(url.lastPathComponent).")
    }
    return text
  }
}
