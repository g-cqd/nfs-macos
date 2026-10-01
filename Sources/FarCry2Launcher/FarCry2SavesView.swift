import FarCry2Core
import SwiftUI

struct FarCry2SavesView: View {
  @Bindable var model: FarCry2Model
  var body: some View {
    Form {
      Section("Your saves and settings") {
        Text(
          "Saved games, the game's settings file and its input map live in the player folder, outside the app and the Wine prefix. They survive app updates."
        )
        Button("Back Up Now", action: model.backUp).disabled(!model.canBackUp)
        if model.backups.count >= FarCry2Backups.limit {
          Text("Remove an older backup before creating another.").font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if model.keptAside > 0 {
        Section("Set-aside folders") {
          Text(
            "\(model.keptAside) older player folder(s) conflicted with your saved data and were kept, not deleted, in Data/Saves/FarCry2/Conflicts inside ~/Library/Application Support/FarCry2Mac."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Backups") {
        if model.backups.isEmpty {
          Text("No backups yet.").foregroundStyle(.secondary)
        } else {
          Picker("Backup", selection: $model.backupSelection) {
            ForEach(model.backups) { backup in
              Text(
                "\(backup.created.formatted(date: .abbreviated, time: .shortened)) · \(backup.label)"
              )
              .tag(backup.id)
            }
          }
          HStack {
            Button("Restore…") { model.restoreConfirmation = true }.disabled(!model.canRestore)
            Button("Remove…") { model.removalConfirmation = true }.disabled(!model.canRestore)
          }
          if let selected = model.backups.first(where: { $0.id == model.backupSelection }) {
            Text(
              "\(selected.files) files, \(selected.bytes.formatted(.byteCount(style: .file)))"
            ).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }.formStyle(.grouped)
  }
}
