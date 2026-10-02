import Foundation

/// Declarative rules that recognise a player's own installation without shipping any of its files.
///
/// The packager copies these from the recipe into `game-manifest.json`. At import time the session
/// scans the selected folder against them and builds the per-file inventory (sizes and SHA-256) that
/// the verified-copy pipeline needs. Rules describe what a genuine installation looks like; they do
/// not claim that every edition, patch level or copy-protection variant runs.
package struct ImportRules: Codable, Equatable, Sendable {
  /// A file that must exist, compared case-insensitively, with at least `minimumSize` bytes.
  package struct RequiredFile: Codable, Equatable, Sendable {
    package let path: String
    package let minimumSize: Int
    package init(path: String, minimumSize: Int) {
      self.path = path
      self.minimumSize = minimumSize
    }
  }

  /// A folder copied recursively, minus excluded names, suffixes and sub-folders.
  package struct Directory: Codable, Equatable, Sendable {
    package let path: String
    package let minimumBytes: Int
    package let excludedNames: [String]
    package let excludedSuffixes: [String]
    package let excludedDirectories: [String]
    package init(
      path: String, minimumBytes: Int = 0, excludedNames: [String] = [],
      excludedSuffixes: [String] = [], excludedDirectories: [String] = []
    ) {
      self.path = path
      self.minimumBytes = minimumBytes
      self.excludedNames = excludedNames
      self.excludedSuffixes = excludedSuffixes
      self.excludedDirectories = excludedDirectories
    }
  }

  /// Every file with `primarySuffix` in `directory` needs a sibling with `companionSuffix`.
  package struct Pairing: Codable, Equatable, Sendable {
    package let directory: String
    package let primarySuffix: String
    package let companionSuffix: String
    package init(directory: String, primarySuffix: String, companionSuffix: String) {
      self.directory = directory
      self.primarySuffix = primarySuffix
      self.companionSuffix = companionSuffix
    }
  }

  /// An informational hint (for example a store's metadata file); it never blocks an import.
  package struct Marker: Codable, Equatable, Sendable {
    package let name: String
    package let patterns: [String]
    package init(name: String, patterns: [String]) {
      self.name = name
      self.patterns = patterns
    }
  }

  /// A recorded executable digest. Unlisted digests are accepted and reported as unrecognised.
  package struct KnownBuild: Codable, Equatable, Sendable {
    package let name: String
    package let executableSHA256: String
    package init(name: String, executableSHA256: String) {
      self.name = name
      self.executableSHA256 = executableSHA256
    }
  }

  package let executable: String
  package let machine: String
  package let required: [RequiredFile]
  package let directories: [Directory]
  package let pairings: [Pairing]
  package let markers: [Marker]
  package let knownBuilds: [KnownBuild]
  package let maximumFiles: Int
  package let maximumBytes: Int

  package init(
    executable: String, machine: String = "i386", required: [RequiredFile],
    directories: [Directory], pairings: [Pairing] = [], markers: [Marker] = [],
    knownBuilds: [KnownBuild] = [], maximumFiles: Int = 20_000,
    maximumBytes: Int = 16_000_000_000
  ) {
    self.executable = executable
    self.machine = machine
    self.required = required
    self.directories = directories
    self.pairings = pairings
    self.markers = markers
    self.knownBuilds = knownBuilds
    self.maximumFiles = maximumFiles
    self.maximumBytes = maximumBytes
  }

  var expectedMachine: UInt16? { machine == "i386" ? PortableExecutable.machineI386 : nil }

  /// Rejects unsafe paths, unbounded lists and rules that could never select their own executable.
  package func validate() throws(LauncherError) {
    let invalid = LauncherError.operation("The game recognition rules are invalid.")
    try ManifestFile.validate(path: executable)
    guard expectedMachine != nil, (1...64).contains(required.count),
      (1...16).contains(directories.count), pairings.count <= 8, markers.count <= 16,
      knownBuilds.count <= 64, (1...30_000).contains(maximumFiles),
      (1...64_000_000_000).contains(maximumBytes)
    else { throw invalid }
    let roots = directories.map { $0.path.lowercased() }
    for directory in directories {
      try ManifestFile.validate(path: directory.path)
      guard directory.minimumBytes >= 0, directory.minimumBytes <= maximumBytes,
        directory.excludedNames.count <= 32, directory.excludedSuffixes.count <= 32,
        directory.excludedDirectories.count <= 32,
        directory.excludedNames.allSatisfy({ Self.simpleName($0) }),
        directory.excludedDirectories.allSatisfy({ Self.simpleName($0) }),
        directory.excludedSuffixes.allSatisfy({ $0.hasPrefix(".") && $0 == $0.lowercased() })
      else { throw invalid }
    }
    guard Set(roots).count == roots.count else { throw invalid }
    for file in required {
      try ManifestFile.validate(path: file.path)
      guard file.minimumSize >= 0, file.minimumSize <= 4_000_000_000,
        roots.contains(where: { file.path.lowercased().hasPrefix($0 + "/") })
      else { throw invalid }
    }
    guard required.contains(where: { $0.path.lowercased() == executable.lowercased() }) else {
      throw invalid
    }
    for pairing in pairings {
      try ManifestFile.validate(path: pairing.directory)
      let directory = pairing.directory.lowercased()
      guard roots.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }),
        pairing.primarySuffix.hasPrefix("."), pairing.companionSuffix.hasPrefix("."),
        pairing.primarySuffix == pairing.primarySuffix.lowercased(),
        pairing.companionSuffix == pairing.companionSuffix.lowercased(),
        pairing.primarySuffix != pairing.companionSuffix
      else { throw invalid }
    }
    for marker in markers {
      guard Self.simpleName(marker.name), (1...8).contains(marker.patterns.count),
        marker.patterns.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && !$0.contains("/") })
      else { throw invalid }
    }
    for build in knownBuilds {
      guard Self.simpleName(build.name), build.executableSHA256.utf8.count == 64,
        build.executableSHA256.utf8.allSatisfy({
          (48...57).contains($0) || (97...102).contains($0)
        })
      else { throw invalid }
    }
  }

  private static func simpleName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64 && !value.contains("/") && !value.contains("\\")
      && !value.unicodeScalars.contains(where: { $0.value < 32 })
  }
}

