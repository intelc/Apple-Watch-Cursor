import SwiftUI

@main
struct AppleWatchCursorWatchApp: App {
    @StateObject private var model = WatchPilotModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WatchContentView(model: model)
                .onAppear { model.activate() }
                .onChange(of: phase) { _, phase in
                    if phase == .background { model.suspend() }
                    else if phase == .inactive { model.inactive() }
                    else if phase == .active { model.activate() }
                }
        }
    }
}
