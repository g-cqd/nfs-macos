import Foundation
import LauncherCore

/// The catalog's options as the game's own options file currently records them.
package struct NFS2015Settings: Codable, Equatable, Sendable {
  /// The options whose recorded value is one this app offers, by setting identifier.
  package var values: [String: String]
  /// The options whose value is shown but not changed: a setting this app does not edit, or a
  /// value outside the offered domain. The text is exactly what the game wrote.
  package var observed: [String: String]

  package init() {
    values = [:]
    observed = [:]
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    values = try container.decode([String: String].self, forKey: .values)
    observed = try container.decodeIfPresent([String: String].self, forKey: .observed) ?? [:]
  }

  /// Reads the catalog's options out of the game's own options file.
  ///
  /// An option the game wrote outside this app's offered domain is shown and left alone rather
  /// than replaced, so an unusual setup is never silently normalized.
  package init(document: ProfileOptionsDocument) {
    self.init()
    for definition in NFS2015Catalog.settings {
      let written = definition.keys.map(document.value)
      if let value = definition.value(from: written) {
        values[definition.id] = value
      } else if let text = definition.recordedText(from: written) {
        observed[definition.id] = text
      }
    }
  }

  /// The recorded value, or the catalog default for an option the game has not written.
  package func value(_ id: String) -> String {
    values[id] ?? NFS2015Catalog.setting(id)?.defaultValue ?? ""
  }

  /// Whether the game's file holds a value for this option that the app can change.
  package func isPresent(_ id: String) -> Bool { values[id] != nil }

  package func validate() throws(LauncherError) {
    guard values.count <= NFS2015Catalog.settings.count,
      observed.count <= NFS2015Catalog.settings.count
    else {
      throw .operation("The setup contains too many settings.")
    }
    for (id, value) in values {
      guard let definition = NFS2015Catalog.setting(id), definition.accepts(value) else {
        throw .operation("The setup contains an unsupported setting value.")
      }
    }
  }

  /// The option-file replacements a set of chosen values represents.
  /// - Parameter changes: Setting identifier to the value chosen for it.
  /// - Throws: A failure for an unknown or read-only setting, or a value outside its domain.
  package static func replacements(for changes: [String: String]) throws(LauncherError)
    -> [String: String]
  {
    guard changes.count <= NFS2015Catalog.settings.count else {
      throw .operation("The request contains too many settings.")
    }
    var replacements: [String: String] = [:]
    for id in changes.keys.sorted() {
      guard let definition = NFS2015Catalog.setting(id), definition.isEditable else {
        throw .operation("The request contains a setting this app does not change.")
      }
      guard let value = changes[id], let fileValues = definition.fileValues(for: value) else {
        throw .operation("\(definition.title) is outside the range this app accepts.")
      }
      for (key, written) in zip(definition.keys, fileValues) { replacements[key] = written }
    }
    return replacements
  }

  private enum CodingKeys: String, CodingKey { case values, observed }
}
