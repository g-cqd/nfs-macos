import LauncherCore
import NFS2015Core
import SwiftUI

/// The Wine experiments group of the settings page.
///
/// None of it is a game option. It keeps this app's own choice of three switches that Wine's
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
      Text(
        """
        These test a guess about why the game faults at 0x1B30159: that Rosetta runs a stale \
        translation of a code page the game rewrote. Nothing has shown that either re-toggle \
        helps; the trace only records, as numbers, what the game did with that page, and the \
        crash report prints the last 200 calls. All three are off by default. They apply to \
        the whole Windows session and take effect when Play starts the EA app: quit a running \
        EA app, then press Play.
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
