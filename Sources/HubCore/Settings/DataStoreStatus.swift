import Foundation

/// What a usable data store is: where it is, how much room it has, and its `hub.json`.
package struct DataStoreInfo: Equatable, Sendable {
  package var root: String
  package var freeBytes: Int64
  package var totalBytes: Int64
  package var hubConfig: HubConfig

  package init(root: String, freeBytes: Int64, totalBytes: Int64, hubConfig: HubConfig) {
    self.root = root
    self.freeBytes = freeBytes
    self.totalBytes = totalBytes
    self.hubConfig = hubConfig
  }
}

/// Whether the folder the settings name can serve as the data store.
package enum DataStoreStatus: Equatable, Sendable {
  case ok(DataStoreInfo)
  /// The folder is on `/Volumes/<name>` and that volume is not mounted.
  case driveNotConnected(volume: String)
  /// The drive is there but the folder is not.
  case missing
  case notADirectory
  /// The volume does not tell upper from lower case; Wine prefixes need it to.
  case notCaseSensitive
  case notWritable
  /// A folder that holds no `Hub/hub.json` yet. It is fine as a place to move a store to.
  case notInitialised
  /// `Hub/hub.json` exists but cannot be used; the text says why.
  case configInvalid(String)

  /// Whether the Hub can run on this data store.
  package var isUsable: Bool {
    if case .ok = self { return true }
    return false
  }

  /// A one-line title for a badge.
  package var title: String {
    switch self {
    case .ok: "Ready"
    case .driveNotConnected: "Drive not connected"
    case .missing: "Folder not found"
    case .notADirectory: "Not a folder"
    case .notCaseSensitive: "Not case-sensitive"
    case .notWritable: "Not writable"
    case .notInitialised: "Not set up"
    case .configInvalid: "Configuration invalid"
    }
  }

  /// The sentence that tells the user what is wrong and what to do.
  package var message: String {
    switch self {
    case .ok:
      "The data store is connected and ready."
    case .driveNotConnected(let volume):
      "The drive \(volume) is not connected. Plug it in and press Refresh."
    case .missing:
      "The data store folder does not exist. Choose another folder, or reconnect the drive."
    case .notADirectory:
      "The chosen path is not a folder."
    case .notCaseSensitive:
      "This volume does not distinguish upper and lower case, which Wine needs. "
        + "Use a case-sensitive APFS volume."
    case .notWritable:
      "You cannot write to this folder. Choose a folder you own on a writable volume."
    case .notInitialised:
      "This folder holds no Game Hub data store (Hub/hub.json is missing)."
    case .configInvalid(let reason):
      "Hub/hub.json cannot be used: \(reason)"
    }
  }

  /// Checks the folder at `root`, in this order: drive mounted, folder present, folder is a
  /// directory, volume case-sensitive, folder writable, `Hub/hub.json` valid.
  /// - Complexity: O(1) system calls; reads one file of at most 64 KiB.
  package static func check(
    root: String,
    capabilities: any DataStoreCapabilities = LiveDataStoreCapabilities(),
    fileSystem: any DatastoreFileSystem = RealDatastoreFileSystem()
  ) -> DataStoreReport {
    func report(
      _ status: DataStoreStatus, space: DataStoreCapacity? = nil, caseSensitive: Bool? = nil
    ) -> DataStoreReport {
      DataStoreReport(
        root: root, status: status, freeBytes: space?.free, totalBytes: space?.total,
        isCaseSensitive: caseSensitive)
    }

    if let volume = HubPaths.volumeRoot(of: root), !capabilities.isMounted(volumeRoot: volume) {
      return report(.driveNotConnected(volume: volume))
    }
    let node: DatastoreNodeInfo?
    do throws(HubError) {
      node = try fileSystem.statNode(root)
    } catch {
      return report(.configInvalid(text(of: error)))
    }
    guard let node else { return report(.missing) }
    guard node.kind == .directory else { return report(.notADirectory) }

    let space = capabilities.capacity(at: root)
    let caseSensitive = capabilities.isCaseSensitive(at: root)
    guard caseSensitive else {
      return report(.notCaseSensitive, space: space, caseSensitive: false)
    }
    guard capabilities.isWritable(at: root) else {
      return report(.notWritable, space: space, caseSensitive: true)
    }

    let configPath = HubPaths(root: URL(fileURLWithPath: root, isDirectory: true)).config.path
    do throws(HubError) {
      guard try fileSystem.lstatNode(configPath) != nil else {
        return report(.notInitialised, space: space, caseSensitive: true)
      }
      let config = try HubConfig.read(URL(fileURLWithPath: configPath))
      let info = DataStoreInfo(
        root: root, freeBytes: space?.free ?? 0, totalBytes: space?.total ?? 0, hubConfig: config)
      return report(.ok(info), space: space, caseSensitive: true)
    } catch {
      return report(.configInvalid(text(of: error)), space: space, caseSensitive: true)
    }
  }
}

