import Foundation

/// Describes a store client the player installs, signs into, and that starts the game.
///
/// Need for Speed (2015) is activated by Denuvo through EA's client: the game exits without
/// it. The app therefore depends on the player's own EA app rather than replacing any part
/// of it. Every path here is a recipe-declared, prefix-relative Windows location, so a new
/// client version or install location is configuration and not a code change.
package struct StoreClientPlan: Codable, Equatable, Sendable {
  /// The client's player-visible name, used in dependency messages.
  package let name: String
  /// The client's installation root inside the Windows prefix, which holds version folders.
  package let installRoot: String
  /// The window-owning client, relative to the resolved version folder.
  package let clientExecutable: String
  /// Arguments the client needs; the EA interface renders blank without `--in-process-gpu`.
  package let clientArguments: [String]
  /// The stub that hands a launch request to the running client.
  package let launcherExecutable: String
  /// The request template; `{offer}` is replaced by `offerID`.
  package let launchURL: String
  /// The store's identifier for this game.
  package let offerID: String
  /// Prefix-relative folders, below a Windows user profile, that exist once a player signs in.
  package let signInEvidence: [String]
  /// Prefix-relative locations, below a Windows user profile, the client touches when it starts.
  package let readinessEvidence: [String]
  /// The number of live helper processes the client must have before it is ready.
  ///
  /// The EA client renders its interface in separate `EACefSubProcess` children. A client
  /// without them is wedged and has to be restarted, so their presence is the readiness signal.
  package let readinessChildren: Int
  /// How long the session waits for the client to open its own window before giving up.
  package let readinessSeconds: Int
  /// The game's installation root inside the same Windows prefix.
  package let gameRoot: String

  package init(
    name: String, installRoot: String, clientExecutable: String, clientArguments: [String],
    launcherExecutable: String, launchURL: String, offerID: String, signInEvidence: [String],
    readinessEvidence: [String], readinessChildren: Int, readinessSeconds: Int, gameRoot: String
  ) {
    self.name = name
    self.installRoot = installRoot
    self.clientExecutable = clientExecutable
    self.clientArguments = clientArguments
    self.launcherExecutable = launcherExecutable
    self.launchURL = launchURL
    self.offerID = offerID
    self.signInEvidence = signInEvidence
    self.readinessEvidence = readinessEvidence
    self.readinessChildren = readinessChildren
    self.readinessSeconds = readinessSeconds
    self.gameRoot = gameRoot
  }

  /// The request handed to the launcher stub once the client is up.
  package var launchRequest: String {
    launchURL.replacingOccurrences(of: "{offer}", with: offerID)
  }

  /// Rejects an unsafe path, an unbounded wait, or an argument that is not a plain switch.
  package func validate() throws(LauncherError) {
    for path in [installRoot, clientExecutable, launcherExecutable, gameRoot] + signInEvidence
      + readinessEvidence
    {
      try ManifestFile.validate(path: path)
    }
    guard !name.isEmpty, name.utf8.count <= 64,
      !name.unicodeScalars.contains(where: { $0.value < 32 })
    else {
      throw .operation("The store client needs a plain name.")
    }
    guard (1...8).contains(clientArguments.count + 1),
      clientArguments.allSatisfy({
        $0.hasPrefix("--") && $0.utf8.count <= 64
          && $0.utf8.allSatisfy { (97...122).contains($0) || $0 == 45 }
      })
    else {
      throw .operation("The store client arguments must be plain long switches.")
    }
    guard launchURL.utf8.count <= 256, launchURL.contains("{offer}"),
      launchURL.hasPrefix("origin2://") || launchURL.hasPrefix("link2ea://"),
      !launchURL.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 })
    else {
      throw .operation("The store launch request must be a bounded store URL with an offer slot.")
    }
    guard (1...20).contains(offerID.utf8.count),
      offerID.utf8.allSatisfy({ (48...57).contains($0) })
    else {
      throw .operation("The store offer identifier must be a decimal number.")
    }
    guard (1...16).contains(signInEvidence.count), (1...16).contains(readinessEvidence.count),
      (0...64).contains(readinessChildren), (5...600).contains(readinessSeconds)
    else {
      throw .operation("The store client needs sign-in evidence and a bounded readiness wait.")
    }
  }
}
