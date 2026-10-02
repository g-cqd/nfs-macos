import AppKit
import SwiftUI

/// Reports where it is on screen so the game's window can be kept over it.
struct DockAnchor: NSViewRepresentable {
  let onChange: @MainActor (CGRect?) -> Void

  func makeNSView(context: Context) -> AnchorView { AnchorView(onChange: onChange) }
  func updateNSView(_ view: AnchorView, context: Context) {
    view.onChange = onChange
    view.report()
  }
  static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.stop() }
}

final class AnchorView: NSView {
  var onChange: @MainActor (CGRect?) -> Void
  private var observers: [any NSObjectProtocol] = []

  init(onChange: @escaping @MainActor (CGRect?) -> Void) {
    self.onChange = onChange
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stop()
    guard let window else { return }
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.report() }
        })
    }
    report()
  }

  override func layout() {
    super.layout()
    report()
  }

  func report() {
    guard let window else { return onChange(nil) }
    onChange(window.convertToScreen(convert(bounds, to: nil)))
  }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    onChange(nil)
  }
}

struct FarCry2GameView: View {
  @Bindable var model: FarCry2Model

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Game view") {
          Toggle(
            "Show the game in this view",
            isOn: Binding(get: { model.dockEnabled }, set: model.setDock))
          Text(
            "Far Cry 2 runs in its own borderless window, and the starter keeps that window over the area below while you play. macOS cannot place another program's window inside a view, so the game is positioned, not embedded: click the starter and the game goes behind it, and Return to Game brings it back."
          )
          .font(.caption).foregroundStyle(.secondary)
          if model.dockNeedsPermission {
            Text("Moving the game's window needs Accessibility permission for this app.")
              .font(.callout)
            Button("Open Accessibility Settings…", action: model.openAccessibilitySettings)
          }
          if let size = model.gameViewSize {
            Text(
              "The area below is the game's resolution, \(Int(size.width)) × \(Int(size.height)) points. Make the window large enough to show it, or choose a smaller resolution in Graphics."
            ).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .frame(height: 250)
      ScrollView([.horizontal, .vertical]) {
        let size = model.gameViewSize ?? CGSize(width: 1280, height: 800)
        ZStack {
          Color.black
          Text(model.dockEnabled ? "The game appears here" : "Turn on Show the game in this view")
            .foregroundStyle(.secondary)
        }
        .frame(width: size.width, height: size.height)
        .background(DockAnchor { model.dockFrame = $0 })
        .padding()
      }
    }
  }
}
