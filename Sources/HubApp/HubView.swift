import HubCore
import LauncherCore
import SwiftUI

struct HubView: View {
  @Bindable var model: HubModel
  @State private var selectedGameID: GameID?
  @State private var selectedInstanceID: String?
  @State private var showRemoveConfirmation = false
  @State private var instanceToRemove: InstanceSummary?

  var body: some View {
    NavigationSplitView {
      HubSidebar(model: model, selectedGameID: $selectedGameID, selectedInstanceID: $selectedInstanceID)
    } detail: {
      if model.filter == .internalInstances {
        if let id = selectedInstanceID, let instance = model.instances.first(where: { $0.id == id }) {
          InstanceDetailPane(
            model: model, instance: instance, instanceToRemove: $instanceToRemove,
            showRemoveConfirmation: $showRemoveConfirmation)
        } else {
          Text("No Instance Selected")
            .font(.title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else if let gameID = selectedGameID, let game = model.catalog.first(where: { $0.id == gameID }) {
        GameDetailPane(model: model, game: game, instanceToRemove: $instanceToRemove, showRemoveConfirmation: $showRemoveConfirmation)
      } else {
        VStack {
          Text("No Game Selected")
            .font(.title)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 1000, minHeight: 600)
    .navigationSplitViewStyle(.balanced)
    .sheet(item: $model.pending) { _ in
      PendingInstanceSheet(model: model)
    }
    .interactiveDismissDisabled(model.isCreatingInstance)
    .alert(
      "Error",
      isPresented: Binding(
        get: { model.error != nil },
        set: { if !$0 { model.clearError() } }
      )
    ) {
      Button("OK") { model.clearError() }
    } message: {
      if let error = model.error {
        Text(errorMessage(for: error))
      }
    }
    .confirmationDialog(
      "Remove Instance",
      isPresented: $showRemoveConfirmation,
      presenting: instanceToRemove
    ) { instance in
      Button("Remove", role: .destructive) {
        Task { await model.removeInstance(instance.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { instance in
      Text("Remove instance? This will free \(instance.realBytes.formatted(.byteCount(style: .binary))) of space.")
    }
    .task { await model.reload() }
  }

  // MARK: - Helpers

  private func errorMessage(for error: HubError) -> String {
    switch error {
    case let .invalid(msg):
      return "Invalid: \(msg)"
    case let .unsafePath(msg):
      return "Unsafe path: \(msg)"
    case let .belowFloor(needed, free, floor):
      return "Insufficient space. Need \(needed.formatted(.byteCount(style: .binary))), have \(free.formatted(.byteCount(style: .binary))), floor \(floor.formatted(.byteCount(style: .binary)))"
    case let .io(msg):
      return "I/O error: \(msg)"
    case let .volumeMissing(msg):
      return "Volume missing: \(msg)"
    case let .blocked(msg):
      return "Operation blocked: \(msg)"
    }
  }
}

// MARK: - Space footer

/// Free space on both disks and the instance floor, as a compact footer of the sidebar so it never
/// covers the library or the detail controls.
private struct SpaceFooter: View {
  let spaceInfo: SpaceInfo?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Divider()
      if let info = spaceInfo {
        SpaceRow(label: "Game disk", bytes: info.hubFree, isWarning: false, missingText: "Not connected")
        SpaceRow(label: "Internal disk", bytes: info.homeFree, isWarning: info.isHomeBelowFloor)
        SpaceRow(label: "Instance floor", bytes: SpaceBudget.defaultFloor, isWarning: false)
      } else {
        Text("Measuring disk space…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .background(.bar)
  }
}

private struct SpaceRow: View {
  let label: String
  let bytes: Int64?
  let isWarning: Bool
  var missingText = "—"

  var body: some View {
    HStack(spacing: 6) {
      if isWarning {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .accessibilityHidden(true)
      }
      Text(label)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(bytes.map { $0.formatted(.byteCount(style: .binary)) } ?? missingText)
        .font(.callout.monospacedDigit())
        .foregroundStyle(isWarning ? .red : .primary)
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      isWarning ? "\(label), below the instance floor" : label)
    .accessibilityValue(bytes.map { $0.formatted(.byteCount(style: .binary)) } ?? missingText)
  }
}

// MARK: - Sidebar

private struct HubSidebar: View {
  @Bindable var model: HubModel
  @Binding var selectedGameID: GameID?
  @Binding var selectedInstanceID: String?

  var body: some View {
    VStack(spacing: 0) {
      FilterList(model: model)
      Divider()
      LibraryList(model: model, selectedGameID: $selectedGameID, selectedInstanceID: $selectedInstanceID)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SpaceFooter(spaceInfo: model.spaceInfo)
    }
  }
}

private struct FilterList: View {
  @Bindable var model: HubModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Filters")
        .font(.headline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      List(LibraryFilter.allCases, selection: $model.filter) { filter in
        HStack {
          Text(filter.title)
          Spacer()
          Text("\(model.countForFilter(filter))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      .listStyle(.sidebar)
      .scrollDisabled(true)
      .frame(height: CGFloat(LibraryFilter.allCases.count) * FilterList.rowHeight + 8)
    }
  }

  /// Height of one filter row; the list is sized to its rows so the library gets the rest.
  private static let rowHeight: CGFloat = 28
}

private struct LibraryList: View {
  @Bindable var model: HubModel
  @Binding var selectedGameID: GameID?
  @Binding var selectedInstanceID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(libraryTitle)
          .font(.headline)
        Spacer()
        Button(action: { Task { await model.reload() } }) {
          Label("Refresh Catalog", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh catalog (⌘R)")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      if model.filter == .internalInstances {
        InstanceList(model: model, selection: $selectedInstanceID)
      } else if model.filteredCatalog.isEmpty && !model.isGameDriveConnected {
        ContentUnavailableView(
          "Game drive not connected",
          systemImage: "externaldrive.badge.xmark",
          description: Text(
            "Plug in the game drive and press Refresh. Instances on the internal disk are listed under Internal instances."
          ))
      } else {
      List(model.filteredCatalog, selection: $selectedGameID) { game in
        VStack(alignment: .leading, spacing: 2) {
          Text(game.title)
            .lineLimit(1)
          Text(game.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .tag(game.id)
      }
      .listStyle(.sidebar)
      }
    }
  }

  private var libraryTitle: String {
    switch model.filter {
    case .internalInstances:
      "Instances"
    default:
      "Library"
    }
  }
}

// MARK: - Instances without the catalog

/// The internal instances, listed from the internal disk alone, so they show with the big drive unplugged.
private struct InstanceList: View {
  let model: HubModel
  @Binding var selection: String?

  var body: some View {
    if model.instances.isEmpty {
      ContentUnavailableView(
        "No internal instances",
        systemImage: "internaldrive",
        description: Text("Create one from a game's detail while the game drive is connected."))
    } else {
      List(model.instances, selection: $selection) { instance in
        VStack(alignment: .leading, spacing: 2) {
          Text(model.title(for: instance))
            .lineLimit(1)
          Text(instance.realBytes.formatted(.byteCount(style: .binary)))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .tag(instance.id)
      }
      .listStyle(.sidebar)
    }
  }
}

private struct InstanceDetailPane: View {
  let model: HubModel
  let instance: InstanceSummary
  @Binding var instanceToRemove: InstanceSummary?
  @Binding var showRemoveConfirmation: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.title(for: instance))
        .font(.title2.bold())
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        GridRow {
          Text("Created").foregroundStyle(.secondary)
          Text(instance.createdAt, format: .dateTime)
        }
        GridRow {
          Text("Real size").foregroundStyle(.secondary)
          Text(instance.realBytes.formatted(.byteCount(style: .binary)))
        }
        GridRow {
          Text("Folder").foregroundStyle(.secondary)
          Text(instance.url.path).lineLimit(2).truncationMode(.middle)
        }
      }
      .font(.callout)
      HStack {
        Button("Play") {}
          .disabled(true)
          .help("Starting an internal instance needs the shared Wine prefix, which is not ready yet")
          .accessibilityHint("The shared Wine prefix is not ready yet")
        Button("Remove", role: .destructive) {
          instanceToRemove = instance
          showRemoveConfirmation = true
        }
        .accessibilityLabel("Remove \(model.title(for: instance))")
      }
      Spacer()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Detail Pane

private struct GameDetailPane: View {
  @Bindable var model: HubModel
  let game: CatalogEntry
  @Binding var instanceToRemove: InstanceSummary?
  @Binding var showRemoveConfirmation: Bool

  var body: some View {
    VStack(spacing: 12) {
      GameInfoBox(game: game)
      PlayButton(model: model, game: game)
      InstancesSection(model: model, game: game, instanceToRemove: $instanceToRemove, showRemoveConfirmation: $showRemoveConfirmation)
      if model.filter != .internalInstances {
        CreateInstanceSection(model: model, game: game)
      }
      Spacer()
    }
    .padding(12)
  }
}

private struct GameInfoBox: View {
  let game: CatalogEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(game.title)
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          DetailRow(label: "Source", value: game.source.rawValue)
          DetailRow(label: "Root", value: game.root.path)
          if let executable = game.executable {
            DetailRow(label: "Executable", value: executable)
          }
          if let sizeBytes = game.sizeBytes {
            DetailRow(label: "Size", value: sizeBytes.formatted(.byteCount(style: .binary)))
          }
        }
        Spacer()
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(.rect(cornerRadius: 8))
  }
}

private struct PlayButton: View {
  let model: HubModel
  let game: CatalogEntry

  var body: some View {
    let launchable = model.canLaunch(game)
    Button {
      Task { await model.launch(game) }
    } label: {
      Text("Play")
    }
    .disabled(!launchable)
    .help(launchable ? "Open this game's wrapped app" : "Starting this game from the Hub needs the shared prefix, which is not ready yet")
    .accessibilityHint(
      launchable
        ? "Opens the wrapped app that owns this game"
        : "The shared Wine prefix is not ready yet")
  }
}

private struct InstancesSection: View {
  @Bindable var model: HubModel
  let game: CatalogEntry
  @Binding var instanceToRemove: InstanceSummary?
  @Binding var showRemoveConfirmation: Bool

  var body: some View {
    let gameInstances = model.instancesForGame(game.id)
    if !gameInstances.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Play from Internal Disk")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        List(gameInstances) { instance in
          InstanceRow(instance: instance, instanceToRemove: $instanceToRemove, showRemoveConfirmation: $showRemoveConfirmation)
        }
        .frame(maxHeight: 150)
      }
    }
  }
}

private struct InstanceRow: View {
  let instance: InstanceSummary
  @Binding var instanceToRemove: InstanceSummary?
  @Binding var showRemoveConfirmation: Bool

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(instance.id)
          .font(.callout)
          .monospaced()
        HStack(spacing: 16) {
          Text("Created: \(Text(instance.createdAt, format: .dateTime))")
          Text("Size: \(instance.realBytes.formatted(.byteCount(style: .binary)))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button(role: .destructive) {
        instanceToRemove = instance
        showRemoveConfirmation = true
      } label: {
        Image(systemName: "trash")
      }
      .accessibilityLabel("Remove instance \(instance.id)")
    }
  }
}

private struct CreateInstanceSection: View {
  @Bindable var model: HubModel
  let game: CatalogEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Create Internal Instance")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      CreateInstanceButton(model: model, game: game)
    }
  }
}

private struct CreateInstanceButton: View {
  @Bindable var model: HubModel
  let game: CatalogEntry

  var body: some View {
    if model.resolveGameKind(for: game) != nil {
      Button(action: {
        Task { await model.prepareInstance(for: game) }
      }) {
        if model.isCreatingInstance {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Create Instance")
        }
      }
      .disabled(model.isCreatingInstance)
    } else {
      Text("Not available for internal instances")
        .foregroundStyle(.secondary)
        .font(.caption)
    }
  }
}

private struct DetailRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(spacing: 8) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(minWidth: 80, alignment: .trailing)
      Text(value)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.caption)
  }
}

// MARK: - Pending Instance Sheet

private struct PendingInstanceSheet: View {
  @Bindable var model: HubModel
  @State private var isPreparing = false

  var body: some View {
    if let pending = model.pending {
      VStack(spacing: 16) {
        Text("Create Instance: \(pending.game.title)")
          .font(.headline)

        if isPreparing {
          ProgressView()
            .controlSize(.regular)
        } else if let pendingError = pending.pendingError {
          Text(errorMessage(for: pendingError))
            .foregroundStyle(.red)
            .font(.caption)
        }

        if !isPreparing {
          PendingInstanceDetails(pending: pending)
        }

        HStack {
          Button("Cancel") { model.cancelPending() }
            .disabled(model.isCreatingInstance)
          Spacer()
          Button("Create") {
            isPreparing = true
            Task {
              await model.confirmPending()
              isPreparing = false
            }
          }
          .disabled(!canCreateInstance(pending: pending) || model.isCreatingInstance)
        }

        Spacer()
      }
      .padding(16)
      .interactiveDismissDisabled(model.isCreatingInstance)
    }
  }

  private func canCreateInstance(pending: PendingInstance) -> Bool {
    let budget = SpaceBudget(free: pending.freeBytes)
    return budget.allows(adding: InstanceBuilder.requiredBytes(pending.plan))
  }

  private func errorMessage(for error: HubError) -> String {
    switch error {
    case let .invalid(msg):
      return "Invalid: \(msg)"
    case let .unsafePath(msg):
      return "Unsafe path: \(msg)"
    case let .belowFloor(needed, free, floor):
      return "Insufficient space. Need \(needed.formatted(.byteCount(style: .binary))), have \(free.formatted(.byteCount(style: .binary))), floor \(floor.formatted(.byteCount(style: .binary)))"
    case let .io(msg):
      return "I/O error: \(msg)"
    case let .volumeMissing(msg):
      return "Volume missing: \(msg)"
    case let .blocked(msg):
      return "Operation blocked: \(msg)"
    }
  }
}

private struct PendingInstanceDetails: View {
  let pending: PendingInstance

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DetailRow(label: "Real Bytes", value: pending.plan.realBytes.formatted(.byteCount(style: .binary)))
      DetailRow(label: "Placeholders", value: "\(pending.plan.placeholderCount)")
      DetailRow(label: "Omitted", value: "\(pending.plan.omittedCount)")
      if !pending.plan.externalLinks.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("External Links")
            .font(.caption2)
            .foregroundStyle(.secondary)
          ForEach(pending.plan.externalLinks, id: \.self) { link in
            Text(link)
              .font(.caption)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
      let remaining = pending.freeBytes - InstanceBuilder.requiredBytes(pending.plan)
      DetailRow(label: "Free After", value: remaining.formatted(.byteCount(style: .binary)))
      DetailRow(label: "Floor", value: SpaceBudget.defaultFloor.formatted(.byteCount(style: .binary)))
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(.rect(cornerRadius: 8))
  }
}

// MARK: - Previews

#Preview {
  let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
  let layout = HubLayout(
    hub: tempDir, bundles: tempDir, steam: tempDir, eaGames: tempDir,
    epic: tempDir, ubisoft: tempDir, instances: tempDir)
  return HubView(model: HubModel(layout: layout))
}
