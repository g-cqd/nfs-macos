import SwiftUI

struct SavesView: View {
  let model: LauncherModel
  @Bindable var editor: SaveEditorModel

  var body: some View {
    Form {
      Section("Profiles") {
        ProfilePicker(editor: editor)
        HStack {
          Button("Import…", action: model.importSave)
          Button("Export…", action: model.exportSave).disabled(!editor.hasLiveProfile)
          Button("Open Saves", action: model.openSaves)
        }
        Text(
          "Import selects a save file from inside its player folder. Each replacement keeps a backup of the previous file."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Create a fresh career") {
        TextField("New player name", text: $editor.newProfileName)
        Button("Create profile", action: model.createProfile).disabled(!editor.canCreateProfile)
        Text(
          "Starts at the beginning with no completed races. Names can contain up to 16 ASCII characters."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Backups") {
        Button("Back up selected profile", action: model.backupSave).disabled(
          !editor.hasLiveProfile)
        Picker("Restore point", selection: $editor.selectedBackup) {
          Text("Select a backup").tag("")
          ForEach(editor.backupNames, id: \.self) { name in Text(name).tag(name) }
        }
        Button("Restore selected backup", action: model.restoreSave).disabled(
          editor.selectedBackup.isEmpty)
        Text(
          "Restoring also backs up the current save. Save tools are available when the game is closed."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Remove profile") {
        Button("Remove selected profile…", role: .destructive, action: model.requestProfileRemoval)
          .disabled(!editor.hasLiveProfile)
        Text(
          "Removes the playable save after backing it up. The profile remains listed as removed so you can restore it here."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Remove \(editor.selectedProfile)?", isPresented: $editor.removeConfirmation
    ) {
      Button("Back up and remove", role: .destructive, action: model.removeProfile)
    } message: {
      Text("The game will no longer list this profile. Its backup stays available for restoration.")
    }
  }
}
