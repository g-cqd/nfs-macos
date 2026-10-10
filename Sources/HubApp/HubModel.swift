import AppKit
import Foundation
import HubCore
import LauncherCore
import Observation

/// A game that can be created as an instance.
struct PendingInstance: Identifiable {
  let id: String = UUID().uuidString
  let game: CatalogEntry
  let kind: GameKind
  let prefix: URL
  let plan: InstancePlan
  let freeBytes: Int64
  var pendingError: HubError?
}

/// Filter options for the game library.
enum LibraryFilter: CaseIterable, Identifiable {
  case all
  case wrapped
  case steam
  case ea
  case epic
  case ubisoft
  case internalInstances

  var id: String { title }

  var title: String {
    switch self {
    case .all: "All"
    case .wrapped: "Wrapped apps"
    case .steam: "Steam"
    case .ea: "EA"
    case .epic: "Epic"
    case .ubisoft: "Ubisoft"
    case .internalInstances: "Internal instances"
    }
  }

  var source: GameSource? {
    switch self {
    case .all, .internalInstances: nil
    case .wrapped: .bundle
    case .steam: .steam
    case .ea: .ea
    case .epic: .epic
    case .ubisoft: .ubisoft
    }
  }
}

/// Free space on volumes.
struct SpaceInfo: Equatable {
  let hubFree: Int64?
  let homeFree: Int64?
  let isHomeBelowFloor: Bool
}

/// The Game Hub's state and operations.
@MainActor @Observable
final class HubModel {
  private(set) var catalog: [CatalogEntry] = []
  private(set) var instances: [InstanceSummary] = []
  var filter: LibraryFilter = .all
  private(set) var isCreatingInstance = false
  private(set) var error: HubError?
  private(set) var spaceInfo: SpaceInfo?
  var pending: PendingInstance?

  let layout: HubLayout
  private var catalogGeneration = 0

  init(layout: HubLayout = .standard()) {
    self.layout = layout
  }

  // MARK: - Loading

  /// Load all data from disk.
  func reload() async {
    await refreshCatalog()
    await refreshInstances()
    await refreshSpace()
  }

  /// Refresh free space information.
  private func refreshSpace() async {
    let (hubFree, homeFree) = await Task.detached { () -> (Int64?, Int64?) in
      let hub = SpaceProbe.freeBytes(at: self.layout.hub)
      let home = SpaceProbe.freeBytes(at: FileManager.default.homeDirectoryForCurrentUser)
      return (hub, home)
    }.value
    let isHomeBelowFloor = (homeFree ?? 0) < SpaceBudget.defaultFloor
    self.spaceInfo = SpaceInfo(hubFree: hubFree, homeFree: homeFree, isHomeBelowFloor: isHomeBelowFloor)
  }

  /// Refresh the catalog of games.
  func refreshCatalog() async {
    let generation = catalogGeneration + 1
    catalogGeneration = generation
    let entries = await Task.detached { GameCatalog.scan(layout: self.layout) }.value
    if generation == catalogGeneration {
      self.catalog = entries
    }
  }

  /// Refresh the list of internal instances.
  private func refreshInstances() async {
    let summary = await Task.detached {
      InstanceStore.list(instances: self.layout.instances)
    }.value
    self.instances = summary
  }

  // MARK: - Filtering

  /// Get the filtered catalog entries.
  var filteredCatalog: [CatalogEntry] {
    if let source = filter.source {
      return catalog.filter { $0.source == source }
    } else if filter == .internalInstances {
      return []
    } else {
      return catalog
    }
  }

  /// Get the count for a filter.
  func countForFilter(_ filter: LibraryFilter) -> Int {
    if let source = filter.source {
      return catalog.filter { $0.source == source }.count
    } else if filter == .internalInstances {
      return instances.count
    } else {
      return catalog.count
    }
  }

  /// Get instances for a specific game.
  func instancesForGame(_ gameID: GameID) -> [InstanceSummary] {
    instances.filter { $0.gameID == gameID }
  }

  // MARK: - Instance Management

  /// Prepare to create an instance (step 1: planning).
  func prepareInstance(for game: CatalogEntry) async {
    guard let kind = resolveGameKind(for: game) else {
      self.error = HubError.invalid("Game kind not supported")
      return
    }

    do {
      guard let prefix = sourcePrefix(for: kind) else {
        self.error = HubError.invalid("Source prefix not found")
        return
      }

      // Check if Wine server is running
      if PrefixActivity.serverIsRunning(prefix: prefix) {
        self.error = HubError.invalid("Quit the game before creating an instance")
        return
      }

      let (plan, freeBytes) = try await Task.detached(priority: .userInitiated) {
        let recipe = InstanceRecipes.recipe(for: kind, prefix: prefix)
        guard let recipe = recipe else {
          throw HubError.invalid("Recipe not found for \(kind)")
        }

        let plan = try InstancePlanner.plan(prefix: prefix, recipe: recipe)

        guard let free = SpaceProbe.freeBytes(at: self.layout.instances) else {
          throw HubError.io("Could not determine free space")
        }

        return (plan, free)
      }.value

      self.pending = PendingInstance(game: game, kind: kind, prefix: prefix, plan: plan, freeBytes: freeBytes)
    } catch let err as HubError {
      self.error = err
    } catch {
      self.error = HubError.io(error.localizedDescription)
    }
  }

