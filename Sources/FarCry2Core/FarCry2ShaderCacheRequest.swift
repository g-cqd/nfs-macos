import Foundation
import LauncherCore

/// A shader cache operation the starter asks the session helper to run under its lock.
package struct FarCry2ShaderCacheRequest: Codable, Equatable, Sendable {
  package enum Action: String, Codable, Sendable {
    /// Delete every saved cache so the next launch compiles from scratch.
    case reset
    /// Write the saved cache to `path`.
    case export
    /// Add the cache in the export at `path` to the saved one.
    case `import`
  }

  package let action: Action
  package let path: String?

  package init(action: Action, path: String? = nil) {
    self.action = action
    self.path = path
  }

  /// The file for an export or import; reset takes none, and no other operation may carry one.
  package func file() throws(LauncherError) -> URL? {
    switch (action, path) {
    case (.reset, nil): return nil
    case (.export, let path?), (.import, let path?):
      let url = URL(fileURLWithPath: path)
      guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
        url.pathExtension == ShaderCacheExport.fileExtension
      else { throw .operation("Choose a .\(ShaderCacheExport.fileExtension) file.") }
      return url
    default: throw .operation("The shader cache request is not valid.")
    }
  }
}
