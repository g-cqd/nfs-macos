import Foundation
import LauncherCore

/// Validated display, quality and controller settings for Need for Speed (2015).
package struct NFS2015Settings: Codable, Equatable, Sendable {
  package var values: [String: String]

  package init() { values = [:] }

  /// Reads the supported options out of the game's own options file.
  ///
  /// An option the game wrote outside this app's offered domain is left alone rather than
  /// replaced, so an unusual setup is never silently normalized.
  package init(document: ProfileOptionsDocument) {
    self.init()
    for definition in NFS2015Catalog.settings {
      let written = definition.keys.map(document.value)
      if let value = definition.value(from: written) { values[definition.id] = value }
    }
  }

  package func value(_ id: String) -> String {
    values[id] ?? NFS2015Catalog.setting(id)?.defaultValue ?? ""
  }

  package func validate() throws(LauncherError) {
    guard values.count <= NFS2015Catalog.settings.count else {
      throw .operation("The setup contains too many settings.")
    }
    for (id, value) in values {
      guard let definition = NFS2015Catalog.setting(id), definition.accepts(value) else {
        throw .operation("The setup contains an unsupported setting value.")
      }
    }
  }

  /// The option-file replacements these settings represent.
  package func replacements() throws(LauncherError) -> [String: String] {
    try validate()
    var replacements: [String: String] = [:]
    for id in values.keys.sorted() {
      guard let definition = NFS2015Catalog.setting(id),
        let fileValues = definition.fileValues(for: value(id))
      else {
        throw .operation("The setup contains an unsupported setting value.")
      }
      for (key, written) in zip(definition.keys, fileValues) { replacements[key] = written }
    }
    return replacements
  }

  /// Rewrites only the managed values in the game's own options file.
  package func applying(to original: String) throws(LauncherError) -> String {
    try ProfileOptionsDocument(text: original).applying(try replacements())
  }
}
