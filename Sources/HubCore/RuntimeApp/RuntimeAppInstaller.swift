import Darwin
import Foundation

/// What to install and where.
package struct RuntimeInstallRequest: Sendable {
  package var id: String
  /// The Wine tree (`bin`, `lib`, ...), laid out as the manifest describes it.
  package var wineTree: URL
  /// A folder of tools kept outside the runtime; it must hold `x87sidecar`.
  package var helpersDir: URL
  package var manifest: URL
  package var links: URL
  /// The app bundle to create; it must not exist.
  package var appURL: URL

  package init(
    id: String, wineTree: URL, helpersDir: URL, manifest: URL, links: URL, appURL: URL
  ) {
    self.id = id
    self.wineTree = wineTree
    self.helpersDir = helpersDir
    self.manifest = manifest
    self.links = links
    self.appURL = appURL
  }
}

/// What a finished install reports.
package struct RuntimeInstallResult: Equatable, Sendable {
  package let info: RuntimeAppInfo
  /// The first line `wine --version` printed.
  package let wineVersion: String
  /// Bytes copied (Wine tree and helpers).
  package let copiedBytes: Int64
  package let filesVerified: Int
}

/// Installs a Wine runtime as an app bundle: stages it beside the target, checks the staged copy
/// completely, runs `wine --version`, then renames it into place with `RENAME_EXCL`.
///
/// Errors: `.invalid`, `.blocked`, `.unsafePath` and `.belowFloor` mean a precondition failed
/// and nothing was written; `.io` means a step failed and the staging folder was removed, unless
/// the message says otherwise (a failure after the rename reads "Installed at ...").
package struct RuntimeAppInstaller: Sendable {
  /// Folder trees the app may not be placed under.
  package var refusedRoots: [String] = ["/Volumes/ExT2"]
  /// Free bytes that must remain beyond the size of the sources (default 2 GiB).
  package var reserveBytes: Int64 = 2 * 1024 * 1024 * 1024
  /// The bytes free on the volume that will hold the app; nil when unknown.
  package var freeBytes: @Sendable (URL) -> Int64? = { SpaceProbe.freeBytes(at: $0) }
  package var runner: any RuntimeProcessRunner = LiveRuntimeProcessRunner()
  package var now: @Sendable () -> Date = { Date() }
  package var processID: Int32 = getpid()
  package var versionTimeout: TimeInterval = 60
  /// Called with the staging folder after it is filled and before it is verified.
  package var afterCopy: (@Sendable (URL) throws(HubError) -> Void)?

  package init() {}

  /// - Returns: The installed app, located and checked.
  /// - Complexity: O(bytes) to copy and to hash the copy.
  package func install(_ request: RuntimeInstallRequest) throws(HubError) -> RuntimeInstallResult {
    let plan = try preflight(request)
    let app = request.appURL
    let parent = app.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(
      app.lastPathComponent + ".staging-\(processID)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    } catch {
      throw .io("Cannot create \(parent.path): \(error.localizedDescription)")
    }
    guard mkdir(staging.path, 0o755) == 0 else {
      if errno == EEXIST {
        throw .blocked("\(staging.path) already exists; another install may be running.")
      }
      throw posixFailure("mkdir", staging.path)
    }
    let version: String
    let filesVerified: Int
    do throws(HubError) {
      let folders = try populate(staging, request: request, plan: plan)
      try afterCopy?(staging)
      let report = try RuntimeApp.verify(staging, expectedSHA256: plan.manifestSHA256)
      guard report.isOK else {
        throw .io(
          "The staged copy failed verification: \(Self.describe(report.state, problems: report.problems))"
        )
      }
      version = try wineVersion(in: staging)
      filesVerified = report.checkedFiles
      try RuntimeTreeCopier.restore(folders)
      guard renamex_np(staging.path, app.path, UInt32(RENAME_EXCL)) == 0 else {
        if errno == EEXIST { throw .blocked("\(app.path) appeared while installing.") }
        throw posixFailure("renamex_np", app.path)
      }
    } catch {
      RuntimeTreeCopier.makeRemovable(staging.path)
      do {
        try FileManager.default.removeItem(at: staging)
      } catch let removal {
        throw .io(
          "\(text(of: error)) The staging folder \(staging.path) could not be removed: "
            + removal.localizedDescription)
      }
      throw error
    }
    // The staging folder is gone: it is the app now, so nothing below may remove anything.
    let located = RuntimeApp.locate(app, expectedSHA256: plan.manifestSHA256)
    guard case .ok(let info) = located else {
      throw .io(
        "Installed at \(app.path) but it cannot be located: \(Self.describe(located))")
    }
    return RuntimeInstallResult(
      info: info, wineVersion: version, copiedBytes: plan.sourceBytes,
      filesVerified: filesVerified)
  }

  // MARK: - Steps

  /// - Returns: The Wine tree's folders with their source modes, still to be restored.
  private func populate(
    _ staging: URL, request: RuntimeInstallRequest, plan: RuntimeInstallPlan
  ) throws(HubError) -> [RuntimeTreeCopier.FolderMode] {
    let path = staging.path
    for directory in [
      "Contents", "Contents/MacOS", "Contents/SharedSupport", RuntimeApp.wineRelativePath,
      RuntimeApp.helpersRelativePath, "Contents/Resources", RuntimeApp.metadataRelativePath,
    ] {
      guard mkdir(path + "/" + directory, 0o755) == 0 else {
        throw posixFailure("mkdir", path + "/" + directory)
      }
    }
    try writeInfoPlist(id: request.id, to: path + "/Contents/Info.plist")
    guard symlink(RuntimeApp.launcherLinkTarget, path + "/Contents/MacOS/wine") == 0 else {
      throw posixFailure("symlink", path + "/Contents/MacOS/wine")
    }
    let folders = try RuntimeTreeCopier.copy(
      contentsOf: request.wineTree.path, to: path + "/" + RuntimeApp.wineRelativePath)
    for name in plan.helperHashes.keys.sorted() {
      try RuntimeTreeCopier.copyFile(
        from: request.helpersDir.path + "/" + name,
        to: path + "/" + RuntimeApp.helpersRelativePath + "/" + name)
    }
    let metadata = path + "/" + RuntimeApp.metadataRelativePath
    try RuntimeTreeCopier.copyFile(
      from: request.manifest.path, to: metadata + "/\(request.id).manifest")
    try RuntimeTreeCopier.copyFile(
      from: request.links.path, to: metadata + "/\(request.id).manifest.links")
    let record = RuntimeRecord(
      id: request.id, manifestSHA256: plan.manifestSHA256, source: plan.wineTree,
      installedAt: now(), helpers: plan.helperHashes)
    do {
      try RuntimeRecord.encoder().encode(record).write(
        to: URL(fileURLWithPath: metadata + "/runtime.json"))
    } catch {
      throw .io("Cannot write runtime.json: \(error.localizedDescription)")
    }
    return folders
  }

  /// The keys the app's `Info.plist` holds. The identifier follows the packaging recipes'
  /// `local.<name>.mac` form.
  private struct InfoPlist: Encodable {
    let identifier: String
    let name: String
    let packageType = "APPL"
    let executable = "wine"
    let isUIElement = true

    private enum CodingKeys: String, CodingKey {
      case identifier = "CFBundleIdentifier"
      case name = "CFBundleName"
      case packageType = "CFBundlePackageType"
      case executable = "CFBundleExecutable"
      case isUIElement = "LSUIElement"
    }
  }

  private func writeInfoPlist(id: String, to path: String) throws(HubError) {
    let plist = InfoPlist(identifier: "local.gamehub.runtime.\(id)", name: "GameHub Runtime \(id)")
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    do {
      try encoder.encode(plist).write(to: URL(fileURLWithPath: path))
    } catch {
      throw .io("Cannot write Info.plist: \(error.localizedDescription)")
    }
  }

  /// Runs `wine --version` from `app` with an empty environment and a throwaway HOME.
  private func wineVersion(in app: URL) throws(HubError) -> String {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("gamehub-runtime-home-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    } catch {
      throw .io("Cannot create \(home.path): \(error.localizedDescription)")
    }
    defer { try? FileManager.default.removeItem(at: home) }
    let binary = app.appendingPathComponent(RuntimeApp.wineRelativePath + "/bin/wine")
    let result = try runner.run(
      executable: binary, arguments: ["--version"],
      environment: ["PATH": "/usr/bin:/bin", "HOME": home.path], timeout: versionTimeout)
    guard result.exitCode == 0 else {
      throw .io("wine --version exited with status \(result.exitCode): \(result.output)")
    }
    let lines = result.output.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let version = lines.first(where: { Self.isVersionLine($0) }) else {
      throw .io("wine --version printed no version: \(result.output)")
    }
    return version
  }

  /// `wine-` followed by a digit, such as `wine-11.0`.
  static func isVersionLine(_ line: String) -> Bool {
    guard line.hasPrefix("wine-"), let next = line.dropFirst(5).first else { return false }
    return next.isASCII && next.isNumber
  }

  private static func describe(_ state: RuntimeAppState, problems: [String] = []) -> String {
    switch state {
    case .ok: return problems.joined(separator: "; ")
    case .notFound: return "the app is missing"
    case .invalid(let reason): return reason
    case .mismatch(let expected, let actual):
      return "manifest SHA-256 \(actual), expected \(expected)"
    }
  }
}
