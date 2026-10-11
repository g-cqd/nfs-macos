import Foundation
import HubCore
import Observation

/// A folder the user chose for the data store, and what moving it there would do.
struct RelocationProposal: Identifiable, Equatable {
  let id = UUID()
  let chosen: String
  let plan: DataStoreRelocationPlan
}

/// A line of feedback under the settings: what happened, or why it was refused.
struct SettingsNotice: Equatable {
  let text: String
  let isError: Bool
}

/// What is changing the locations now. At most one thing at a time.
enum RelocationActivity: Equatable {
  /// Reading the chosen folder (a copy plan measures the whole data store).
  case planning
  /// Moving the data store; `progress` is set while a copy reports it.
  case moving(DataStoreCopyProgress?)
  /// Saving the runtime location.
  case savingRuntime
}

/// The Hub's two locations (data store and runtime app): their settings, their state, and the
/// operations that change them. All filesystem work runs off the main actor, and only one
/// operation that changes the settings runs at a time.
@MainActor @Observable
final class LocationsModel {
  private(set) var settings: HubSettings
  private(set) var layout: HubLayout
  /// Nil until the first check finishes.
  private(set) var status: HubLocationsStatus?
  /// Set when `settings.json` exists but cannot be read; the defaults are in force meanwhile.
  private(set) var settingsProblem: HubError?
  /// Increases whenever the settings changed, so the library knows to reload.
  private(set) var generation = 0
  private(set) var proposal: RelocationProposal?
  private(set) var activity: RelocationActivity?
  private(set) var dataStoreNotice: SettingsNotice?
  private(set) var runtimeNotice: SettingsNotice?

  private let home: URL
  private let environment: [String: String]
  private var running: Task<Result<DataStoreRelocationOutcome, HubError>, Never>?
  /// Identifies the move whose progress is still wanted; a late report of an ended one is dropped.
  private var currentMove: UUID?
  /// Identifies the newest refresh; an older one that finishes late must not overwrite it.
  private var latestRefresh = 0

