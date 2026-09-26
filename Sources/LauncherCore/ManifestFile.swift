import Foundation

/// One regular game file and its expected size and SHA-256 digest.
package struct ManifestFile: Codable {
  let path: String
  let size: Int
  let sha256: String

  static func validate(path: String) throws(LauncherError) {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, path.utf8.count <= 512, !path.contains("\\"),
      !path.unicodeScalars.contains(where: { $0.value < 32 }),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw .operation("The game manifest contains an unsafe file path.")
    }
  }
}
