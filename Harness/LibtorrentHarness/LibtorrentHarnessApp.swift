import SwiftUI

@main
struct LibtorrentHarnessApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = HarnessModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    await model.prepare()
                    await model.runAcceptanceIfRequested()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { Task { await model.checkpointForBackground() } }
                }
        }
    }
}
