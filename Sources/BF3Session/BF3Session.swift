import AppKit
import CoreGraphics
import Darwin
import Foundation
import LauncherCore

/// The helper that does every Windows-side step of the Battlefield 3 app.
///
/// The starter runs one action per helper process: place the prepared prefix, start the EA app
/// in it and wait for its local service, open Battlelog in a Chromium-family browser with the
/// identity Battlelog accepts, report status, apply a settings preset, or stop the prefix's own
/// Wine server. `--plan` prints what each step would do and starts nothing.
struct BF3Session {
  let paths: AppPaths
  let options: SessionOptions
  let game: PreparedPrefixGame

  init(options: SessionOptions) throws {
    self.options = options
    paths = try AppPaths(bundle: options.bundle, support: options.support, game: .bf3)
    game = try PreparedPrefixGame.read(
      from: paths.resources.appendingPathComponent("game-manifest.json"))
    guard game.gameID == .bf3 else {
      throw LauncherError.operation("This helper belongs to a different game.")
    }
  }

  // MARK: Locations

  var placement: PreparedPrefixPlacement {
    PreparedPrefixPlacement(
      template: paths.resources.appendingPathComponent(game.prefix.path), manifest: game.prefix,
      version: game.version, data: paths.data)
  }
  var prefix: URL { options.developer.prefix ?? paths.prefix }
  var isPrepared: Bool { options.developer.prefix != nil || placement.isPlaced }
  var wine: URL {
    options.developer.runtime?.appendingPathComponent("bin/wine") ?? paths.wine
  }
  var wineServer: URL {
    options.developer.runtime?.appendingPathComponent("bin/wineserver") ?? paths.wineServer
  }
  var logs: URL { paths.support.appendingPathComponent("Logs") }
  var settingsURL: URL { paths.support.appendingPathComponent("settings.json") }
  var profile: URL { prefix.appendingPathComponent(game.settingsProfile) }

  struct Settings: Codable {
    var sidecar = true
  }

