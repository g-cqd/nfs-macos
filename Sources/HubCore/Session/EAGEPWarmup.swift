import CryptoKit
import Darwin
import Foundation

/// The identity of a runtime's x86 Mach-O files, as Rosetta's translation cache sees them.
///
/// Rosetta keeps its ahead-of-time (AOT) translation of each x86 Mach-O file in `/var/db/oah`,
/// keyed by the file on disk and not by its content: a copied, reinstalled or replaced file is
/// translated again on first use. The stamp therefore records the device, inode, size and
/// modification time of every Mach-O file under the Wine tree's `bin` and `lib`, and the tree's
/// own resolved path, so it changes whenever one of them is a different file or the tree moved.
package struct RuntimeTranslationStamp: Codable, Equatable, Sendable {
  package let schemaVersion: Int
  /// SHA-256 of the tree's resolved path, then one `path dev inode size mtime` line per Mach-O
  /// file, sorted by path.
  package let digest: String
  /// How many Mach-O files the digest covers.
  package let files: Int

  package static let currentSchemaVersion = 1

  /// Reads the stamp of the Wine tree `wine` (the folder with `bin` and `lib`).
  ///
  /// - Throws: `.invalid` when `wine` has no Mach-O file at all; `.io` when a folder cannot be read.
  package static func of(wine: URL) throws(HubError) -> RuntimeTranslationStamp {
    var lines: [String] = []
    for top in ["bin", "lib"] {
      let root = wine.appendingPathComponent(top).path
      // The walk does not follow links: a link is not a file of its own, the file it names is
      // listed where it lives.
      for entry in try RuntimeTree.entries(under: root) where entry.kind == .file {
        let path = root + "/" + entry.path
        var info = stat()
        guard lstat(path, &info) == 0 else { throw posixFailure("lstat", path) }
        guard isMachO(path) else { continue }
        lines.append(
          "\(top)/\(entry.path) \(info.st_dev) \(info.st_ino) \(info.st_size) "
            + "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
      }
    }
    guard !lines.isEmpty else { throw .invalid("\(wine.path) holds no Mach-O file.") }
    let root = InstancePaths.realPath(wine.path) ?? wine.path
    let text = ([root] + lines.sorted()).joined(separator: "\n")
    let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    return RuntimeTranslationStamp(
      schemaVersion: currentSchemaVersion, digest: digest, files: lines.count)
  }

  /// Whether the file starts with a Mach-O or universal (fat) magic number.
  static func isMachO(_ path: String) -> Bool {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var magic: UInt32 = 0
    guard read(fd, &magic, 4) == 4 else { return false }
    // MH_MAGIC_64, MH_MAGIC and FAT_MAGIC, as stored on disk by little- and big-endian writers.
    return [0xfeed_facf, 0xcffa_edfe, 0xfeed_face, 0xcefa_edfe, 0xcafe_babe, 0xbeba_feca]
      .contains(magic)
  }
}

/// Warms Rosetta's translation cache for EA's elevation proxy, `EAGEP.exe`.
///
/// EA's background service starts EAGEP for every elevated game launch and gives up when EAGEP
/// has not connected back within 3.5 s. After a runtime was installed, copied or had a library
/// replaced, the first EAGEP spends 8 to 10 s translating Wine's unix libraries before it can
/// connect (measured), so that launch always fails. Wine's page cache and EA's own files play a
/// much smaller part: a fully cold copy of the EA app and of the runtime's Windows libraries cost
/// about 0.1 s.
///
/// The warm-up runs EAGEP once, by its unix path, in a scratch prefix of the Hub's own. No EA
/// background service runs there, so EAGEP loads the libraries it needs, finds no service and
/// exits by itself within seconds; EA, its prefix and its processes are not touched. The
/// translations land in `/var/db/oah`, which every prefix shares, so the next EAGEP in the real
/// prefix starts warm. A `RuntimeTranslationStamp` recorded after the run tells `isNeeded` whether
/// the runtime changed since.
package struct EAGEPWarmup: Sendable {
  /// The Wine tree of the runtime that runs EA (the folder with `bin` and `lib`).
  package let wine: URL
  /// A prefix that only the warm-up uses; Wine creates it on the first run.
  package let scratchPrefix: URL
  /// Where the stamp of the last warm-up is kept, as JSON.
  package let stampFile: URL
  package let runner: any RuntimeProcessRunner
  /// How long the run may take: the first one also creates the scratch prefix.
  package let timeout: TimeInterval

  package init(
    wine: URL, scratchPrefix: URL, stampFile: URL,
    runner: any RuntimeProcessRunner = LiveRuntimeProcessRunner(), timeout: TimeInterval = 300
  ) {
    self.wine = wine
    self.scratchPrefix = scratchPrefix
    self.stampFile = stampFile
    self.runner = runner
    self.timeout = timeout
  }

  /// Where the EA app installs EAGEP inside a prefix, relative to `drive_c`.
  static let eaDesktopFolder = "Program Files/Electronic Arts/EA Desktop"

  /// Finds `EAGEP.exe` of the EA app installed in `prefix`, or nil.
  ///
  /// The EA app keeps one folder per version under `EA Desktop`, some of them links to others;
  /// they are resolved, and the first real file by sorted path is returned, so the answer does not
  /// depend on directory order.
  package static func locateEAGEP(inPrefix prefix: URL) -> URL? {
    let base = prefix.appendingPathComponent("drive_c/" + eaDesktopFolder)
    guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
      return nil
    }
    let found = versions.sorted().compactMap { version -> String? in
      let candidate = base.path + "/" + version + "/EA Desktop/EAGEP.exe"
      guard let resolved = realpath(candidate, nil) else { return nil }
      defer { free(resolved) }
      var info = stat()
      let path = String(cString: resolved)
      guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
      return path
    }
    return found.first.map { URL(fileURLWithPath: $0) }
  }

  /// The stamp recorded by the last warm-up, or nil when there is none or it cannot be read.
  package func recordedStamp() -> RuntimeTranslationStamp? {
    guard let data = FileManager.default.contents(atPath: stampFile.path),
      let stamp = try? JSONDecoder().decode(RuntimeTranslationStamp.self, from: data),
      stamp.schemaVersion == RuntimeTranslationStamp.currentSchemaVersion
    else { return nil }
    return stamp
  }

  /// Whether the runtime's Mach-O files changed since the last warm-up, or there was none.
  package func isNeeded() throws(HubError) -> Bool {
    try recordedStamp() != RuntimeTranslationStamp.of(wine: wine)
  }

  /// Runs `eagep` once in the scratch prefix, then records the runtime's stamp.
  ///
  /// EAGEP's own exit status is not checked: without a background service it always gives up,
  /// and it has loaded its libraries by then. The stamp is taken before the run, so a runtime
  /// that changes meanwhile is warmed again next time, and it is written only when the run ended
  /// in time and Wine got as far as the prefix's `drive_c/windows`, which it creates before it
  /// starts any program.
  ///
  /// - Parameters:
  ///   - eagep: `EAGEP.exe`, usually from `locateEAGEP(inPrefix:)` on the real prefix.
  ///   - livePrefix: the prefix EA runs in; the scratch prefix must be a different folder that
  ///     neither contains it nor lies inside it.
  ///   - home: `HOME` for Wine, as the Hub gives it to the EA session; the caller's otherwise.
  /// - Throws: `.unsafePath` when either prefix path has a `.` or `..` component, when the
  ///   scratch prefix overlaps `livePrefix`, or when it holds an EA app, whose own background
  ///   service EAGEP could start there; `.invalid` when `eagep` is not a file or the runtime has
  ///   no Mach-O file; `.io` when the scratch prefix cannot be created, Wine cannot run, does not
  ///   finish within `timeout` or never set up the prefix, or the stamp cannot be written.
  @discardableResult
  package func run(eagep: URL, livePrefix: URL, home: URL? = nil) throws(HubError)
    -> RuntimeProcessResult
  {
    try checkScratchPrefix(livePrefix: livePrefix)
    var info = stat()
    guard stat(eagep.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw .invalid("\(eagep.path) is not a file.")
    }
    let stamp = try RuntimeTranslationStamp.of(wine: wine)
    do {
      // Wine creates only the last folder of WINEPREFIX itself.
      try FileManager.default.createDirectory(at: scratchPrefix, withIntermediateDirectories: true)
    } catch {
      throw .io("Cannot create \(scratchPrefix.path): \(error.localizedDescription)")
    }
    let result = try runner.run(
      executable: wine.appendingPathComponent("bin/wine"), arguments: [eagep.path],
      environment: environment(home: home), timeout: timeout)
    var windows = stat()
    guard lstat(scratchPrefix.appendingPathComponent("drive_c/windows").path, &windows) == 0 else {
      throw .io(
        "Wine did not set up \(scratchPrefix.path), so EAGEP never ran (exit \(result.exitCode)): "
          + String(result.output.suffix(400)))
    }
    try record(stamp)
    return result
  }

  /// The environment of the warm-up: nothing from the EA session except `HOME`.
  func environment(home: URL?) -> [String: String] {
    var environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "en_US.UTF-8",
      "WINEPREFIX": scratchPrefix.path,
      "WINEDEBUG": "-all",
      // A new prefix would otherwise offer to install Mono and Gecko, and wait for an answer.
      "WINEDLLOVERRIDES": "mscoree,mshtml=;winemenubuilder.exe=d",
      // No x87sidecar: it makes Rosetta JIT-translate the processes it starts, which fills no
      // cache, and EAGEP is 64-bit and never runs under it in the EA session either. Newer
      // runtimes read an empty value as "off"; older ones try to start the empty path for a
      // 32-bit process, fail, and run the process directly, which has the same effect.
      "ROSETTA_X87_PATH": "",
      "TMPDIR": NSTemporaryDirectory(),
    ]
    environment["HOME"] = home?.path ?? ProcessInfo.processInfo.environment["HOME"]
    return environment
  }

  private func checkScratchPrefix(livePrefix: URL) throws(HubError) {
    // `..` after a link means the parent of the link's target to the system, but the parent of
    // the link to a textual normalization; refusing it keeps the two readings from differing.
    for url in [scratchPrefix, livePrefix]
    where url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
      throw .unsafePath("\(url.path) has a '.' or '..' component.")
    }
    let scratch = Self.canonical(scratchPrefix)
    let live = Self.canonical(livePrefix)
    if scratch == live || scratch.hasPrefix(live + "/") || live.hasPrefix(scratch + "/") {
      throw .unsafePath(
        "The scratch prefix \(scratchPrefix.path) overlaps the EA prefix \(livePrefix.path).")
    }
    for folder in ["drive_c/" + Self.eaDesktopFolder, "drive_c/ProgramData/EA Desktop"] {
      var info = stat()
      if lstat(scratchPrefix.appendingPathComponent(folder).path, &info) == 0 {
        throw .unsafePath(
          "The scratch prefix \(scratchPrefix.path) holds an EA app (\(folder)); EAGEP could "
            + "start its background service there.")
      }
    }
  }

  /// The path with links resolved by the system as far as it exists, then the rest as given.
  /// Callers refuse `.` and `..` components first (see `checkScratchPrefix`).
  static func canonical(_ url: URL) -> String {
    var existing = url.path
    var rest: [String] = []
    while InstancePaths.realPath(existing) == nil, existing != "/", !existing.isEmpty {
      rest.insert((existing as NSString).lastPathComponent, at: 0)
      existing = (existing as NSString).deletingLastPathComponent
    }
    let base = InstancePaths.realPath(existing) ?? existing
    return rest.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
  }

  private func record(_ stamp: RuntimeTranslationStamp) throws(HubError) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      try FileManager.default.createDirectory(
        at: stampFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(stamp).write(to: stampFile, options: .atomic)
    } catch {
      throw .io("Cannot write \(stampFile.path): \(error.localizedDescription)")
    }
  }
}
