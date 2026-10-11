import AppKit
import HubCore
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window: where the data store and the runtime app are, and how to change them.
struct SettingsView: View {
  @Bindable var locations: LocationsModel

  var body: some View {
    Form {
      if let problem = locations.settingsProblemText {
        Section {
          Label(
            "settings.json cannot be read, so the defaults are in use: \(problem)",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.red)
        }
      }
      DataStoreSection(locations: locations)
      RuntimeSection(locations: locations)
    }
    .formStyle(.grouped)
    .frame(minWidth: 620, minHeight: 560)
    .task { await locations.refresh() }
  }
}

// MARK: - Data store

private struct DataStoreSection: View {
  @Bindable var locations: LocationsModel
  @State private var confirming: RelocationProposal?

  var body: some View {
    Section("Data store") {
      LabeledContent("Folder") {
        Text(locations.isOverridden ? locations.layout.hub.path : locations.settings.dataStoreRoot)
          .textSelection(.enabled)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      if locations.isOverridden {
        Label(
          "Overridden by HUB_ROOT/HUB_VOLUME. The data store cannot be changed here.",
          systemImage: "lock.fill"
        )
        .foregroundStyle(.secondary)
      }
      if let report = locations.status?.dataStore {
        LabeledContent("Status") {
          StatusBadge(title: report.status.title, isReady: report.status.isUsable)
        }
        Text(report.status.message)
          .font(.callout)
          .foregroundStyle(.secondary)
        LabeledContent("Free space") {
          Text(spaceText(free: report.freeBytes, total: report.totalBytes))
        }
        LabeledContent("Case-sensitive") {
          Text(report.isCaseSensitive.map { $0 ? "Yes" : "No" } ?? "Unknown")
        }
      } else {
        ProgressView().controlSize(.small)
      }

      HStack {
        Button("Choose…") { chooseFolder() }
          .disabled(locations.isBusy || locations.isOverridden)
          .help("Choose another data store, or a folder to move the data store to")
        Button("Refresh") { Task { await locations.refresh() } }
          .disabled(locations.isBusy)
        if locations.activity == .planning {
          ProgressView().controlSize(.small)
          Text("Reading the folder…").font(.callout).foregroundStyle(.secondary)
        }
      }

      if let proposal = locations.proposal {
        ProposalView(locations: locations, proposal: proposal, confirming: $confirming)
      }
      if case .moving(let progress) = locations.activity {
        MovingView(locations: locations, progress: progress)
      }
      if let notice = locations.dataStoreNotice {
        NoticeView(notice: notice)
      }
    }
    .alert(
      confirmationTitle,
      isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
      presenting: confirming
    ) { proposal in
      Button(confirmationButton(for: proposal.plan)) {
        Task { await locations.apply(proposal, confirmedCopy: true) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { proposal in
      Text(confirmationMessage(for: proposal.plan))
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Choose a Game Hub data store, or a folder to move the data store to."
    panel.directoryURL = URL(fileURLWithPath: locations.settings.dataStoreRoot)
      .deletingLastPathComponent()
    Task {
      if await panel.begin() == .OK, let url = panel.url {
        await locations.choose(dataStoreFolder: url)
      }
    }
  }

  private var confirmationTitle: String {
    if case .copy? = confirming?.plan { return "Copy the data store?" }
    return "Move the data store?"
  }

  private func confirmationButton(for plan: DataStoreRelocationPlan) -> String {
    if case .copy = plan { return "Copy" }
    return "Move"
  }

  private func confirmationMessage(for plan: DataStoreRelocationPlan) -> String {
    let warning = DataStoreRelocation.windowsRecordsWarning
    switch plan {
    case .copy(let from, let to, let bytes, _, _):
      return "Copy \(bytes.formatted(.byteCount(style: .binary))) from \(from) to \(to). "
        + "The original stays where it is and is never deleted. Quit all games first. \(warning)"
    case .rename(let from, let to):
      return "Rename \(from) to \(to). Nothing is copied. Quit all games and the EA, Steam and "
        + "Epic apps first. \(warning)"
    case .pointAtExisting, .refused:
      return ""
    }
  }

  private func spaceText(free: Int64?, total: Int64?) -> String {
    guard let free, let total else { return "Unknown" }
    return "\(free.formatted(.byteCount(style: .binary))) free of "
      + total.formatted(.byteCount(style: .binary))
  }
}

/// The plan for the folder the user chose, with the buttons that apply to it.
private struct ProposalView: View {
  let locations: LocationsModel
  let proposal: RelocationProposal
  @Binding var confirming: RelocationProposal?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch proposal.plan {
      case .pointAtExisting(let root):
        Text("\(root) already holds a data store. The Hub will use it; nothing is moved or copied.")
        HStack {
          Button("Point at existing") {
            Task { await locations.apply(proposal, confirmedCopy: false) }
          }
          .keyboardShortcut(.defaultAction)
          dismiss
        }
      case .rename(let from, let to):
        Text(
          "Move the data store on the same drive: \(from) becomes \(to). It is renamed in one "
            + "step; no data is copied. Needs all games and store apps to be closed.")
        HStack {
          Button("Move here (rename on the same drive)") { confirming = proposal }
          dismiss
        }
      case .copy(_, let to, let bytes, _, let free):
        Text(
          "\(to) is on another drive. The data store (\(bytes.formatted(.byteCount(style: .binary)))) "
            + "can be copied there; the target has \(free.formatted(.byteCount(style: .binary))) "
            + "free. The original is kept.")
        HStack {
          Button("Copy here…") { confirming = proposal }
          dismiss
        }
      case .refused(let refusal):
        Label(refusal.message, systemImage: "xmark.octagon.fill")
          .foregroundStyle(.red)
        dismiss
      }
    }
    .disabled(locations.isBusy)
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(.rect(cornerRadius: 8))
  }

  private var dismiss: some View {
    Button("Dismiss") { locations.dismissProposal() }
  }
}

private struct MovingView: View {
  let locations: LocationsModel
  let progress: DataStoreCopyProgress?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let progress {
        ProgressView(value: progress.fraction) {
          Text("Copying…")
        } currentValueLabel: {
          Text(
            "\(progress.bytesDone.formatted(.byteCount(style: .binary))) of "
              + "\(progress.bytesTotal.formatted(.byteCount(style: .binary))), "
              + "\(progress.entriesDone) of \(progress.entriesTotal) items")
        }
      } else {
        ProgressView().controlSize(.small)
        Text("Working…").font(.callout).foregroundStyle(.secondary)
      }
      Button("Cancel") { locations.cancelMove() }
        .help("Stops the copy and removes the partial copy; the original is untouched")
    }
  }
}

// MARK: - Runtime

private struct RuntimeSection: View {
  @Bindable var locations: LocationsModel

