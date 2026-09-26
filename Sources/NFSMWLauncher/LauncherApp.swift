import SwiftUI

@main
struct LauncherApp: App {
  @State private var model = LauncherModel()

  var body: some Scene {
    Window("Most Wanted", id: "launcher") {
      LauncherView(model: model)
        .task(id: model.request) { await model.launch() }
        .task { await model.watchControllerConnections() }
        .task { await model.watchControllerDisconnections() }
        .task { await model.watchApplicationActivation() }
    }
    .defaultSize(width: 900, height: 760)
  }
}
