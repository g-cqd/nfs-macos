import Foundation
import Testing

@testable import LauncherCore

/// The prepared-prefix bundle shape (Battlefield 3): its manifest rules, the placement of the
/// template, the store browser plan, the loopback probe, presets and the process matcher.
struct PreparedPrefixTests {
  private static let digestOfEmpty =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  private func sha(_ text: String) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try FileDigest.sha256(of: url, size: text.utf8.count)
  }

  private func template() throws -> (URL, PreparedPrefix) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "prepared-\(UUID().uuidString)")
    let files = [
      "system.reg": "[Software\\\\Wine]\n", "drive_c/game/bf3.exe": "MZ", ".update-timestamp": "",
    ]
    var entries: [PreparedPrefix.File] = []
    for (path, text) in files {
      let url = root.appendingPathComponent("Game").appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
      entries.append(.init(path: path, size: text.utf8.count, sha256: try sha(text)))
    }
    let manifest = PreparedPrefix(
      path: "Game", files: entries.sorted { $0.path < $1.path },
      emptyDirectories: ["drive_c/users/crossover/Desktop"],
      links: [.init(path: "dosdevices/c:", target: "../drive_c")],
      attributes: [
        .init(
          path: "drive_c/game/bf3.exe", name: "user.DOSATTRIB",
          value: Data("0x20".utf8).base64EncodedString())
      ])
    return (root, manifest)
  }

  @Test
  func `the store client's own updater folder names are recognised as versions`() {
    for name in ["13.805.2.6319", "13.805.11.6320-1791598480", "1.0"] {
      #expect(PreparedPrefixGame.isClientVersionFolder(name), "\(name)")
    }
    for name in [
      "", ".", "13.805.", ".13", "EA Desktop", "13.805.2.6319-", "-1791598480",
      "13.805-1-2", "13.805.2.6319-abc", "../13.805.2",
    ] {
      #expect(!PreparedPrefixGame.isClientVersionFolder(name), "\(name)")
    }
  }

  @Test
  func `a template is placed, linked, attributed, verified and published once`() throws {
    let (root, manifest) = try template()
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("Support/Data")
    let placement = PreparedPrefixPlacement(
      template: root.appendingPathComponent("Game"), manifest: manifest,
      version: "0123456789abcdef01234567", data: data, freeSpace: { _ in Int.max })
    let prefix = try placement.place()
    #expect(placement.isPlaced)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: prefix.appendingPathComponent("dosdevices/c:").path) == "../drive_c")
    #expect(
      FileManager.default.fileExists(
        atPath: prefix.appendingPathComponent("drive_c/users/crossover/Desktop").path))
    var buffer = [UInt8](repeating: 0, count: 16)
    let count = getxattr(
      prefix.appendingPathComponent("drive_c/game/bf3.exe").path, "user.DOSATTRIB", &buffer, 16, 0,
      XATTR_NOFOLLOW)
    #expect(count == 4)
    // A second placement returns the published prefix and changes nothing.
    #expect(try placement.place() == prefix)
  }

  @Test
  func `a changed template file publishes nothing`() throws {
    let (root, manifest) = try template()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("ZM".utf8).write(to: root.appendingPathComponent("Game/drive_c/game/bf3.exe"))
    let data = root.appendingPathComponent("Support/Data")
    let placement = PreparedPrefixPlacement(
      template: root.appendingPathComponent("Game"), manifest: manifest,
      version: "0123456789abcdef01234567", data: data, freeSpace: { _ in Int.max })
    #expect(throws: LauncherError.self) { try placement.place() }
    #expect(!FileManager.default.fileExists(atPath: data.path))
    #expect(!FileManager.default.fileExists(atPath: placement.stage.path))
  }

  @Test
  func `an extra file in the template is refused`() throws {
    let (root, manifest) = try template()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("Game/drive_c/extra.txt"))
    let placement = PreparedPrefixPlacement(
      template: root.appendingPathComponent("Game"), manifest: manifest,
      version: "0123456789abcdef01234567", data: root.appendingPathComponent("Support/Data"),
      freeSpace: { _ in Int.max })
    #expect(throws: LauncherError.self) { try placement.place() }
  }

  @Test
  func `too little space across volumes is refused before copying`() throws {
    let (root, manifest) = try template()
    defer { try? FileManager.default.removeItem(at: root) }
    let placement = PreparedPrefixPlacement(
      template: root.appendingPathComponent("Game"), manifest: manifest,
      version: "0123456789abcdef01234567", data: root.appendingPathComponent("Support/Data"),
      freeSpace: { _ in 1 })
    #expect(throws: LauncherError.self) { try placement.place() }
  }

  @Test
  func `only Wine's own links and attributes are accepted`() {
    let file = PreparedPrefix.File(path: "system.reg", size: 0, sha256: Self.digestOfEmpty)
    let drive = PreparedPrefix.File(path: "drive_c/a", size: 0, sha256: Self.digestOfEmpty)
    #expect(throws: Never.self) {
      try PreparedPrefix(path: "Game", files: [file, drive]).validate()
    }
    #expect(throws: LauncherError.self) {
      try PreparedPrefix(
        path: "Game", files: [file, drive], links: [.init(path: "dosdevices/d:", target: "/Users")]
      ).validate()
    }
    #expect(throws: LauncherError.self) {
      try PreparedPrefix(
        path: "Game", files: [file, drive],
        attributes: [.init(path: "drive_c/a", name: "com.apple.quarantine", value: "")]
      ).validate()
    }
    #expect(throws: LauncherError.self) {
      try PreparedPrefix(path: "Game", files: [drive]).validate()
    }
    #expect(throws: LauncherError.self) {
      try PreparedPrefix(path: "../Game", files: [file, drive]).validate()
    }
  }

  private let service = LocalServiceProbe(
    url: "http://127.0.0.1:3215/ping", origin: "https://battlelog.battlefield.com", reply: "pong",
    seconds: 180)

  private func browser(
    url: String = "https://battlelog.battlefield.com/bf3/campaign/",
    agent: String =
      "Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
    profile: String = "BrowserProfile", probe: LocalServiceProbe? = nil
  ) -> StoreBrowserPlan {
    StoreBrowserPlan(
      name: "Battlelog",
      pages: [
        .init(name: "singleplayer", title: "Campaign", url: url),
        .init(
          name: "multiplayer", title: "Multiplayer", url: "https://battlelog.battlefield.com/bf3/"),
      ],
      userAgent: agent, browsers: ["com.google.Chrome", "org.chromium.Chromium"],
      profileFolder: profile, service: probe ?? service)
  }

  @Test
  func `the browser gets its own profile, the identity and the page`() throws {
    let plan = browser()
    try plan.validate()
    let page = try plan.page(named: "singleplayer")
    let arguments = plan.arguments(profile: URL(fileURLWithPath: "/tmp/P"), page: page)
    #expect(arguments.first == "--user-data-dir=/tmp/P")
    #expect(arguments.contains("--user-agent=\(plan.userAgent)"))
    #expect(arguments.last == "https://battlelog.battlefield.com/bf3/campaign/")
    #expect(try plan.page(named: nil).name == "singleplayer")
    #expect(throws: LauncherError.self) { try plan.page(named: "coop") }
    let chosen = plan.browser {
      $0 == "org.chromium.Chromium" ? URL(fileURLWithPath: "/Applications/Chromium.app") : nil
    }
    #expect(chosen?.identifier == "org.chromium.Chromium")
    #expect(plan.browser { _ in nil } == nil)
  }

  @Test
  func `unsafe store pages, identities, profiles and services are refused`() {
    #expect(throws: LauncherError.self) {
      try browser(url: "http://battlelog.battlefield.com/").validate()
    }
    #expect(throws: LauncherError.self) {
      try browser(agent: "Mozilla \"x\" 0123456789").validate()
    }
    #expect(throws: LauncherError.self) { try browser(profile: "../Profile").validate() }
    let remote = LocalServiceProbe(
      url: "http://example.com:3215/ping", origin: "https://battlelog.battlefield.com",
      reply: "pong",
      seconds: 180)
    #expect(throws: LauncherError.self) { try browser(probe: remote).validate() }
    let privileged = LocalServiceProbe(
      url: "http://127.0.0.1:80/ping", origin: "https://battlelog.battlefield.com", reply: "pong",
      seconds: 180)
    #expect(throws: LauncherError.self) { try browser(probe: privileged).validate() }
    let elsewhere = LocalServiceProbe(
      url: "http://127.0.0.1:3215/ping", origin: "https://battlelog.battlefield.com", reply: "pong",
      seconds: 180, gameURL: "http://127.0.0.1:4215/game/status", gameReply: "INSTALLED")
    #expect(throws: LauncherError.self) { try browser(probe: elsewhere).validate() }
    let halfDeclared = LocalServiceProbe(
      url: "http://127.0.0.1:3215/ping", origin: "https://battlelog.battlefield.com", reply: "pong",
      seconds: 180, gameURL: "http://127.0.0.1:3215/game/status")
    #expect(throws: LauncherError.self) { try browser(probe: halfDeclared).validate() }
  }

  @Test
  func `a closed loopback port does not answer`() {
    let probe = LocalServiceProbe(
      url: "http://127.0.0.1:1/ping", origin: "https://battlelog.battlefield.com", reply: "pong",
      seconds: 5)
    #expect(!probe.answers(timeout: 1))
    #expect(probe.state() == .notAnswering)
  }

  @Test
  func `a preset replaces existing lines only and resolves the display`() throws {
    let preset = TextProfilePreset(
      name: "fullscreen", title: "Full Screen",
      values: [
        .init(key: "GstRender.FullscreenEnabled", value: "1"),
        .init(key: "GstRender.ResolutionWidth", value: "{display.width}"),
        .init(key: "GstRender.ResolutionHertz", value: "{display.refresh}"),
        .init(key: "GstRender.Missing", value: "0"),
      ], reason: "Not verified")
    try preset.validate()
    let text =
      "GstRender.FullscreenEnabled 0\r\nGstRender.ResolutionWidth 2560\r\nGstGame.Other 7\r\nGstRender.ResolutionHertz 60\r\n"
    let result = preset.apply(to: text, display: .init(width: 3360, height: 2100, refresh: 120))
    #expect(
      result.text
        == "GstRender.FullscreenEnabled 1\r\nGstRender.ResolutionWidth 3360\r\nGstGame.Other 7\r\nGstRender.ResolutionHertz 120\r\n"
    )
    #expect(result.missing == ["GstRender.Missing"])
    #expect(
      TextProfilePreset.lines(in: result.text, keys: ["GstGame.Other"]) == ["GstGame.Other 7"])
    let bad = TextProfilePreset(
      name: "x", title: "X", values: [.init(key: "A B", value: "1")], reason: "r")
    #expect(throws: LauncherError.self) { try bad.validate() }
  }

  @Test
  func `processes are matched by whole executable name and never by argument text`() {
    let listing = """
      C:\\Program Files\\EA Games\\Battlefield 3\\bf3.exe -webMode SP -AuthCode secret
      /opt/wine/bin/wineserver
      notbf3.exe
      C:\\windows\\system32\\PnkBstrB.exe
      """
    let found = PrefixActivity.matches(
      listing, names: ["bf3.exe", "PnkBstrB.exe", "EADesktop.exe", "/opt/wine/bin/wineserver"])
    #expect(found == ["bf3.exe", "PnkBstrB.exe", "/opt/wine/bin/wineserver"])
    #expect(PrefixActivity.matches("notbf3.exe\n", names: ["bf3.exe"]).isEmpty)
  }

  @Test
  func `registry records find keys and values the way Wine writes them`() {
    let hive = """
      [Software\\\\Wine\\\\AppDefaults\\\\bf3.exe\\\\DllOverrides] 1760000000
      #time=1dc000000000000
      "d3d11"="native,builtin"

      [Software\\\\Classes\\\\PROTOCOLS\\\\Handler\\\\res] 1760000000
      @="{3050F3BC-98B5-11CF-BB82-00AA00BDCE0B}"
      """
    let value = PreparedPrefixGame.RegistryRecord(
      hive: "user.reg", path: "Software\\Wine\\AppDefaults\\bf3.exe\\DllOverrides", name: "d3d11",
      reason: "r")
    let key = PreparedPrefixGame.RegistryRecord(
      hive: "system.reg", path: "Software\\Classes\\PROTOCOLS\\Handler\\res", reason: "r")
    let absent = PreparedPrefixGame.RegistryRecord(
      hive: "user.reg", path: "Software\\Wine\\AppDefaults\\bf3.exe\\DllOverrides", name: "dxgi",
      reason: "r")
    #expect(value.isRecorded(in: hive))
    #expect(key.isRecorded(in: hive))
    #expect(!absent.isRecorded(in: hive))
  }

  @Test
  func `the Battlefield 3 overrides keep mshtml for the res protocol`() {
    #expect(LaunchEnvironment.overrides(.bf3) == "IGOProxy32.exe=d;winemenubuilder.exe=d")
    #expect(GameKind.bf3.requiresStoreClient && !GameKind.bf3.copiesGameData)
  }
}
