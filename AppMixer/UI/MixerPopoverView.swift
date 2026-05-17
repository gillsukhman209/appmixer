import SwiftUI
import UniformTypeIdentifiers

struct MixerPopoverView: View {
    @EnvironmentObject private var audioEngine: AudioEngine

    private var activeCountText: String {
        audioEngine.sessions.count == 1 ? "1 app" : "\(audioEngine.sessions.count) apps"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    statusPanel
                    masterPanel
                    appList
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            footer
        }
        .background(Color(red: 0.055, green: 0.058, blue: 0.066))
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.cyan.opacity(0.14))
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("AppMixer")
                    .font(.system(size: 15, weight: .semibold))
                Text(audioEngine.isProcessing ? "Mixing \(activeCountText)" : "Ready")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            Button {
                audioEngine.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))
            .help("Refresh")
        }
        .padding(16)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StatusPill(isActive: audioEngine.isProcessing)
                Spacer()
                Button(audioEngine.isProcessing ? "Stop" : "Start") {
                    audioEngine.toggleProcessing()
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(isActive: !audioEngine.isProcessing))
            }

            if let message = audioEngine.statusMessage {
                StatusMessageView(message: message)
            }

            HStack(spacing: 10) {
                Image(systemName: "airplayaudio")
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 20)

                Picker("Default Output", selection: $audioEngine.selectedOutputDeviceID) {
                    ForEach(audioEngine.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .onChange(of: audioEngine.selectedOutputDeviceID) { newValue in
                    audioEngine.selectOutputDevice(newValue)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.075))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .panelStyle()
    }

    private var masterPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: audioEngine.masterVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.white.opacity(0.76))
                    .frame(width: 20)
                Text("Master Volume")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(audioEngine.masterVolume * 100))%")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Slider(value: $audioEngine.masterVolume, in: 0...1)
                .controlSize(.small)
                .tint(.cyan)
                .onChange(of: audioEngine.masterVolume) { value in
                    audioEngine.setMasterVolume(value)
                }
        }
        .panelStyle()
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apps")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(activeCountText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.54))
            }

            if audioEngine.sessions.isEmpty {
                EmptyAppsView()
            } else {
                VStack(spacing: 8) {
                    ForEach(audioEngine.sessions) { session in
                        AppVolumeRow(session: session)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(audioEngine.backendDescription)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.38))
            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.62))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.24))
    }
}

private struct StatusPill: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isActive ? Color.green : Color.white.opacity(0.32))
                .frame(width: 8, height: 8)
            Text(isActive ? "On" : "Off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? .green : .white.opacity(0.68))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((isActive ? Color.green : Color.white).opacity(isActive ? 0.12 : 0.07))
        .clipShape(Capsule())
    }
}

private struct StatusMessageView: View {
    let message: StatusMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.style == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(message.style == .warning ? .yellow : .cyan)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.caption.weight(.semibold))
                Text(message.detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct EmptyAppsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.cyan.opacity(0.75))
            Text("No apps playing audio")
                .font(.subheadline.weight(.medium))
            Text("Start playback and AppMixer will pick it up.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AppVolumeRow: View {
    @EnvironmentObject private var audioEngine: AudioEngine
    let session: ProcessAudioSession

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(icon: session.icon)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let subtitle = session.subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.42))
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    AppOutputMenu(session: session)
                }

                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { session.volume },
                            set: { audioEngine.setVolume($0, for: session.id) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.small)
                    .tint(session.isMuted ? .gray : .cyan)

                    Text("\(Int(session.volume * 100))%")
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Button {
                audioEngine.toggleMute(for: session.id)
            } label: {
                Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(session.isMuted ? .red : .white.opacity(0.72))
            .help(session.isMuted ? "Unmute" : "Mute")
        }
        .padding(12)
        .background(Color.white.opacity(session.isTapRunning || !audioEngine.isProcessing ? 0.075 : 0.045))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AppOutputMenu: View {
    @EnvironmentObject private var audioEngine: AudioEngine
    let session: ProcessAudioSession

    private var defaultOutputName: String {
        audioEngine.outputDevices.first(where: { $0.id == audioEngine.selectedOutputDeviceID })?.name ?? "Default"
    }

    var body: some View {
        Menu {
            Button {
                audioEngine.setOutputDeviceUID(nil, for: session.id)
            } label: {
                Label("Default: \(defaultOutputName)", systemImage: session.outputDeviceUID == nil ? "checkmark" : "speaker.wave.2")
            }

            Divider()

            ForEach(audioEngine.outputDevices) { device in
                Button {
                    audioEngine.setOutputDeviceUID(device.uid, for: session.id)
                } label: {
                    Label(device.name, systemImage: session.outputDeviceUID == device.uid ? "checkmark" : "hifispeaker")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(session.outputDeviceUID == nil ? "Default" : session.outputDeviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.58))
            .frame(width: 142, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .help("Route this app to an output device")
    }
}

private struct AppIconView: View {
    let icon: NSImage?

    var body: some View {
        Image(nsImage: icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
            .resizable()
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

private struct PrimaryCapsuleButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(isActive ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isActive ? Color.cyan : Color.white.opacity(0.11))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(12)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
