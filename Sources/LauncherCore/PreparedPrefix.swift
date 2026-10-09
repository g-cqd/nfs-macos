import Darwin
import Foundation

/// A complete Windows prefix the app carries, with its store client and game already in it.
///
/// Some games cannot be prepared by `PrefixSeed`, which starts from Wine's defaults: Battlefield 3
/// needs the store client, a browser engine, a class-object stand-in, protocol and game
/// registrations and a game-folder library that were brought up together in one prefix. The app
/// therefore ships that prefix as its template and the session places it, once, in the player's
/// folder: cloned on one APFS volume, copied otherwise, then every file is hashed against this
/// manifest before the prefix is published by one rename. From then on the prefix belongs to the
/// player and to the store client, which patches it in place; an app update never replaces it.
package struct PreparedPrefix: Codable, Equatable, Sendable {
  /// One regular file of the template, relative to the prefix root.
  package struct File: Codable, Equatable, Sendable {
    package let path: String
    package let size: Int
    package let sha256: String

    package init(path: String, size: Int, sha256: String) {
      self.path = path
      self.size = size
      self.sha256 = sha256
    }
  }

  /// A link Wine keeps in `dosdevices`. Code signing refuses a link that leaves the app, so the
  /// template ships without them and the session recreates exactly these.
  package struct Link: Codable, Equatable, Sendable {
    package let path: String
    package let target: String

    package init(path: String, target: String) {
      self.path = path
      self.target = target
    }
  }

  /// An extended attribute Wine stores its Windows file state in (DOS attributes, reparse
  /// points). Signing clears extended attributes in the app, so they travel in the manifest.
  package struct Attribute: Codable, Equatable, Sendable {
    package let path: String
    package let name: String
    /// The value, base64-encoded.
    package let value: String

    package init(path: String, name: String, value: String) {
      self.path = path
      self.name = name
      self.value = value
    }
  }

  /// What was placed, kept beside the prefix so a later launch knows the preparation completed.
  package struct Record: Codable, Equatable, Sendable {
    package let version: String
    package let files: Int
    package let bytes: Int
  }

  /// The template's folder below `Contents/Resources`.
  package let path: String
  package let files: [File]
  /// Folders that hold nothing, which a file list alone cannot recreate.
  package let emptyDirectories: [String]
  package let links: [Link]
  package let attributes: [Attribute]

  package init(
    path: String, files: [File], emptyDirectories: [String] = [], links: [Link] = [],
    attributes: [Attribute] = []
  ) {
    self.path = path
    self.files = files
    self.emptyDirectories = emptyDirectories
    self.links = links
    self.attributes = attributes
  }

  /// The only extended attributes Wine's file layer reads; nothing else is set on a player's file.
  static let attributeNames: Set<String> = ["user.DOSATTRIB", "user.WINEREPARSE"]
  /// The drive links a Wine prefix has; `z:` is the host root, which Wine itself creates.
  static let linkTargets: [String: String] = ["dosdevices/c:": "../drive_c", "dosdevices/z:": "/"]

  package var bytes: Int { files.reduce(0) { $0 + $1.size } }

  /// Rejects an unsafe path, a duplicate, a digest that is not SHA-256, a link or attribute that
  /// is not one of Wine's own, and a template without a drive.
  package func validate() throws(LauncherError) {
    try ManifestFile.validate(path: path)
    guard (1...200_000).contains(files.count), emptyDirectories.count <= 10_000,
      links.count <= Self.linkTargets.count, attributes.count <= 4_096
    else {
      throw .operation("The prepared prefix manifest is out of bounds.")
    }
    var seen = Set<String>()
    for file in files {
      try ManifestFile.validate(path: file.path)
      guard file.size >= 0, file.sha256.utf8.count == 64,
        file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        seen.insert(file.path).inserted
      else {
        throw .operation("The prepared prefix manifest lists an unusable file: \(file.path)")
      }
    }
    for folder in emptyDirectories {
      try ManifestFile.validate(path: folder)
      guard seen.insert(folder).inserted else {
        throw .operation("The prepared prefix manifest lists a folder twice: \(folder)")
      }
    }
    for link in links {
      guard Self.linkTargets[link.path] == link.target, seen.insert(link.path).inserted else {
        throw .operation("The prepared prefix may only recreate Wine's own drive links.")
      }
    }
    for attribute in attributes {
      try ManifestFile.validate(path: attribute.path)
      guard Self.attributeNames.contains(attribute.name),
        let value = Data(base64Encoded: attribute.value), value.count <= 65_536
      else {
        throw .operation("The prepared prefix may only carry Wine's own file attributes.")
      }
    }
    guard files.contains(where: { $0.path == "system.reg" }),
      files.contains(where: { $0.path.hasPrefix("drive_c/") })
    else {
      throw .operation("The prepared prefix has no registry or no Windows drive.")
    }
  }
}

