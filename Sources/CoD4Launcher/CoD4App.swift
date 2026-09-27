import SwiftUI

@main
struct CoD4App: App {
  @State private var model = CoD4Model()
  var body: some Scene {
    Window("Call of Duty 4", id: "launcher") {
      CoD4View(model: model)
        .task(id: model.request) { await model.run() }
        .task { await model.watchControllerConnections() }
        .task { await model.watchControllerDisconnections() }
        .task { await model.watchActivation() }
    }
    .defaultSize(width: 960, height: 780)
  }
}