  /// Confirm and build the pending instance (step 2: building).
  func confirmPending() async {
    guard var pending = self.pending else { return }
    self.isCreatingInstance = true
    defer { self.isCreatingInstance = false }

    do {
      // Check if Wine server is still running
      if PrefixActivity.serverIsRunning(prefix: pending.prefix) {
        pending.pendingError = HubError.invalid("Quit the game before creating an instance")
        self.pending = pending
        return
      }

      // Re-plan to check if anything changed
      let recipe = InstanceRecipes.recipe(for: pending.kind, prefix: pending.prefix)
      guard let recipe = recipe else {
        pending.pendingError = HubError.invalid("Recipe not found")
        self.pending = pending
        return
      }

      let newPlan = try InstancePlanner.plan(prefix: pending.prefix, recipe: recipe)

      // Compare what the builder will really check, not only the real file bytes.
      let oldRequired = InstanceBuilder.requiredBytes(pending.plan)
      let newRequired = InstanceBuilder.requiredBytes(newPlan)
      if abs(newRequired - oldRequired) > 1000000 {  // 1MB threshold
        pending.pendingError = HubError.invalid("Game files have changed; please prepare again")
        self.pending = pending
        return
      }

      guard let freeBytes = SpaceProbe.freeBytes(at: layout.instances) else {
        pending.pendingError = HubError.io("Could not determine free space")
        self.pending = pending
        return
      }

      let budget = SpaceBudget(free: freeBytes)
      if !budget.allows(adding: newRequired) {
        pending.pendingError = HubError.belowFloor(needed: newRequired, free: freeBytes, floor: budget.floor)
        self.pending = pending
        return
      }

      let instanceID = makeInstanceID(for: pending.game.id)
      let prefixPath = pending.prefix
      let instancesPath = self.layout.instances

      do {
        _ = try await Task.detached(priority: .userInitiated) {
          try InstanceBuilder.build(
            plan: newPlan, prefix: prefixPath, instances: instancesPath,
            instanceID: instanceID, budget: budget, now: Date())
        }.value
        self.pending = nil
        await reload()
      } catch let err as HubError {
        var updatedPending = pending
        updatedPending.pendingError = err
        self.pending = updatedPending
      } catch {
        var updatedPending = pending
        updatedPending.pendingError = HubError.io(error.localizedDescription)
        self.pending = updatedPending
      }
    } catch let err as HubError {
      self.error = err
    } catch {
      self.error = HubError.io(error.localizedDescription)
    }
  }

  /// Cancel the pending instance creation.
  func cancelPending() {
    self.pending = nil
  }

  /// Remove an instance.
  func removeInstance(_ instanceID: String) async {
    do {
      try await Task.detached {
        try InstanceRemover.remove(instanceID: instanceID, instances: self.layout.instances)
      }.value
      await refreshInstances()
      await refreshSpace()
    } catch let err as HubError {
      self.error = err
    } catch {
      self.error = HubError.io(error.localizedDescription)
    }
  }

  /// Clear the error message.
  func clearError() {
    self.error = nil
  }

  // MARK: - Launching

  /// Whether the Hub can start `game` today: wrapped apps only, until the shared prefix exists.
  func canLaunch(_ game: CatalogEntry) -> Bool { GameLauncher.wrappedApp(for: game) != nil }

  /// Opens the wrapped app that owns `game`.
  func launch(_ game: CatalogEntry) async {
    guard let app = GameLauncher.wrappedApp(for: game) else {
      error = .invalid("\(game.title) cannot be started from the Hub yet.")
      return
    }
    do {
      _ = try await NSWorkspace.shared.openApplication(
        at: app, configuration: NSWorkspace.OpenConfiguration())
    } catch {
      self.error = .io("Could not open \(app.lastPathComponent): \(error.localizedDescription)")
    }
  }

  // MARK: - Helpers

  func resolveGameKind(for entry: CatalogEntry) -> GameKind? {
    // The recipe/kind id survives id de-duplication (two wrapped builds of one game).
    entry.kindID.flatMap(GameKind.init(rawValue:)) ?? GameKind(rawValue: entry.id.rawValue)
  }

  private func sourcePrefix(for kind: GameKind) -> URL? {
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support")
    let path: String
    switch kind {
    case .cod4: path = "CoD4Mac/Data/Prefix"
    case .bf3: path = "BF3Mac/Data/Prefix"
    case .nfs2015: path = "NFS2015Mac/Data/Prefix"
    default: return nil
    }
    return support.appendingPathComponent(path)
  }

  private func makeInstanceID(for gameID: GameID) -> String {
    let uuid = UUID().uuidString.prefix(8).lowercased()
    return "\(gameID)-\(uuid)"
  }
}