/// Places a `PreparedPrefix` in the player's folder and publishes it atomically.
package struct PreparedPrefixPlacement {
  /// Free space the preparation must leave on the player's volume.
  static let reserve = 2_000_000_000

  private let template: URL
  private let manifest: PreparedPrefix
  private let version: String
  private let data: URL
  private let freeSpace: (URL) -> Int?
  private let files = FileManager.default

  /// - Parameters:
  ///   - template: The template folder inside the app.
  ///   - version: The bundle manifest version, recorded with the published prefix.
  ///   - data: The player's data folder; the prefix is published as `data/Prefix`.
  package init(
    template: URL, manifest: PreparedPrefix, version: String, data: URL,
    freeSpace: @escaping (URL) -> Int? = PrefixSeed.availableCapacity
  ) {
    self.template = template
    self.manifest = manifest
    self.version = version
    self.data = data
    self.freeSpace = freeSpace
  }

  package var prefix: URL { data.appendingPathComponent("Prefix") }
  package var recordURL: URL { data.appendingPathComponent("seed.json") }
  package var stage: URL {
    data.deletingLastPathComponent().appendingPathComponent(".preparing")
  }
  package var isPlaced: Bool { files.fileExists(atPath: recordURL.path) }

  /// Copies the template, recreates links and attributes, verifies every file and publishes.
  ///
  /// Must run while holding the session lock, on the synchronous session helper.
  /// - Returns: The published prefix. A prefix placed earlier is returned untouched.
  /// - Throws: A failure; nothing is published, and a retry starts clean.
  /// - Complexity: O(template bytes) for the first launch, O(1) afterwards.
  package func place(progress: (String) -> Void = { _ in }) throws(LauncherError) -> URL {
    do {
      try manifest.validate()
      if files.fileExists(atPath: data.path) {
        guard isPlaced, files.fileExists(atPath: prefix.appendingPathComponent("drive_c").path)
        else {
          throw LauncherError.operation(
            "Player data is incomplete. Keep this folder and check the session log.")
        }
        return prefix
      }
      try files.createDirectory(
        at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
      try requireSpace()
      if files.fileExists(atPath: stage.path) { try files.removeItem(at: stage) }
      try files.createDirectory(at: stage, withIntermediateDirectories: false)
      do {
        let staged = stage.appendingPathComponent("Prefix")
        progress("Placing the Windows folder (\(manifest.bytes / 1_000_000_000) GB).")
        try copyTree(to: staged)
        try recreate(in: staged)
        progress("Verifying \(manifest.files.count) files.")
        try verify(staged)
        let record = PreparedPrefix.Record(
          version: version, files: manifest.files.count, bytes: manifest.bytes)
        try JSONEncoder().encode(record).write(
          to: stage.appendingPathComponent("seed.json"), options: .withoutOverwriting)
        try files.moveItem(at: stage, to: data)
      } catch {
        do { try files.removeItem(at: stage) } catch {
          print("Could not remove incomplete preparation: \(error)")
        }
        throw error
      }
      return prefix
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not prepare the Windows folder: \(error.localizedDescription)")
    }
  }

  /// One `copyfile` of the whole tree: a clone of every file on one APFS volume, a copy
  /// otherwise. Links are copied as links and never followed.
  private func copyTree(to target: URL) throws {
    let flags = copyfile_flags_t(
      COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
    guard copyfile(template.path, target.path, nil, flags) == 0 else {
      throw LauncherError.operation("Could not copy the Windows folder (\(errno)).")
    }
  }

  /// Wine's drive links, the empty folders and Wine's own file attributes.
  private func recreate(in root: URL) throws {
    for folder in manifest.emptyDirectories {
      try files.createDirectory(
        at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    for link in manifest.links {
      let url = root.appendingPathComponent(link.path)
      try files.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if (try? files.destinationOfSymbolicLink(atPath: url.path)) == link.target { continue }
      try files.createSymbolicLink(atPath: url.path, withDestinationPath: link.target)
    }
    for attribute in manifest.attributes {
      let url = root.appendingPathComponent(attribute.path)
      guard let value = Data(base64Encoded: attribute.value) else { continue }
      let status = value.withUnsafeBytes { bytes in
        setxattr(url.path, attribute.name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
      }
      guard status == 0 else {
        throw LauncherError.operation(
          "Could not restore a Windows file attribute on \(attribute.path) (\(errno)).")
      }
    }
  }

  /// Every listed file is a regular file of its size and digest, and nothing else is a file.
  private func verify(_ root: URL) throws {
    for file in manifest.files {
      let url = root.appendingPathComponent(file.path)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        try FileDigest.sha256(of: url, size: file.size) == file.sha256
      else {
        throw LauncherError.operation("Windows folder verification failed: \(file.path)")
      }
    }
    var count = 0
    let enumerator = files.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [])
    while let url = enumerator?.nextObject() as? URL {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { count += 1 }
    }
    guard count == manifest.files.count else {
      throw LauncherError.operation(
        "The Windows folder holds \(count) files where the manifest lists \(manifest.files.count).")
    }
  }

  /// A clone needs almost no space; a copy from another volume needs the whole template.
  private func requireSpace() throws {
    let parent = data.deletingLastPathComponent()
    let same =
      (try? template.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject)
      .flatMap { lhs in
        (try? parent.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject)
          .map { lhs.isEqual($0) }
      } ?? false
    let needed = (same ? 0 : manifest.bytes) + Self.reserve
    if let available = freeSpace(parent), available < needed {
      throw LauncherError.operation(
        """
        There is not enough free space to prepare the game. It needs about \
        \((needed + 999_999_999) / 1_000_000_000) GB free on the disk that holds your \
        Library folder.
        """)
    }
  }
}
