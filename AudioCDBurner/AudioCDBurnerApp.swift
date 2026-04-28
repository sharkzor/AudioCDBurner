import SwiftUI

@main
struct AudioCDBurnerApp: App {
    @StateObject private var model = BurnModel()

    var body: some Scene {
        WindowGroup("AudioCDBurner") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}
