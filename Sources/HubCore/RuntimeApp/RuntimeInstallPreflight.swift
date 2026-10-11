import Darwin
import Foundation

/// What `RuntimeAppInstaller` learned about the sources before it wrote anything.
struct RuntimeInstallPlan {
  let manifestSHA256: String
  /// Bytes of the Wine tree and the helpers.
  let sourceBytes: Int64
  /// SHA-256 of each helper file, by name.
  let helperHashes: [String: String]
  let wineTree: String
}

extension RuntimeAppInstaller {
  /// Checks everything that can be checked without writing: the id, the target, the sources and
  /// the free space.
  /// - Throws: `.invalid`, `.blocked`, `.unsafePath` or `.belowFloor`; never `.io`.
  func preflight(_ request: RuntimeInstallRequest) throws(HubError) -> RuntimeInstallPlan {
    do throws(HubError) {
      try Check.id(request.id, field: "runtime id")
      try checkTarget(request.appURL)

      guard let manifestText = try readText(request.manifest, label: "manifest"),
        let linksText = try readText(request.links, label: "links file"),
        let manifestSHA = try DatastoreIO.sha256Hex(fileAt: request.manifest.path)
      else {
        throw .invalid("The manifest or the links file is missing.")
      }
      let list = try RuntimeFileList.parse(manifest: manifestText, links: linksText)
      let wineBytes = try checkWineTree(request.wineTree.path, against: list)
      let (helperBytes, hashes) = try checkHelpers(request.helpersDir.path)

      let sourceBytes = wineBytes + helperBytes
      let parent = request.appURL.deletingLastPathComponent()
      guard let free = freeBytes(parent) else {
        throw .invalid("Cannot read the free space of the volume holding \(parent.path).")
      }
      guard free >= sourceBytes + reserveBytes else {
        throw .belowFloor(needed: sourceBytes, free: free, floor: reserveBytes)
      }
      return RuntimeInstallPlan(
        manifestSHA256: manifestSHA, sourceBytes: sourceBytes, helperHashes: hashes,
        wineTree: request.wineTree.path)
    } catch {
      if case .io(let message) = error { throw .invalid(message) }
      throw error
    }
  }

