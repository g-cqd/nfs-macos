import SwiftUI

struct ProfilePicker: View {
  @Bindable var editor: SaveEditorModel

  var body: some View {
    Picker("Player", selection: $editor.selectedProfile) {
      Text("Select a profile").tag("")
      ForEach(editor.profiles) { profile in Text(profile.displayName).tag(profile.id) }
    }
    LabeledContent("Current cash", value: editor.cashText)
    if let issue = editor.profile?.issue { Text(issue).foregroundStyle(.red) }
    if editor.profiles.isEmpty {
      Text("Create a fresh profile or import a save in Saves & backups.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