  var settings: Settings {
    (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))) ?? Settings()
  }

  func environment() throws -> [String: String] {
    var environment = try LaunchEnvironment.make(
      paths: paths, prefix: prefix,
      home: paths.support.appendingPathComponent("RuntimeHome/Player"),
      temporary: paths.support.appendingPathComponent("Temporary"), tuning: game.runtimeTuning,
      renderers: game.renderers, usesSidecar: settings.sidecar)
    if settings.sidecar, let sidecar = options.developer.sidecar {
      environment["ROSETTA_X87_PATH"] = sidecar.path
    }
    return environment
  }

  // MARK: Actions

  func run() throws -> Int32 {
    try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
    switch options.action {
    case "--plan": return try plan()
    case "--status": return status()
    case "--sidecar": return try setSidecar()
    default: break
    }
    return try SessionLock.withLock(at: paths.support.appendingPathComponent("session.lock")) {
      switch options.action {
      case "--prepare": return try prepare()
      case "--start-client": return try startClient()
      case "--open-store": return try openStore()
      case "--stop": return try stop()
      case "--preset": return try preset()
      default: throw LauncherError.operation("Unknown operation.")
      }
    }
  }

  func prepare() throws -> Int32 {
    guard options.developer.prefix == nil else {
      print("Using the developer prefix in place; nothing is placed.")
      return 0
    }
    if placement.isPlaced {
      print("The Windows folder is ready.")
      return 0
    }
    _ = try placement.place { print($0) }
    for problem in prefixProblems() { print("Check: \(problem)") }
    print("The Windows folder is ready.")
    return 0
  }

  /// The registry records and game-folder files the prefix must hold, as problems found.
  func prefixProblems(in root: URL? = nil) -> [String] {
    let root = root ?? prefix
    var problems: [String] = []
    var hives: [String: String] = [:]
    for record in game.prefixRegistry {
      if hives[record.hive] == nil {
        hives[record.hive] =
          (try? String(contentsOf: root.appendingPathComponent(record.hive), encoding: .utf8)) ?? ""
      }
      if !record.isRecorded(in: hives[record.hive] ?? "") {
        problems.append(
          "registry \(record.hive) [\(record.path)]\(record.name.map { " " + $0 } ?? "") is missing"
        )
      }
    }
    let gameFolder = root.appendingPathComponent("drive_c").appendingPathComponent(
      game.storeClient.gameRoot)
    for shim in game.gameShims {
      let url = gameFolder.appendingPathComponent(shim.path)
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
      let digest = size >= 0 ? (try? FileDigest.sha256(of: url, size: size)) : nil
      if digest != shim.sha256 {
        problems.append("game-folder file \(shim.path) differs or is missing")
      }
    }
    return problems
  }

  /// Whether this prefix's Wine server is up: its socket answers, or this runtime's server runs.
  func serverIsRunning() -> Bool {
    // Wine starts its server through the loader's own relative path, so both spellings count.
    let relative =
      wine.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("lib/wine").path + "/../../bin/wineserver"
    return PrefixActivity.serverIsRunning(prefix: prefix)
      || !PrefixActivity.running([wineServer.path, relative]).isEmpty
  }

  func requireRosetta() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
    process.arguments = ["-x86_64", "/usr/bin/true"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw LauncherError.operation(
        "Rosetta is not installed. Install it from the starter, then try again.")
    }
  }

  func startClient() throws -> Int32 {
    guard isPrepared else {
      throw LauncherError.operation("Prepare the Windows folder first.")
    }
    let service = game.storeBrowser.service
    let clientName = game.watchedPrograms[0]
    var started: Process?
    if serverIsRunning() {
      if PrefixActivity.running([clientName]).isEmpty {
        throw LauncherError.operation(
          "Windows programs of this app are still running without the \(game.storeClient.name). Press Stop, then try again."
        )
      }
      print("The \(game.storeClient.name) is already running.")
    } else {
      try requireRosetta()
      guard let executable = game.clientWindowsPath(prefix: prefix) else {
        throw LauncherError.operation(
          "The \(game.storeClient.name) is missing from the Windows folder.")
      }
      try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      for folder in ["RuntimeHome/Player", "Temporary"] {
        try FileManager.default.createDirectory(
          at: paths.support.appendingPathComponent(folder), withIntermediateDirectories: true)
      }
      let log = logs.appendingPathComponent("client-\(Self.timestamp()).log")
      guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
        throw LauncherError.operation("Could not create the client log.")
      }
      let output = try FileHandle(forWritingTo: log)
      let process = try ProcessCommand(
        executable: wine, arguments: [executable] + game.storeClient.clientArguments,
        directory: paths.support, environment: try environment()
      ).start(output: output)
      print(
        "Started the \(game.storeClient.name) (x87 sidecar \(settings.sidecar ? "on" : "off")); log \(log.lastPathComponent)."
      )
      started = process
    }
    print("Waiting for its local service. Sign in in the EA window if it asks.")
    let begin = Date()
    // The server needs a moment to appear; until then the started process alone counts.
    let alive = {
      Date().timeIntervalSince(begin) < 30 || started?.isRunning == true || serverIsRunning()
    }
    if let seconds = service.wait(stillStarting: alive) {
      print("The \(game.storeClient.name) local service answered after about \(seconds) s.")
      return 0
    }
    print("The local service did not answer yet. Sign in in the EA window, then open Battlelog.")
    return 2
  }

  func openStore() throws -> Int32 {
    let plan = game.storeBrowser
    let page = try plan.page(named: options.value)
    guard
      let browser = plan.browser(installed: {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
      })
    else {
      throw LauncherError.operation(
        "\(plan.name) needs a Chromium-family browser (Chrome, Chromium, Edge, Brave or Vivaldi). Safari blocks its call to the EA app."
      )
    }
    if !plan.service.answers() {
      print(
        "Note: the \(game.storeClient.name) is not answering yet; \(plan.name) will ask for it.")
    }
    let profile =
      options.developer.browserProfile ?? paths.support.appendingPathComponent(plan.profileFolder)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = plan.arguments(profile: profile, page: page)
    configuration.createsNewApplicationInstance = true
    configuration.activates = true
    configuration.addsToRecentItems = false
    let done = DispatchSemaphore(value: 0)
    let failure = OpenFailure()
    NSWorkspace.shared.openApplication(at: browser.url, configuration: configuration) { _, error in
      failure.set(error?.localizedDescription)
      done.signal()
    }
    guard done.wait(timeout: .now() + 30) == .success else {
      throw LauncherError.operation("The browser did not start in time.")
    }
    if let message = failure.message {
      throw LauncherError.operation("Could not open the browser: \(message)")
    }
    print("Opened \(page.title) in \(browser.url.deletingPathExtension().lastPathComponent).")
    return 0
  }

  func stop() throws -> Int32 {
    guard serverIsRunning() else {
      print("Nothing of this app is running.")
      return 0
    }
    let environment = try environment()
    try WineShutdown.stop { argument in
      try ProcessCommand(
        executable: wineServer, arguments: [argument], directory: paths.support,
        environment: environment
      ).run(output: .standardOutput)
    }
    print("Stopped the Windows side of this app.")
    return 0
  }

  func preset() throws -> Int32 {
    let name = options.value ?? "show"
    guard FileManager.default.fileExists(atPath: profile.path) else {
      throw LauncherError.operation(
        "The game has no settings yet: start it once from Battlelog and quit it, then apply a preset."
      )
    }
    let text = try String(contentsOf: profile, encoding: .utf8)
    let keys = Array(Set(game.presets.flatMap { $0.values.map(\.key) })).sorted()
    if name == "show" {
      for line in TextProfilePreset.lines(in: text, keys: keys) { print(line) }
      return 0
    }
    guard let preset = game.presets.first(where: { $0.name == name }) else {
      throw LauncherError.operation("There is no preset named \(name).")
    }
    if !PrefixActivity.running([game.storeClient.leaseTarget]).isEmpty {
      throw LauncherError.operation(
        "Quit the game first: it rewrites its settings when it exits.")
    }
    let result = preset.apply(to: text, display: Self.mainDisplay())
    let backup = profile.deletingLastPathComponent().appendingPathComponent(
      profile.lastPathComponent + ".bak-\(Self.timestamp())")
    try FileManager.default.copyItem(at: profile, to: backup)
    try Data(result.text.utf8).write(to: profile, options: .atomic)
    for key in result.missing { print("Not in this profile, left out: \(key)") }
    print("Applied \(preset.title). The previous settings are in \(backup.lastPathComponent).")
    for line in TextProfilePreset.lines(in: result.text, keys: preset.values.map(\.key)) {
      print(line)
    }
    return 0
  }

  func setSidecar() throws -> Int32 {
    guard let value = options.value, ["on", "off"].contains(value) else {
      throw LauncherError.operation("Use on or off.")
    }
    var current = settings
    current.sidecar = value == "on"
    try JSONEncoder().encode(current).write(to: settingsURL, options: .atomic)
    print("x87 sidecar \(value) for the next start of the \(game.storeClient.name).")
    return 0
  }

  /// One JSON line for the starter: what is prepared and running. Names only, never arguments.
  func status() -> Int32 {
    struct Status: Encodable {
      let prepared: Bool
      let server: Bool
      let service: Bool
      let running: [String]
      let sidecar: Bool
      let browser: String?
      let profile: Bool
    }
    let server = isPrepared && serverIsRunning()
    let browser = game.storeBrowser.browser(installed: {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    })
    let value = Status(
      prepared: isPrepared, server: server, service: server && game.storeBrowser.service.answers(),
      running: server ? PrefixActivity.running(game.watchedPrograms).sorted() : [],
      sidecar: settings.sidecar,
      browser: browser?.url.deletingPathExtension().lastPathComponent,
      profile: FileManager.default.fileExists(atPath: profile.path))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
    return 0
  }

  /// Everything the steps would do, with nothing started and nothing written but the support folder.
  func plan() throws -> Int32 {
    print("app: \(paths.bundle.lastPathComponent) (manifest \(game.version))")
    print("runtime: \(wine.path)\(options.developer.runtime == nil ? "" : " (developer override)")")
    print(
      "prefix: \(prefix.path)\(options.developer.prefix == nil ? "" : " (developer override, used in place)")"
    )
    print(
      "prepared: \(isPrepared); template \(game.prefix.files.count) files, \(game.prefix.bytes) bytes, \(game.prefix.links.count) links, \(game.prefix.attributes.count) attributes"
    )
    let root = isPrepared ? prefix : paths.resources.appendingPathComponent(game.prefix.path)
    let problems = prefixProblems(in: root)
    print(
      "prefix checks (\(root == prefix ? "prefix" : "template")): \(game.prefixRegistry.count) registry records, \(game.gameShims.count) game-folder files, \(problems.count) problems"
    )
    for problem in problems { print("  problem: \(problem)") }
    let environment = try environment()
    for name in environment.keys.sorted() where name != "WINE_COMPATDB" {
      print("env \(name)=\(environment[name] ?? "")")
    }
    print("env WINE_COMPATDB:")
    for line in (environment["WINE_COMPATDB"] ?? "").split(separator: "\n") { print("  \(line)") }
    let client = game.clientWindowsPath(prefix: root) ?? "(client not found)"
    print(
      "client: \(wine.lastPathComponent) \(([client] + game.storeClient.clientArguments).joined(separator: " "))"
    )
    print(
      "service: \(game.storeBrowser.service.url) (Origin \(game.storeBrowser.service.origin)), wait \(game.storeBrowser.service.seconds) s; answering now: \(game.storeBrowser.service.answers())"
    )
    print(
      "server running now: \(serverIsRunning()); watched programs: \(game.watchedPrograms.joined(separator: ", "))"
    )
    print(
      "running now: \(PrefixActivity.running(game.watchedPrograms).sorted().joined(separator: ", "))"
    )
    let browser = game.storeBrowser.browser(installed: {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    })
    print("browser: \(browser.map { "\($0.identifier) at \($0.url.path)" } ?? "none installed")")
    for page in game.storeBrowser.pages {
      let arguments = game.storeBrowser.arguments(
        profile: options.developer.browserProfile
          ?? paths.support.appendingPathComponent(game.storeBrowser.profileFolder), page: page)
      print("page \(page.name): open -n with \(arguments.joined(separator: " "))")
    }
    let display = Self.mainDisplay()
    print("display: \(display.width)x\(display.height)@\(display.refresh)")
    print(
      "settings profile: \(FileManager.default.fileExists(atPath: profile.path) ? "present" : "not yet created") (\(game.settingsProfile))"
    )
    for preset in game.presets {
      let values = preset.resolved(for: display).map { "\($0.key)=\($0.value)" }
      print("preset \(preset.name): \(values.joined(separator: " "))")
    }
    print("stop: \(wineServer.lastPathComponent) -k then -w for this prefix only")
    return 0
  }

  // MARK: Helpers

  static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  /// The main display's current mode in pixels (the desktop the game's full-screen mode matches).
  static func mainDisplay() -> TextProfilePreset.Display {
    let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
    let refresh = Int((mode?.refreshRate ?? 0).rounded())
    return TextProfilePreset.Display(
      width: mode?.pixelWidth ?? 1920, height: mode?.pixelHeight ?? 1200,
      refresh: refresh > 0 ? refresh : 60)
  }
}

/// The browser start's completion result, set once from AppKit's completion queue.
final class OpenFailure: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?
  func set(_ message: String?) { lock.withLock { value = message } }
  var message: String? { lock.withLock { value } }
}
