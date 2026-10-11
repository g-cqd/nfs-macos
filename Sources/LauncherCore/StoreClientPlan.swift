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
  /// The request template; `{offer}` is replaced by the offer ids, joined with commas.
  package let launchURL: String
  /// The store's identifier, or identifiers, for this game.
  package let offerID: OfferIDs
  /// Prefix-relative folders, below a Windows user profile, that exist once a player signs in.
  package let signInEvidence: [String]
  /// The client's own diagnostic log, relative to the Windows drive, that tells when it is ready.
  package let readinessLog: String
  /// The text the client writes at the start of every run, so only the latest run is read.
  package let startMarker: String
  /// Telemetry event names that, all present after the start marker, mean the client is signed
  /// in and has finished booting.
  package let readyEvents: [String]
  /// How long one Play waits for the client to be ready. The client is never ended when this
  /// passes; the player is told what is missing and presses Play again.
  package let readinessSeconds: Int
  /// The game's installation root inside the same Windows prefix.
  package let gameRoot: String
  /// The executables the launch request starts, in order, for a game that starts through helper
  /// processes before its own; nil when the recipe does not say.
  package let launchChain: [String]?
  /// The launch chain executable the session lease follows; it must be one of `launchChain`.
  package let leaseTarget: String?
  /// Loopback ports whose availability the launch checks beforehand.
  package let expectedPorts: [Int]?

  package init(
    name: String, installRoot: String, clientExecutable: String, clientArguments: [String],
    launcherExecutable: String, launchURL: String, offerID: OfferIDs, signInEvidence: [String],
    readinessLog: String, startMarker: String, readyEvents: [String], readinessSeconds: Int,
    gameRoot: String, launchChain: [String]? = nil, leaseTarget: String? = nil,
    expectedPorts: [Int]? = nil
  ) {
    self.name = name
    self.installRoot = installRoot
    self.clientExecutable = clientExecutable
    self.clientArguments = clientArguments
    self.launcherExecutable = launcherExecutable
    self.launchURL = launchURL
    self.offerID = offerID
    self.signInEvidence = signInEvidence
    self.readinessLog = readinessLog
    self.startMarker = startMarker
    self.readyEvents = readyEvents
    self.readinessSeconds = readinessSeconds
    self.gameRoot = gameRoot
    self.launchChain = launchChain
    self.leaseTarget = leaseTarget
    self.expectedPorts = expectedPorts
  }

  /// The longest launch request, with every offer id in place, the recipe may produce.
  static let maximumLaunchRequest = 512

  /// The request handed to the launcher stub once the client is up.
  package var launchRequest: String {
    launchURL.replacingOccurrences(of: "{offer}", with: offerID.ids.joined(separator: ","))
  }

  /// Rejects an unsafe path, an unbounded wait, or an argument that is not a plain switch.
  package func validate() throws(LauncherError) {
    for path in [installRoot, clientExecutable, launcherExecutable, gameRoot, readinessLog]
      + signInEvidence
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
    try offerID.validate()
    guard launchRequest.utf8.count <= Self.maximumLaunchRequest else {
      throw .operation("The expanded store launch request is too long.")
    }
    guard (1...16).contains(signInEvidence.count), (5...600).contains(readinessSeconds) else {
      throw .operation("The store client needs sign-in evidence and a bounded readiness wait.")
    }
    guard (1...128).contains(startMarker.utf8.count), !startMarker.contains("\n"),
      (1...8).contains(readyEvents.count),
      readyEvents.allSatisfy({
        (1...64).contains($0.utf8.count)
          && $0.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95
          }
      })
    else {
      throw .operation("The store client needs a start marker and plain ready event names.")
    }
    try validateLaunchChain()
  }

  /// The optional launch chain, lease target and ports, with the packager's bounds.
  private func validateLaunchChain() throws(LauncherError) {
    if let launchChain {
      guard (1...8).contains(launchChain.count), launchChain.allSatisfy(Self.isExecutableName),
        Set(launchChain.map { $0.lowercased() }).count == launchChain.count
      else {
        throw .operation("The launch chain must be 1-8 distinct plain executable names.")
      }
    }
    if let leaseTarget {
      guard let launchChain,
        launchChain.contains(where: { $0.lowercased() == leaseTarget.lowercased() })
      else {
        throw .operation("The lease target must be one of the launch chain executables.")
      }
    }
    if let expectedPorts {
      guard (1...8).contains(expectedPorts.count),
        expectedPorts.allSatisfy({ (1024...65535).contains($0) }),
        Set(expectedPorts).count == expectedPorts.count
      else {
        throw .operation("Expected ports must be 1-8 distinct unprivileged port numbers.")
      }
    }
  }

  /// `[A-Za-z0-9._-]{1,64}` followed by `.exe` in any letter case, matched in full.
  static func isExecutableName(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard (5...68).contains(bytes.count), value.lowercased().hasSuffix(".exe") else {
      return false
    }
    return bytes.dropLast(4).allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || [46, 95, 45].contains($0)
    }
  }
}

/// One store offer id, or a bounded list of distinct ones, as the launch request joins them.
///
/// A recipe writes one id as a string, the form every shipped recipe uses, and several as an
/// array. A single id is encoded back as a string, so a manifest that names one stays the same.
package struct OfferIDs: Codable, Equatable, Sendable, ExpressibleByStringLiteral,
  ExpressibleByArrayLiteral
{
  package let ids: [String]

  package init(_ id: String) { ids = [id] }
  package init(_ ids: [String]) { self.ids = ids }
  package init(stringLiteral value: String) { self.init(value) }
  package init(arrayLiteral elements: String...) { self.init(elements) }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let id = try? container.decode(String.self) {
      ids = [id]
    } else {
      ids = try container.decode([String].self)
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    if ids.count == 1 { try container.encode(ids[0]) } else { try container.encode(ids) }
  }

  /// 1...32 distinct decimal ids of 1...20 digits each.
  package func validate() throws(LauncherError) {
    guard (1...32).contains(ids.count), Set(ids).count == ids.count,
      ids.allSatisfy({ id in
        (1...20).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) }
      })
    else {
      throw .operation(
        "The store offer identifier must be a decimal number or a bounded list of them.")
    }
  }
}