/// The result of checking a data store folder: the verdict, and what was measured on the way even
/// when the verdict is a refusal, so the settings can still show the free space.
package struct DataStoreReport: Equatable, Sendable {
  package var root: String
  package var status: DataStoreStatus
  package var freeBytes: Int64?
  package var totalBytes: Int64?
  /// Nil when the check stopped before the volume was asked.
  package var isCaseSensitive: Bool?

  package init(
    root: String, status: DataStoreStatus, freeBytes: Int64? = nil, totalBytes: Int64? = nil,
    isCaseSensitive: Bool? = nil
  ) {
    self.root = root
    self.status = status
    self.freeBytes = freeBytes
    self.totalBytes = totalBytes
    self.isCaseSensitive = isCaseSensitive
  }
}

/// Whether the runtime app the settings name can run games.
package enum RuntimeStatus: Equatable, Sendable {
  case ok(RuntimeAppInfo)
  case notFound
  case invalid(String)
  /// The app is intact but is not the runtime the data store's `hub.json` records.
  case mismatch(expected: String, actual: String)

  package init(_ state: RuntimeAppState) {
    switch state {
    case .ok(let info): self = .ok(info)
    case .notFound: self = .notFound
    case .invalid(let reason): self = .invalid(reason)
    case .mismatch(let expected, let actual): self = .mismatch(expected: expected, actual: actual)
    }
  }

  /// Checks the runtime app at `app` (the cheap check: no hashing of the Wine tree).
  /// - Parameter expectedSHA256: The manifest hash from `hub.json`; nil accepts any runtime.
  package static func check(app: String, expectedSHA256: String?) -> RuntimeStatus {
    RuntimeStatus(RuntimeApp.locate(URL(fileURLWithPath: app), expectedSHA256: expectedSHA256))
  }

  package var isUsable: Bool {
    if case .ok = self { return true }
    return false
  }

  package var title: String {
    switch self {
    case .ok: "Ready"
    case .notFound: "Runtime not found"
    case .invalid: "Runtime invalid"
    case .mismatch: "Manifest mismatch"
    }
  }

  package var message: String {
    switch self {
    case .ok(let info):
      "Runtime \(info.id), manifest \(RuntimeStatus.shortHash(info.manifestSHA256))."
    case .notFound:
      "The runtime app was not found. Install it with gamehub-cli runtime install, or choose it."
    case .invalid(let reason):
      "This is not a usable runtime app: \(reason)"
    case .mismatch(let expected, let actual):
      "The runtime is intact but is not the one the data store uses (manifest "
        + "\(RuntimeStatus.shortHash(actual)), the data store expects \(RuntimeStatus.shortHash(expected)))."
    }
  }

  /// The first 8 characters of a hash, for display.
  package static func shortHash(_ hash: String) -> String { String(hash.prefix(8)) }
}

/// The two locations of the settings, checked together.
package struct HubLocationsStatus: Equatable, Sendable {
  package var dataStore: DataStoreReport
  package var runtime: RuntimeStatus

  package init(dataStore: DataStoreReport, runtime: RuntimeStatus) {
    self.dataStore = dataStore
    self.runtime = runtime
  }

  /// Whether the Hub has something to tell the user: the data store or the runtime is not usable.
  package var needsAttention: Bool { !dataStore.status.isUsable || !runtime.isUsable }

  /// Checks both locations. The runtime is compared with the manifest hash in `hub.json` when the
  /// data store is readable, and against any runtime otherwise.
  package static func check(
    _ settings: HubSettings,
    capabilities: any DataStoreCapabilities = LiveDataStoreCapabilities(),
    fileSystem: any DatastoreFileSystem = RealDatastoreFileSystem()
  ) -> HubLocationsStatus {
    let store = DataStoreStatus.check(
      root: settings.dataStoreRoot, capabilities: capabilities, fileSystem: fileSystem)
    var expected: String?
    if case .ok(let info) = store.status { expected = info.hubConfig.runtimeManifestSHA256 }
    return HubLocationsStatus(
      dataStore: store,
      runtime: RuntimeStatus.check(app: settings.runtimeApp, expectedSHA256: expected))
  }
}