  private func checkTarget(_ app: URL) throws(HubError) {
    guard try RuntimeTree.lstatEntry(app.path) == nil else {
      throw .blocked("\(app.path) already exists; remove it or pick another target.")
    }
    let path = app.standardizedFileURL.path
    let resolved = try resolvedPath(path)
    var ancestor = path
    while try RuntimeTree.lstatEntry(ancestor) == nil, ancestor != "/" {
      ancestor = (ancestor as NSString).deletingLastPathComponent
    }
    for root in refusedRoots {
      if try isMountPoint(root), try sameDevice(root, ancestor) {
        throw .unsafePath(
          "\(app.path) is on the same volume as \(root); the runtime belongs on the internal disk.")
      }
      for candidate in [path, resolved]
      where candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
        throw .unsafePath(
          "\(candidate) is under \(root); the runtime belongs on the internal disk.")
      }
    }
  }

  /// Whether `path` is the root of a mounted volume. A refused root that is only an empty folder
  /// on the internal disk (its volume is not mounted) is not, and must not refuse the whole disk.
  private func isMountPoint(_ path: String) throws(HubError) -> Bool {
    guard let real = realpath(path, nil) else {
      if errno == ENOENT || errno == ENOTDIR { return false }
      throw posixFailure("realpath", path)
    }
    defer { free(real) }
    var info = statfs()
    guard statfs(real, &info) == 0 else { throw posixFailure("statfs", path) }
    let mountedOn = withUnsafeBytes(of: &info.f_mntonname) {
      String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return mountedOn == String(cString: real)
  }

  private func sameDevice(_ first: String, _ second: String) throws(HubError) -> Bool {
    var one = stat()
    var two = stat()
    guard stat(first, &one) == 0 else { throw posixFailure("stat", first) }
    guard stat(second, &two) == 0 else { throw posixFailure("stat", second) }
    return one.st_dev == two.st_dev
  }

  /// `path` with the symbolic links of its nearest existing ancestor resolved.
  private func resolvedPath(_ path: String) throws(HubError) -> String {
    var existing = path
    var rest: [String] = []
    while try RuntimeTree.lstatEntry(existing) == nil, existing != "/" {
      rest.insert((existing as NSString).lastPathComponent, at: 0)
      existing = (existing as NSString).deletingLastPathComponent
    }
    guard let real = realpath(existing, nil) else { throw posixFailure("realpath", existing) }
    defer { free(real) }
    return ([String(cString: real)] + rest).joined(separator: "/").replacingOccurrences(
      of: "//", with: "/")
  }

  private func readText(_ url: URL, label: String) throws(HubError) -> String? {
    guard let data = try DatastoreIO.readBounded(url.path, limit: 16 * 1024 * 1024) else {
      return nil
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw .invalid("The \(label) is not UTF-8.")
    }
    return text
  }

  /// The tree must hold exactly the manifest's files and links, and not the x87 sidecar.
  private func checkWineTree(_ root: String, against list: RuntimeFileList) throws(HubError)
    -> Int64
  {
    let sidecar = "bin/" + RuntimeApp.sidecarName
    guard !list.files.contains(where: { $0.path == sidecar }) else {
      throw .invalid("The manifest lists \(sidecar); the sidecar belongs in the helpers folder.")
    }
    guard try RuntimeTree.lstatEntry(root)?.kind == .directory else {
      throw .invalid("\(root) is not a folder.")
    }
    var files = Set(list.files.map(\.path))
    var links = Set(list.links.map(\.path))
    var bytes: Int64 = 0
    for entry in try RuntimeTree.entries(under: root) {
      switch entry.kind {
      case .directory: continue
      case .file:
        guard files.remove(entry.path) != nil else {
          throw .invalid(
            entry.path == sidecar
              ? "The Wine tree holds \(sidecar); the sidecar belongs in the helpers folder."
              : "The Wine tree holds \(entry.path), which the manifest does not list.")
        }
        bytes += entry.size
      case .link:
        guard links.remove(entry.path) != nil else {
          throw .invalid(
            "The Wine tree holds the link \(entry.path), which the links file does not list.")
        }
      case .other:
        throw .invalid("\(entry.path) is not a regular file, folder or link.")
      }
    }
    if let missing = files.min() ?? links.min() {
      throw .invalid("The Wine tree lacks \(missing), which the manifest lists.")
    }
    return bytes
  }

  /// The helpers folder holds only regular files, and `x87sidecar` among them, runnable.
  private func checkHelpers(_ root: String) throws(HubError) -> (Int64, [String: String]) {
    guard try RuntimeTree.lstatEntry(root)?.kind == .directory else {
      throw .invalid("\(root) is not a folder.")
    }
    var bytes: Int64 = 0
    var hashes: [String: String] = [:]
    for entry in try RuntimeTree.entries(under: root) {
      guard entry.kind == .file, !entry.path.contains("/") else {
        throw .invalid("The helpers folder may hold only regular files; found \(entry.path).")
      }
      guard let hash = try DatastoreIO.sha256Hex(fileAt: root + "/" + entry.path) else {
        throw .invalid("\(entry.path) vanished.")
      }
      hashes[entry.path] = hash
      bytes += entry.size
      if entry.path == RuntimeApp.sidecarName, entry.mode & 0o111 == 0 {
        throw .invalid("\(entry.path) is not executable.")
      }
    }
    guard hashes[RuntimeApp.sidecarName] != nil else {
      throw .invalid("The helpers folder has no \(RuntimeApp.sidecarName).")
    }
    return (bytes, hashes)
  }
}