/// Facts recorded about an imported installation; shown by the starter and written to its log.
package struct InstalledGame: Codable, Equatable, Sendable {
  package let executableSHA256: String
  /// Name of a matching `KnownBuild`, or nil when the executable is not on the verified list.
  package let build: String?
  package let fileVersion: String?
  package let versionStrings: [String: String]
  package let markers: [String]
  package let fileCount: Int
  package let totalBytes: Int

  /// Bounds every recorded string in bytes so `origin.json` can always be read back; a file that
  /// cannot be read back would block every later session until the player folder was deleted.
  package func validate() throws(LauncherError) {
    let invalid = LauncherError.operation("The recognised installation details are invalid.")
    guard executableSHA256.utf8.count == 64,
      executableSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      (build?.utf8.count ?? 0) <= 64, (fileVersion?.utf8.count ?? 0) <= 32,
      versionStrings.count <= 16, markers.count <= 16, fileCount >= 0, totalBytes >= 0,
      versionStrings.allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= 256 }),
      markers.allSatisfy({ $0.utf8.count <= 64 })
    else { throw invalid }
  }

  package init(
    executableSHA256: String, build: String?, fileVersion: String?,
    versionStrings: [String: String], markers: [String], fileCount: Int, totalBytes: Int
  ) {
    self.executableSHA256 = executableSHA256
    self.build = build
    self.fileVersion = fileVersion
    self.versionStrings = versionStrings
    self.markers = markers
    self.fileCount = fileCount
    self.totalBytes = totalBytes
  }
}
