import SwiftUI

@main
struct AppMixerApp: App {
    @StateObject private var audioEngine = AudioEngine()

    var body: some Scene {
        MenuBarExtra {
            MixerPopoverView()
                .environmentObject(audioEngine)
                .frame(width: 420, height: 560)
                .task {
                    await audioEngine.start()
                }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)
    }
}
