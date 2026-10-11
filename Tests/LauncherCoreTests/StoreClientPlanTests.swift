import Foundation
import Testing

@testable import LauncherCore

/// The native side of the offer id and launch chain rules in `check_bf4_recipe_schema.py`.
struct StoreClientPlanTests {
  /// Thirty-two twenty-digit ids: each is valid, the expanded request is not.
  private static let longIDs = (10..<42).map { "1" + String(repeating: "0", count: 17) + "\($0)" }

  private func plan(
    url: String = "origin2://game/launch/?offerIds={offer}",
    offer: OfferIDs = ["1000001", "1000002", "1000003"],
    chain: [String]? = ["Launcher64.exe", "WebHelper.exe", "Game64.exe"],
    lease: String? = "Game64.exe", ports: [Int]? = [3215, 3216]
  ) -> StoreClientPlan {
    StoreClientPlan(
      name: "EA app", installRoot: "Program Files/Electronic Arts/EA Desktop",
      clientExecutable: "EA Desktop/EADesktop.exe", clientArguments: ["--in-process-gpu"],
      launcherExecutable: "EA Desktop/EALauncher.exe", launchURL: url, offerID: offer,
      signInEvidence: ["AppData/Local/Electronic Arts/EA Desktop"],
      readinessLog: "ProgramData/EA Desktop/Logs/EADesktop.log", startMarker: "[STARTUP]",
      readyEvents: ["login", "client.boot.ready"], readinessSeconds: 180,
      gameRoot: "Program Files/EA Games/Sample 64", launchChain: chain, leaseTarget: lease,
      expectedPorts: ports)
  }

  @Test
  func `a list of offer ids is joined with commas in the launch request`() throws {
    let candidate = plan()
    try candidate.validate()
    #expect(candidate.launchRequest == "origin2://game/launch/?offerIds=1000001,1000002,1000003")
  }

  @Test(arguments: [
    OfferIDs("1"), OfferIDs(String(repeating: "1", count: 20)), OfferIDs(["1"]),
    OfferIDs([String(repeating: "1", count: 20)]), OfferIDs((0..<32).map { String(1000 + $0) }),
  ])
  func `one id or up to thirty-two distinct ids validate`(offer: OfferIDs) throws {
    try plan(offer: offer).validate()
  }

  @Test(arguments: [
    OfferIDs([]), OfferIDs(""), OfferIDs("abc"), OfferIDs(String(repeating: "1", count: 21)),
    OfferIDs(["1", String(repeating: "1", count: 21)]), OfferIDs(["1", ""]),
    OfferIDs((0..<33).map { String(100 + $0) }), OfferIDs(["5", "5"]), OfferIDs(["-5"]),
    OfferIDs(["1,2"]), OfferIDs(longIDs),
  ])
  func `unbounded, duplicate or non-decimal offer ids are refused`(offer: OfferIDs) {
    #expect(throws: LauncherError.self) { try plan(offer: offer).validate() }
  }

  @Test
  func `the launch request still needs its offer slot`() {
    #expect(throws: LauncherError.self) {
      try plan(url: "origin2://game/launch/?offerIds=1").validate()
    }
  }

  @Test(arguments: [
    [], (0..<9).map { "A\($0).exe" }, ["../Game64.exe"], ["bin/Game64.exe"], ["bin\\Game64.exe"],
    ["Game64.dll"], [""], ["Game\n64.exe"], [String(repeating: "a", count: 70) + ".exe"],
    ["Game64.exe", "GAME64.EXE"],
  ])
  func `an unbounded or unsafe launch chain is refused`(chain: [String]) {
    let lease = chain.first { $0 == "Game64.exe" }
    #expect(throws: LauncherError.self) { try plan(chain: chain, lease: lease).validate() }
  }

  @Test
  func `the lease target must be in the launch chain, ignoring case`() throws {
    try plan(lease: "GAME64.EXE").validate()
    #expect(throws: LauncherError.self) { try plan(chain: nil, lease: "Game64.exe").validate() }
    #expect(throws: LauncherError.self) { try plan(lease: "Other.exe").validate() }
    #expect(throws: LauncherError.self) { try plan(lease: "../Game64.exe").validate() }
  }

  @Test(arguments: [
    [], Array(3000..<3009), [80], [0], [65536], [-3215], [3215, 3215],
  ])
  func `ports outside the unprivileged range or repeated are refused`(ports: [Int]) {
    #expect(throws: LauncherError.self) { try plan(ports: ports).validate() }
  }

  @Test
  func `the shipped single-id shape decodes and encodes unchanged`() throws {
    let single = plan(offer: "1024486", chain: nil, lease: nil, ports: nil)
    try single.validate()
    let encoded = String(decoding: try JSONEncoder().encode(single), as: UTF8.self)
    #expect(encoded.contains(#""offerID":"1024486""#))
    for key in ["launchChain", "leaseTarget", "expectedPorts"] { #expect(!encoded.contains(key)) }
    let decoded = try JSONDecoder().decode(StoreClientPlan.self, from: Data(encoded.utf8))
    #expect(decoded == single)
    #expect(decoded.launchRequest == "origin2://game/launch/?offerIds=1024486")
  }

  @Test
  func `a list of ids and the launch chain round-trip through JSON`() throws {
    let listed = plan()
    let encoded = try JSONEncoder().encode(listed)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(text.contains(#""offerID":["1000001","1000002","1000003"]"#))
    let decoded = try JSONDecoder().decode(StoreClientPlan.self, from: encoded)
    #expect(decoded == listed)
    #expect(decoded.expectedPorts == [3215, 3216])
  }

  @Test
  func `an offer id that is neither text nor a list of text does not decode`() {
    for value in ["5", "[1]", "{\"1\":\"2\"}", "[[\"1\"]]", "[\"1\",null]"] {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(OfferIDs.self, from: Data(value.utf8))
      }
    }
  }
}
