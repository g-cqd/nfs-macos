import LauncherCore
import NFS2015Core
import SwiftUI

/// The Wine workaround and experiments group of the settings page.
///
/// None of it is a game option. It keeps this app's own choice of four switches that Wine reads
/// (`WineExperimentSwitches`) for the next Play: the Rosetta workaround, on by default, and three
/// experiments, off by default. The text says what each is for and that the experiments are not needed.
struct NFS2015ExperimentsView: View {
  @Bindable var model: NFS2015Model

  var body: some View {
    Section("Wine: Rosetta workaround and experiments (for the NFS16 crash)") {
      Toggle(
        "Rosetta 2 self-modifying-code workaround, on by default "
          + "(\(WineExperimentSwitches.rwxWxEmulation)=1)", isOn: model.rwxWxEmulationBinding())
      Text(
        """
        This is a workaround for a bug in Rosetta 2, the part of macOS that runs Windows programs \
        on Apple silicon: after code that the game builds with two stores right ahead of itself, \
        Rosetta resumes one byte late and the game crashes at 0x1B30159. With this on, Wine keeps \
        the game's read-write-execute pages non-writable and lets each store through one \
        instruction at a time. It removed the crash in a test program; it has not been shown in \
        the game yet. It costs a little time on every store to such a page (a page written \
        thousands of times a second is released again), and you can turn it off here if the game \
        or the EA app misbehaves with it.
        """
      ).font(.caption).foregroundStyle(.secondary)
      Toggle(
        "Experiment, not needed: re-toggle executable pages after a cache flush "
          + "(\(WineExperimentSwitches.flushToggle)=1)", isOn: model.flushToggleBinding())
      Toggle(
        "Experiment, not needed: re-toggle pages after a protection change that gives execute "
          + "(\(WineExperimentSwitches.protectToggle)=1)", isOn: model.protectToggleBinding())
      Toggle(
        "Experiment, only records: trace memory calls in the window 0x1B30000-0x1B31000 "
          + "(\(WineExperimentSwitches.tracePage)=\(WineExperimentSwitches.presetTraceWindow))",
        isOn: model.tracePageBinding())
      Text(
        """
        The three experiments test an earlier guess (that Rosetta runs a stale translation of a \
        page the game rewrote through the Windows memory calls); the guess turned out to be wrong, \
        so they are not needed and are off by default. The trace only records, as numbers, what \
        the game did with the page at 0x1B30000, and the crash report prints the last 200 calls. \
        All of these apply to the whole Windows session and take effect when Play starts the EA \
        app: quit a running EA app, then press Play.
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
