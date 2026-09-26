import LauncherCore
import SwiftUI

struct CheatsView: View {
  @Bindable var model: LauncherModel
  @Bindable var editor: SaveEditorModel

  var body: some View {
    Form {
      Section("Availability") {
        Toggle("Unlock all cars, events and shop parts", isOn: $model.settings.unlockAll)
        Text(
          "Applied on the next launch. This is the game's global availability switch; it does not complete career events. Owned cars and purchased parts stay in the save when disabled."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Selected save") {
        ProfilePicker(editor: editor)
        Text(
          "Save edits happen only when you press their Apply button. Each edit creates a backup."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Money") {
        LabeledContent("Current balance", value: editor.cashText)
        Picker("Operation", selection: $editor.moneyOperation) {
          ForEach(MoneyOperation.allCases, id: \.self) { operation in
            Text(operation.rawValue).tag(operation)
          }
        }
        TextField(editor.moneyInputTitle, text: $editor.amount)
        Text(editor.moneyPreview).foregroundStyle(.secondary)
        Button("Apply money change", action: model.changeCash).disabled(!editor.canEdit)
      }
      Section("Add a car") {
        Text(editor.garageCapacity).foregroundStyle(.secondary)
        TextField("Search models", text: $editor.carSearch)
        Picker("Model", selection: $editor.newCarSignature) {
          Text("Select a model").tag("")
          ForEach(editor.catalogCars) { choice in Text(choice.title).tag(choice.id) }
        }
        TextField("Quantity", text: $editor.newCarCount)
        Button("Add to selected profile", action: model.addCar).disabled(!editor.canEdit)
        Text(
          "Adds stock cars without charging cash. Traffic, police and cutscene models have game-defined limitations and may lack racing or customization support."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Owned cars") {
        Picker("Car", selection: $editor.selectedCar) {
          Text("Select a car").tag(0)
          ForEach(editor.cars) { car in Text("\(car.name) · #\(car.id)").tag(car.id) }
        }
        TextField("Additional copies", text: $editor.copies)
        Button("Add copies of selected car", action: model.duplicateCar).disabled(editor.car == nil)
        Text(
          "New copies use independent parts and pursuit records. The career garage holds 25 cars. Cars with advanced visual sidecars cannot be duplicated yet."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        DisclosureGroup("Selected car upgrades & pursuit") {
          ForEach(GarageCar.partNames.indices, id: \.self) { index in
            Picker(GarageCar.partNames[index], selection: editor.partBinding(index)) {
              ForEach(editor.partLevels(index), id: \.self) { level in
                Text("Level \(level)").tag(level)
              }
            }
            Toggle("Junkman \(GarageCar.partNames[index])", isOn: editor.junkmanBinding(index))
          }
          TextField("Heat (0–5)", text: $editor.heat)
          TextField("Bounty", text: $editor.bounty)
          Text(
            "Upgrade levels follow this car's actual ladder. Junkman turbo and nitrous require the corresponding regular upgrade."
          )
          .font(.caption).foregroundStyle(.secondary)
          Button("Apply car changes", action: model.changeCar).disabled(editor.car?.limits == nil)
        }
      }
    }
    .formStyle(.grouped)
  }
}
