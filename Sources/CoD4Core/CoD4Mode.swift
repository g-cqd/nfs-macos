/// Separates campaign and multiplayer configuration files and executable selection.
package enum CoD4Mode: String, Codable, Sendable, CaseIterable, Identifiable {
  case singlePlayer, multiplayer
  package var id: String { rawValue }
  package var title: String { self == .singlePlayer ? "Campaign" : "Multiplayer" }
  package var executable: String { self == .singlePlayer ? "iw3sp.exe" : "iw3mp.exe" }
  package var configuration: String { self == .singlePlayer ? "config.cfg" : "config_mp.cfg" }
}
