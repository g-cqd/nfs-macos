import SwiftUI

@main
struct FarCry2App: App {
  @State private var model = FarCry2Model()
  var body: some Scene {
    Window("Far Cry 2", id: "launcher") {
      FarCry2View(model: model)
        .task(id: model.request) { await model.run() }
        .task { await model.watchActivation() }
    }
    .defaultSize(width: 940, height: 760)
  }
}
