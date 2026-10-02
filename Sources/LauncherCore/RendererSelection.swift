import Foundation

/// Which runtime backend serves a graphics API, optionally for one executable only.
///
/// The runtime carries several implementations of the same API side by side, and the choice is
/// per title rather than universal: a Direct3D 9 game wants mtld3d, and a Direct3D 11 game
/// wants whichever DXGI backend actually implements the features its engine uses. Keeping the
/// choice in the recipe means a measured result can change it without changing code, and the
/// per-executable form lets one runtime serve a store client and its game differently.
package struct RendererSelection: Codable, Equatable, Sendable {
  /// The compatibility-database key, such as `dxgi` or `d3d9`.
  package let api: String
  /// The implementation directory the runtime should load for that key.
  package let backend: String
  /// The executable this applies to, or nil for every process in the prefix.
  package let executable: String?
  /// Why this backend was chosen, carried into the bundle's provenance record.
  package let reason: String

  package init(api: String, backend: String, executable: String? = nil, reason: String = "") {
    self.api = api
    self.backend = backend
    self.executable = executable
    self.reason = reason
  }

  static let supportedAPIs = ["d3d8", "d3d9", "d3d10core", "d3d11", "dxgi"]

  package func validate() throws(LauncherError) {
    guard Self.supportedAPIs.contains(api) else {
      throw .operation("The bundle selects an unknown graphics API: \(api)")
    }
    guard (1...32).contains(backend.utf8.count),
      backend.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) })
    else {
      throw .operation("A renderer backend must be a plain lowercase name: \(backend)")
    }
    if let executable {
      guard (1...64).contains(executable.utf8.count), executable.hasSuffix(".exe"),
        executable.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || $0 == 46 || $0 == 95 || $0 == 45
        })
      else {
        throw .operation("A renderer rule applies to one Windows executable: \(executable)")
      }
    }
    guard reason.utf8.count <= 200,
      !reason.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 59 })
    else {
      throw .operation("The bundle declares an unusable renderer reason.")
    }
  }

  /// One compatibility-database rule line.
  func rule(name: String) -> String {
    "name=\(name);exe=\(executable ?? "*");\(api)=\(backend)"
  }

  /// Renders the complete `WINE_COMPATDB` value for a game's declared selections.
  package static func compatibilityDatabase(_ selections: [RendererSelection], kind: GameKind)
    throws(LauncherError) -> String
  {
    guard (1...16).contains(selections.count) else {
      throw .operation("A bundle needs between one and sixteen renderer rules.")
    }
    var lines = ["v=3"]
    for (index, selection) in selections.enumerated() {
      try selection.validate()
      if let reason = kind.deniedRendererBackends[selection.backend] {
        // A backend known to crash this game must never reach a player's machine.
        throw .operation(
          "\(kind.title) cannot use the \(selection.backend) renderer: \(reason)")
      }
      lines.append(selection.rule(name: "\(kind.rawValue)-\(index)"))
    }
    return lines.joined(separator: "\n")
  }
}
