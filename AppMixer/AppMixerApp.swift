import SwiftUI

@main
struct AppMixerApp: App {
    @StateObject private var audioEngine = AudioEngine()

    var body: some Scene {
        MenuBarExtra {
            MixerPopoverView()
                .environmentObject(audioEngine)
                .frame(width: 448, height: 640)
                .task {
                    await audioEngine.start()
                }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .task {
                    await audioEngine.start()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
