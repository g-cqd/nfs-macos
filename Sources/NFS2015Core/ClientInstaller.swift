import Foundation
import LauncherCore

/// Checks the EA app installer a player chose before the bundled runtime starts it.
///
/// The app never downloads, ships or alters an installer: the player gets it from ea.com and
/// picks the file. It then runs inside the app's own Windows folder with the rights of any other
/// program the player starts, so this only refuses what cannot be a Windows installer at all.
package enum ClientInstaller {
  /// The smallest and largest plausible installer; the EA app's is a few hundred megabytes.
  static let sizeRange = 1_000_000...2_000_000_000

  /// - Returns: The installer's standardized location, safe to hand to Wine as a host path.
  /// - Throws: A failure naming why the file cannot be used.
  package static func validate(_ url: URL) throws(LauncherError) -> URL {
    let url = url.standardizedFileURL
    guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count <= 1024,
      !url.path.unicodeScalars.contains(where: { $0.value < 32 }),
      url.pathExtension.lowercased() == "exe"
    else {
      throw .operation(
        "Choose the EA app installer you downloaded from ea.com; it is an .exe file.")
    }
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
    } catch {
      throw .operation("Could not read the installer: \(error.localizedDescription)")
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, sizeRange.contains(size)
    else {
      throw .operation("That file is not a Windows installer of a plausible size.")
    }
    let header: Data
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer {
        do { try handle.close() } catch { print("Could not close the installer: \(error)") }
      }
      header = try handle.read(upToCount: 2) ?? Data()
    } catch {
      throw .operation("Could not read the installer: \(error.localizedDescription)")
    }
    guard header == Data("MZ".utf8) else {
      throw .operation("That file is not a Windows program.")
    }
    return url
  }
}