  var body: some View {
    Section("Runtime") {
      LabeledContent("App") {
        Text(locations.settings.runtimeApp)
          .textSelection(.enabled)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      if let runtime = locations.status?.runtime {
        LabeledContent("Status") {
          StatusBadge(title: runtime.title, isReady: runtime.isUsable)
        }
        Text(runtime.message)
          .font(.callout)
          .foregroundStyle(.secondary)
        if case .ok(let info) = runtime {
          LabeledContent("Runtime id") { Text(info.id).monospaced() }
          LabeledContent("Manifest") {
            Text(RuntimeStatus.shortHash(info.manifestSHA256)).monospaced()
          }
        }
      } else {
        ProgressView().controlSize(.small)
      }
      HStack {
        Button("Choose…") { chooseApp() }
          .disabled(locations.isBusy)
          .help("Choose the runtime app (GameHub Runtime ….app)")
        Button("Refresh") { Task { await locations.refresh() } }
      }
      if let notice = locations.runtimeNotice {
        NoticeView(notice: notice)
      }
    }
  }

  private func chooseApp() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.applicationBundle]
    panel.prompt = "Choose"
    panel.message = "Choose the Game Hub runtime app."
    panel.directoryURL = URL(fileURLWithPath: locations.settings.runtimeApp)
      .deletingLastPathComponent()
    Task {
      if await panel.begin() == .OK, let url = panel.url {
        await locations.choose(runtimeApp: url)
      }
    }
  }
}

// MARK: - Pieces

private struct StatusBadge: View {
  let title: String
  let isReady: Bool

  var body: some View {
    Label(title, systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
      .foregroundStyle(isReady ? Color.green : Color.orange)
      .accessibilityLabel("Status: \(title)")
  }
}

private struct NoticeView: View {
  let notice: SettingsNotice

  var body: some View {
    Label(
      notice.text, systemImage: notice.isError ? "xmark.octagon.fill" : "info.circle.fill"
    )
    .foregroundStyle(notice.isError ? Color.red : Color.secondary)
    .textSelection(.enabled)
  }
}