  init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.home = home
    self.environment = environment
    var loaded = HubSettings.defaults(home: home)
    var problem: HubError?
    do {
      loaded = try HubSettings.load(home: home)
    } catch {
      problem = error
    }
    self.settings = loaded
    self.settingsProblem = problem
    // No drive access here: the legacy folders are looked for by the first refresh.
    self.layout = HubLayout.from(
      settings: loaded, environment: environment, home: home, resolvingLegacyFolders: false)
  }

  /// Whether `HUB_ROOT` or `HUB_VOLUME` decides the data store, in which case the settings'
  /// data store is not used and cannot be changed here.
  var isOverridden: Bool {
    environment["HUB_ROOT"] != nil || environment["HUB_VOLUME"] != nil
  }

  /// What is wrong with `settings.json`, in words; nil when it is fine.
  var settingsProblemText: String? { settingsProblem.map { message(of: $0) } }

  /// Whether a move or a save is running, so no other change may start.
  var isBusy: Bool { activity != nil }

  // MARK: - Status

  /// Checks both locations again and finds the layout for the data store (this asks the drive).
  /// A refresh that is overtaken by a newer one is dropped.
  func refresh() async {
    latestRefresh += 1
    let token = latestRefresh
    let base = settings
    let overridden = isOverridden
    let environment = environment
    let home = home
    let result = await Task.detached { () -> (HubLocationsStatus, HubLayout) in
      var checked = base
      let layout = HubLayout.from(settings: checked, environment: environment, home: home)
      if overridden { checked.dataStoreRoot = layout.hub.path }
      return (HubLocationsStatus.check(checked), layout)
    }.value
    guard token == latestRefresh else { return }
    status = result.0
    layout = result.1
  }

  // MARK: - Data store

  /// Plans moving the data store to `folder`; the plan is shown for the user to accept.
  func choose(dataStoreFolder folder: URL) async {
    guard !isBusy, !isOverridden else { return }
    dataStoreNotice = nil
    proposal = nil
    activity = .planning
    defer { activity = nil }
    let current = settings.dataStoreRoot
    let chosen = folder.path
    let relocation = DataStoreRelocation(home: home)
    let result = await Task.detached { () -> Result<DataStoreRelocationPlan, HubError> in
      do throws(HubError) {
        return .success(try relocation.plan(current: current, chosen: chosen))
      } catch {
        return .failure(error)
      }
    }.value
    switch result {
    case .success(let plan): proposal = RelocationProposal(chosen: chosen, plan: plan)
    case .failure(let error):
      dataStoreNotice = SettingsNotice(text: message(of: error), isError: true)
    }
  }

  func dismissProposal() {
    guard !isBusy else { return }
    proposal = nil
  }

  /// Carries out the proposal. `confirmedCopy` must be true for a copy to another drive.
  func apply(_ proposal: RelocationProposal, confirmedCopy: Bool) async {
    guard !isBusy, !isOverridden else { return }
    dataStoreNotice = nil
    activity = .moving(nil)
    let move = UUID()
    currentMove = move
    let relocation = DataStoreRelocation(home: home)
    let plan = proposal.plan
    let update = ProgressRelay { [weak self] progress in
      Task { @MainActor in self?.report(progress, of: move) }
    }
    let work = Task.detached { () -> Result<DataStoreRelocationOutcome, HubError> in
      do throws(HubError) {
        return .success(
          try relocation.perform(
            plan, confirmedCopy: confirmedCopy,
            progress: { update.report($0) }, isCancelled: { Task.isCancelled }))
      } catch {
        return .failure(error)
      }
    }
    running = work
    let outcome = await work.value
    running = nil
    currentMove = nil
    switch outcome {
    case .success(.done(let result)):
      await adopt(result.settings)
      self.proposal = nil
      dataStoreNotice = SettingsNotice(text: result.summary, isError: false)
    case .success(.cancelled):
      self.proposal = nil
      dataStoreNotice = SettingsNotice(
        text: "The copy was cancelled. The partial copy was removed; nothing else changed.",
        isError: false)
    case .failure(let error):
      dataStoreNotice = SettingsNotice(text: message(of: error), isError: true)
    }
    activity = nil
    await refresh()
  }

  /// Stops a running copy between files (and inside a large file).
  func cancelMove() { running?.cancel() }

  private func report(_ progress: DataStoreCopyProgress, of move: UUID) {
    guard currentMove == move, case .moving = activity else { return }
    activity = .moving(progress)
  }

  // MARK: - Runtime

  /// Uses the runtime app at `app` when it is a usable runtime for the data store. The saved
  /// settings are read again first, so only the runtime location changes.
  func choose(runtimeApp app: URL) async {
    guard !isBusy else { return }
    runtimeNotice = nil
    activity = .savingRuntime
    defer { activity = nil }
    let home = home
    let path = app.path
    var expected: String?
    if case .ok(let info) = status?.dataStore.status {
      expected = info.hubConfig.runtimeManifestSHA256
    }
    let expectedSHA = expected
    let result = await Task.detached { () -> Result<HubSettings.Saved, HubError> in
      do throws(HubError) {
        return .success(
          try HubSettings.updateRuntimeApp(
            home: home, to: path, expectedSHA256: expectedSHA))
      } catch {
        return .failure(error)
      }
    }.value
    switch result {
    case .success(let saved):
      await adopt(saved.settings)
      runtimeNotice = SettingsNotice(
        text: "The Hub now uses \(app.lastPathComponent)."
          + (saved.warning.map { " " + $0 } ?? ""), isError: false)
      await refresh()
    case .failure(let error):
      runtimeNotice = SettingsNotice(text: message(of: error), isError: true)
    }
  }

  // MARK: - Helpers

  /// Takes the settings that were just saved. The layout is found off the main actor.
  private func adopt(_ updated: HubSettings) async {
    let environment = environment
    let home = home
    let newLayout = await Task.detached {
      HubLayout.from(settings: updated, environment: environment, home: home)
    }.value
    settings = updated
    layout = newLayout
    settingsProblem = nil
    generation += 1
  }

  private func message(of error: HubError) -> String {
    switch error {
    case .invalid(let text), .unsafePath(let text), .io(let text), .volumeMissing(let text),
      .blocked(let text):
      text
    case .belowFloor:
      "There is not enough free space."
    }
  }
}

/// Passes copy progress to the main actor at most a few times a second: a copy reports after each
/// entry, which for a game library is hundreds of thousands of times.
private final class ProgressRelay: @unchecked Sendable {
  // The copy runs on one thread and calls `report` from it only, so the fields need no lock.
  private var lastSent = Date.distantPast
  private let deliver: @Sendable (DataStoreCopyProgress) -> Void

  init(deliver: @escaping @Sendable (DataStoreCopyProgress) -> Void) { self.deliver = deliver }

  func report(_ progress: DataStoreCopyProgress) {
    let now = Date()
    guard now.timeIntervalSince(lastSent) >= 0.2 || progress.fraction >= 1 else { return }
    lastSent = now
    deliver(progress)
  }
}
