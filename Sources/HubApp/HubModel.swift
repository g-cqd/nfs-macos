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
  private(set) var isLoadingCatalog = false
  private(set) var isCreatingInstance = false
  private(set) var error: HubError?
  private(set) var spaceInfo: SpaceInfo?
  var pending: PendingInstance?

  let layout: HubLayout

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
    self.isLoadingCatalog = true
    let entries = await Task.detached { GameCatalog.scan(layout: self.layout) }.value
    self.catalog = entries
    self.isLoadingCatalog = false
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
    guard let kind = gameKind(for: game.id) else {
      self.error = HubError.invalid("Game kind not supported")
      return
    }

    do {
      guard let prefix = sourcePrefix(for: kind) else {
        self.error = HubError.invalid("Source prefix not found")
        return
      }

      let (_, plan, freeBytes) = try await Task.detached(priority: .userInitiated) {
        let recipe = InstanceRecipes.recipe(for: kind, prefix: prefix)
        guard let recipe = recipe else {
          throw HubError.invalid("Recipe not found for \(kind)")
        }

        let plan = try InstancePlanner.plan(prefix: prefix, recipe: recipe)

        let parent = self.layout.instances.deletingLastPathComponent()
        let free = SpaceProbe.freeBytes(at: parent) ?? SpaceProbe.freeBytes(at: self.layout.instances)
        guard let free = free else {
          throw HubError.io("Could not determine free space")
        }

        return (recipe, plan, free)
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
    guard let pending = self.pending else { return }
    self.isCreatingInstance = true
    defer { self.isCreatingInstance = false }

    do {
      let freeBytes = await Task.detached { () -> Int64? in
        let parent = self.layout.instances.deletingLastPathComponent()
        return SpaceProbe.freeBytes(at: parent) ?? SpaceProbe.freeBytes(at: self.layout.instances)
      }.value

      guard let freeBytes = freeBytes else {
        self.error = HubError.io("Could not determine free space")
        return
      }

      let budget = SpaceBudget(free: freeBytes)
      let instanceID = makeInstanceID(for: pending.game.id)

      _ = try await Task.detached(priority: .userInitiated) {
        try InstanceBuilder.build(
          plan: pending.plan, prefix: pending.prefix, instances: self.layout.instances,
          instanceID: instanceID, budget: budget, now: Date())
      }.value

      self.pending = nil
      await reload()
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

  // MARK: - Helpers

  private func gameKind(for gameID: GameID) -> GameKind? {
    GameKind(rawValue: gameID.rawValue)
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
