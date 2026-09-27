import SwiftUI

struct CoD4ProfilesView: View {
  @Bindable var model: CoD4Model
  var body: some View {
    Form {
      Section("Player profiles") {
        Picker(
          "Profile",
          selection: Binding(get: { model.profileSelection }, set: model.selectManagedProfile)
        ) {
          ForEach(model.profiles) { profile in
            Text(profile.isInstalled ? profile.name : "\(profile.name) (archived)").tag(
              profile.name)
          }
        }
        if let profile = model.currentProfile {
          LabeledContent(
            "Campaign save", value: profile.hasCampaignSave ? "Present" : "No save detected")
        }
        HStack {
          Button("Back Up", action: model.backupProfile).disabled(!model.canManageProfile)
          Button("Export…", action: model.exportProfile).disabled(!model.canManageProfile)
          Button("Remove…", role: .destructive) { model.removalConfirmation = true }.disabled(
            !model.canManageProfile)
        }
      }
      Section("Create or import") {
        TextField("Profile name", text: $model.newProfileName)
        Text("Use 1–16 letters, digits, spaces, underscores, or hyphens.").font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          Button("Create Profile", action: model.createProfile).disabled(!model.canCreateProfile)
          Button("Import Profile Folder…", action: model.importProfile).disabled(
            !model.canCreateProfile)
        }
      }
      Section("Restore a backup") {
        Picker("Backup", selection: $model.backupSelection) {
          Text("Choose a backup").tag("")
          ForEach(model.backupNames, id: \.self) { Text($0).tag($0) }
        }
        Button("Restore…") { model.restoreConfirmation = true }.disabled(!model.canRestore)
        Text(
          "Backups retain the player configuration and campaign saves. Removing a profile keeps its backups available here."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
  }
}
