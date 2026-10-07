import NFS2015Core
import SwiftUI

/// The display-safety and diagnostic-log group of the settings page.
///
/// None of it is a game option, so it works before the game has written its options file. What
/// it keeps is this app's own choice, read at the next Play.
struct NFS2015DiagnosticsView: View {
  @Bindable var model: NFS2015Model

  var body: some View {
    Section("Display safety and diagnostics") {
      Toggle(
        "Turn off Retina mode on displays where it is too large", isOn: model.limitRetinaBinding())
      Toggle(
        "Start a game that has never run at a safe resolution", isOn: model.seedResolutionBinding())
      Text(
        """
        The first runs of this game on a 4K screen ended within seconds, when Retina mode made \
        the desktop 7680 by 4320. Both switches are on by default and have not been tried on that \
        screen yet. The first turns Retina mode off when the desktop it would give is more than \
        1.75 times the screen's pixels or larger than 3840 by 2160. The second writes only the \
        resolution into the game's options file, and only when the game has never written one. \
        Turn them off to run exactly as before.
        """
      ).font(.caption).foregroundStyle(.secondary)
      if let note = model.displayNote { Text(note).font(.callout) }
      Toggle("Write a diagnostic log on the next Play only", isOn: model.diagnosticLoggingBinding())
      Text(
        """
        Records the exceptions of every Windows program for one launch in wine-debug files of \
        at most 8 MiB, keeping the newest four. It needs the EA app to be closed first, and it \
        may slow the game. A crash report is written after any crash, with or without it.
        """
      ).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Save", action: model.saveDiagnostics)
          .disabled(!model.hasPendingDiagnostics || !model.canEditDiagnostics)
        Button("Discard", action: model.discardDiagnostics).disabled(!model.hasPendingDiagnostics)
        Button("Reset", action: model.resetDiagnostics).disabled(!model.canResetDiagnostics)
      }
      result
    }
    .disabled(!model.canEditDiagnostics)
  }

  @ViewBuilder private var result: some View {
    if let notice = model.diagnosticsNotice { Text(notice).font(.callout) }
    if let refusal = model.diagnosticsRefusal {
      Text("Nothing was changed: \(refusal)").font(.callout)
    } else if let line = model.diagnosticsOutcomeLine {
      Text(line).font(.callout)
    }
    if model.hasPendingDiagnostics {
      Text("Not saved yet. Play uses the saved choices until you press Save.").font(.caption)
    }
  }
}
