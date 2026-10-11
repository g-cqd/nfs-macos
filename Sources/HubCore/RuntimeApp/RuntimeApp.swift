import Darwin
import Foundation

/// Finds and checks a Wine runtime installed as an app bundle (`GameHub Runtime <id>.app`).
///
/// Layout: `Contents/MacOS/wine` (link to the Wine binary), `Contents/SharedSupport/Wine/` (the
/// runtime), `Contents/Helpers/` (tools kept outside the runtime), and
/// `Contents/Resources/runtime/` (`<id>.manifest`, `<id>.manifest.links`, `runtime.json`).
package enum RuntimeApp {
  package static let wineRelativePath = "Contents/SharedSupport/Wine"
  package static let helpersRelativePath = "Contents/Helpers"
  package static let metadataRelativePath = "Contents/Resources/runtime"
  /// Where `Contents/MacOS/wine` points, relative to its own folder.
  package static let launcherLinkTarget = "../SharedSupport/Wine/bin/wine"
  package static let sidecarName = "x87sidecar"

  /// `<home>/Applications/GameHub Runtime <id>.app`: where the Hub installs runtime `id`.
  package static func defaultAppURL(id: String, home: URL) -> URL {
    home.appendingPathComponent("Applications", isDirectory: true)
      .appendingPathComponent("GameHub Runtime \(id).app", isDirectory: true)
  }

  /// The cheap check: the structure, `runtime.json`, the manifest's SHA-256, and that the key
  /// files exist and can run. It reads about 150 KiB; it does not hash the Wine tree.
  /// - Parameters:
  ///   - app: The app bundle.
  ///   - expectedSHA256: The manifest SHA-256 the app must have (`hub.json`'s
  ///     `runtimeManifestSHA256`); nil accepts any.
  package static func locate(_ app: URL, expectedSHA256: String? = nil) -> RuntimeAppState {
    resolve(app, expectedSHA256: expectedSHA256).state
  }

  /// The full check: ``locate(_:expectedSHA256:)``, then the SHA-256 of every file the manifest
  /// lists, every link in the links file, the helpers' hashes, and that nothing else is a regular
  /// file or link in the Wine tree or the helpers folder.
  ///
  /// Only `Contents/SharedSupport/Wine` and `Contents/Helpers` are compared with the manifest and
  /// the recorded helper hashes; the rest of the bundle (`Info.plist`, the launcher link, the
  /// metadata) is checked for presence by ``locate(_:expectedSHA256:)`` and not hashed.
  /// - Throws: `.io` when a folder or file cannot be read at all.
  /// - Complexity: O(total bytes) in the Wine tree.
  package static func verify(
    _ app: URL, expectedSHA256: String? = nil
  ) throws(HubError) -> RuntimeVerifyReport {
    let (state, located) = resolve(app, expectedSHA256: expectedSHA256)
    guard case .ok(let info) = state, let record = located else {
      return RuntimeVerifyReport(state: state, checkedFiles: 0, problems: [])
    }
    var problems = ProblemList()
    let metadata = app.path + "/" + metadataRelativePath
    let list: RuntimeFileList
    do throws(HubError) {
      // The bytes that are parsed are the bytes that were hashed.
      let manifest = try readData(at: metadata + "/\(info.id).manifest")
      guard DatastoreIO.sha256Hex(manifest) == info.manifestSHA256 else {
        throw .invalid("The manifest changed while it was being verified.")
      }
      let links = try readData(at: metadata + "/\(info.id).manifest.links")
      list = try RuntimeFileList.parse(
        manifest: try utf8(manifest, path: "the manifest"),
        links: try utf8(links, path: "the links file"))
    } catch {
      return RuntimeVerifyReport(
        state: .invalid(text(of: error)), checkedFiles: 0, problems: [])
    }
    var checked = 0
    try verifyTree(
      root: info.wine.path, files: list.files.map { ($0.path, $0.sha256) },
      links: list.links.map { ($0.path, $0.target) }, label: "Wine tree", problems: &problems,
      checked: &checked)
    try verifyTree(
      root: info.helpersDir.path, files: record.helpers.map { ($0.key, $0.value) }, links: [],
      label: "Helpers", problems: &problems, checked: &checked)
    return RuntimeVerifyReport(state: state, checkedFiles: checked, problems: problems.lines)
  }

  // MARK: - Locate

  private enum Inspection {
    case notFound
    case invalid(String)
    case ok(RuntimeAppInfo, RuntimeRecord)
  }

  private static func resolve(
    _ app: URL, expectedSHA256: String?
  ) -> (state: RuntimeAppState, record: RuntimeRecord?) {
    switch inspect(app) {
    case .notFound: return (.notFound, nil)
    case .invalid(let reason): return (.invalid(reason), nil)
    case .ok(let info, let record):
      if let expectedSHA256, expectedSHA256 != info.manifestSHA256 {
        return (.mismatch(expected: expectedSHA256, actual: info.manifestSHA256), nil)
      }
      return (.ok(info), record)
    }
  }

  /// Every folder on the way to a key file, as a real folder: a link in its place would let the
  /// bundle point anywhere.
  private static let requiredFolders = [
    "Contents", "Contents/MacOS", "Contents/Resources", metadataRelativePath,
    "Contents/SharedSupport", wineRelativePath, wineRelativePath + "/bin", helpersRelativePath,
  ]

  private static func inspect(_ app: URL) -> Inspection {
    do throws(HubError) {
      guard let root = try RuntimeTree.lstatEntry(app.path) else { return .notFound }
      guard root.kind == .directory else { return .invalid("\(app.path) is not a folder.") }
      for folder in requiredFolders { try require(.directory, at: app.path + "/" + folder) }
      let contents = app.appendingPathComponent("Contents", isDirectory: true)
      try require(.file, at: contents.appendingPathComponent("Info.plist").path)
      let metadata = app.path + "/" + metadataRelativePath
      let record = try RuntimeRecord.read(at: metadata + "/runtime.json")
      let manifestPath = metadata + "/\(record.id).manifest"
      guard let actual = try DatastoreIO.sha256Hex(fileAt: manifestPath) else {
        return .invalid("\(manifestPath) is missing.")
      }
      guard actual == record.manifestSHA256 else {
        return .invalid(
          "The manifest's SHA-256 is \(actual), but runtime.json records \(record.manifestSHA256).")
      }
      try require(.file, at: metadata + "/\(record.id).manifest.links")

      let wine = app.appendingPathComponent(wineRelativePath, isDirectory: true)
      let wineBinary = wine.appendingPathComponent("bin/wine")
      try require(.file, at: wineBinary.path, executable: true)
      let launcher = contents.appendingPathComponent("MacOS/wine").path
      guard
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: launcher),
        target == launcherLinkTarget
      else {
        return .invalid("Contents/MacOS/wine is not a link to \(launcherLinkTarget).")
      }
      let helpers = app.appendingPathComponent(helpersRelativePath, isDirectory: true)
      let sidecar = helpers.appendingPathComponent(sidecarName)
      var sidecarURL: URL?
      if record.helpers[sidecarName] != nil {
        try require(.file, at: sidecar.path, executable: true)
        sidecarURL = sidecar
      }
      return .ok(
        RuntimeAppInfo(
          id: record.id, manifestSHA256: actual, wine: wine, wineBinary: wineBinary,
          helpersDir: helpers, x87sidecar: sidecarURL), record)
    } catch {
      return .invalid(text(of: error))
    }
  }

  /// Throws `.invalid` unless `path` is a `kind` (never followed through a link) and, when asked,
  /// has an execute bit.
  private static func require(
    _ kind: RuntimeTree.Kind, at path: String, executable: Bool = false
  ) throws(HubError) {
    guard let entry = try RuntimeTree.lstatEntry(path) else {
      throw .invalid("\(path) is missing.")
    }
    guard entry.kind == kind else { throw .invalid("\(path) is not a \(kind).") }
    if executable, entry.mode & 0o111 == 0 { throw .invalid("\(path) is not executable.") }
  }

  private static func readData(at path: String) throws(HubError) -> Data {
    guard let data = try DatastoreIO.readBounded(path, limit: 16 * 1024 * 1024) else {
      throw .invalid("\(path) is missing.")
    }
    return data
  }

  private static func utf8(_ data: Data, path: String) throws(HubError) -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      throw .invalid("\(path) is not UTF-8.")
    }
    return text
  }

  // MARK: - Verify

  private struct ProblemList {
    private(set) var lines: [String] = []

    mutating func add(_ line: String) {
      if lines.count < RuntimeVerifyReport.maxProblems {
        lines.append(line)
      } else if lines.count == RuntimeVerifyReport.maxProblems {
        lines.append("...and more.")
      }
    }
  }

  /// Compares `root` with the files and links it should hold; anything else that is not a
  /// directory is a problem.
  private static func verifyTree(
    root: String, files: [(path: String, sha256: String)],
    links: [(path: String, target: String)], label: String, problems: inout ProblemList,
    checked: inout Int
  ) throws(HubError) {
    guard try RuntimeTree.lstatEntry(root)?.kind == .directory else {
      problems.add("\(label): the folder is missing")
      return
    }
    var expected = Set<String>()
    for (path, hash) in files {
      expected.insert(path)
      let full = root + "/" + path
      do {
        guard let actual = try DatastoreIO.sha256Hex(fileAt: full) else {
          problems.add("\(label): missing file \(path)")
          continue
        }
        checked += 1
        if actual != hash {
          problems.add("\(label): \(path) has SHA-256 \(actual), expected \(hash)")
        }
      } catch {
        problems.add("\(label): \(path): \(text(of: error))")
      }
    }
    for (path, target) in links {
      expected.insert(path)
      let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/" + path)
      if actual != target {
        problems.add(
          "\(label): \(path) is \(actual.map { "a link to \($0)" } ?? "not a link"), expected a link to \(target)"
        )
      }
    }
    for entry in try RuntimeTree.entries(under: root)
    where entry.kind != .directory && !expected.contains(entry.path) {
      problems.add("\(label): unexpected \(entry.kind == .file ? "file" : "entry") \(entry.path)")
    }
  }
}
