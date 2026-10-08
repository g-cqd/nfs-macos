import NFS2015Core
import SwiftUI

/// The x87 sidecar group of the settings page.
///
/// It is not part of the game's options file, so it works before the game has written one. What
/// it keeps is this app's own choice, read at the next Play. It is off unless the player turns it
/// on, and the wording says what is known and what is not.
struct NFS2015SidecarView: View {
  @Bindable var model: NFS2015Model

  var body: some View {
    Section("x87 sidecar (experimental)") {
      Toggle("Attach the x87 sidecar to the Windows session", isOn: model.sidecarBinding())
      Text(
        """
        The sidecar is a helper process that handles the x87 floating-point instructions of \
        32-bit Windows programs. This game is a 64-bit program with little x87 code, so it is \
        expected to gain little from the sidecar, while the sidecar adds a round trip to another \
        process for each block of code it translates. It is off by default for that reason. This \
        is a judgement from how the game is built, not a measurement: nobody has compared this \
        game with the sidecar on and off yet. Turn it on to compare.
        """
      ).font(.caption).foregroundStyle(.secondary)
      Text(
        """
        The choice applies to the whole Windows session, the EA app included: Wine attaches the \
        sidecar when it starts a session, even for a 64-bit program. It takes effect when Play \
        starts the EA app. An EA app that is already running keeps the setting it was started \
        with: quit it, then press Play.
        """
      ).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Save", action: model.saveSidecar)
          .disabled(!model.hasPendingSidecar || !model.canEditSidecar)
        Button("Discard", action: model.discardSidecar).disabled(!model.hasPendingSidecar)
        Button("Reset", action: model.resetSidecar).disabled(!model.canResetSidecar)
      }
      result
    }
    .disabled(!model.canEditSidecar)
  }

  @ViewBuilder private var result: some View {
    if let notice = model.sidecarNotice { Text(notice).font(.callout) }
    if let refusal = model.sidecarRefusal {
      Text("Nothing was changed: \(refusal)").font(.callout)
    } else if let line = model.sidecarOutcomeLine {
      Text(line).font(.callout)
    }
    if model.hasPendingSidecar {
      Text("Not saved yet. Play uses the saved choice until you press Save.").font(.caption)
    }
  }
}
