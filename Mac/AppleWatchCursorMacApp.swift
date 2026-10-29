import SwiftUI

@main
struct AppleWatchCursorMacApp: App {
    @StateObject private var model = MacPilotModel()
    var body: some Scene {
        WindowGroup("Apple-Watch-Cursor") {
            MacContentView(model: model)
                .preferredColorScheme(.dark)
        }.defaultSize(width: 960, height: 760)
        MenuBarExtra("Apple-Watch-Cursor", systemImage: "hand.point.up.left.fill") {
            Text(model.enabled ? "Apple-Watch-Cursor is active" : "Apple-Watch-Cursor is paused")
            Button("Pause cursor control") { model.disable() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Stop Bluetooth") { model.stop() }
            Divider()
            Button("Quit Apple-Watch-Cursor") { NSApplication.shared.terminate(nil) }
        }
    }
}
