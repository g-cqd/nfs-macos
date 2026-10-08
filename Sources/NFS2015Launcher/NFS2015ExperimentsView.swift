import LauncherCore
import NFS2015Core
import SwiftUI

/// The Wine experiments group of the settings page.
///
/// None of it is a game option. It keeps this app's own choice of four switches that Wine's
/// executable-page experiments read (`WineExperimentSwitches`), all off by default, for the next
/// Play. The text says what they are for and that nothing is known to help.
struct NFS2015ExperimentsView: View {
  @Bindable var model: NFS2015Model

  var body: some View {
    Section("Wine experiments (for finding the NFS16 crash)") {
      Toggle(
        "After an instruction-cache flush, re-toggle executable pages "
          + "(\(WineExperimentSwitches.flushToggle)=1)", isOn: model.flushToggleBinding())
      Toggle(
        "After a protection change that gives execute, re-toggle the pages "
          + "(\(WineExperimentSwitches.protectToggle)=1)", isOn: model.protectToggleBinding())
      Toggle(
        "Trace memory calls in the window 0x1B30000-0x1B31000 "
          + "(\(WineExperimentSwitches.tracePage)=\(WineExperimentSwitches.presetTraceWindow))",
        isOn: model.tracePageBinding())
      Toggle(
        "Rosetta self-modifying-code workaround, experimental "
          + "(\(WineExperimentSwitches.rwxWxEmulation)=1)", isOn: model.rwxWxEmulationBinding())
      Text(
        """
        The game faults when Rosetta 2 resumes one byte late after code that the game builds by two \
        stores right ahead of itself. This workaround keeps the game's read-write-execute pages \
        non-writable and lets each store through one instruction at a time, which removed the fault \
        in a test program; it has not been tried in the game, it costs time on every store to \
        such a page, and it is off by default.
        """
      ).font(.caption).foregroundStyle(.secondary)
      Text(
        """
        The two re-toggles test an earlier guess (that Rosetta runs a stale translation of a \
        page the game rewrote through the Windows memory calls); nothing has shown that they \
        help. The trace only records, as numbers, what the game did with the page at 0x1B30000, \
        and the crash report prints the last 200 calls. All four are off by default. They apply \
        to the whole Windows session and take effect when Play starts the EA app: quit a \
        running EA app, then press Play.
        """
      ).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Save", action: model.saveExperiments)
          .disabled(!model.hasPendingExperiments || !model.canEditExperiments)
        Button("Discard", action: model.discardExperiments)
          .disabled(!model.hasPendingExperiments)
        Button("Reset", action: model.resetExperiments).disabled(!model.canResetExperiments)
      }
      result
    }
    .disabled(!model.canEditExperiments)
  }

  @ViewBuilder private var result: some View {
    if let notice = model.experimentsNotice { Text(notice).font(.callout) }
    if let refusal = model.experimentsRefusal {
      Text("Nothing was changed: \(refusal)").font(.callout)
    } else if let line = model.experimentsOutcomeLine {
      Text(line).font(.callout)
    }
    if model.hasPendingExperiments {
      Text("Not saved yet. Play uses the saved choice until you press Save.").font(.caption)
    }
  }
}
