import SwiftUI

struct ControllerButtonLabel: View {
  let button: ControllerButtonPresentation
  var body: some View {
    Label(button.title, systemImage: button.symbol).accessibilityLabel(button.title)
  }
}
