import SwiftUI

struct MixerPopoverView: View {
    @EnvironmentObject private var audioEngine: AudioEngine

    private var activeCountText: String {
        audioEngine.sessions.count == 1 ? "1 app" : "\(audioEngine.sessions.count) apps"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if let message = audioEngine.statusMessage {
                        StatusBanner(message: message)
                    }

                    DeviceControlsPanel()
                    MasterVolumePanel()
                    AppsPanel(activeCountText: activeCountText)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

            footer
        }
        .background(AppTheme.windowBackground)
        .foregroundStyle(.primary)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.16))
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text("AppMixer")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    StatusDot(isActive: audioEngine.isProcessing)
                    Text(audioEngine.isProcessing ? "Mixing \(activeCountText)" : "Ready")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
            }

            Spacer()

            Button {
                audioEngine.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh")

            Button(audioEngine.isProcessing ? "Stop" : "Start") {
                audioEngine.toggleProcessing()
            }
            .buttonStyle(PrimaryPillButtonStyle(isProminent: !audioEngine.isProcessing))
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(audioEngine.backendDescription)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.36))
                .lineLimit(1)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.56))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.footerBackground)
    }
}

private struct DeviceControlsPanel: View {
    @EnvironmentObject private var audioEngine: AudioEngine

    var body: some View {
        VStack(spacing: 10) {
            DeviceControlRow(
                icon: "airplayaudio",
                title: "Output",
                subtitle: defaultOutputName,
                accent: AppTheme.accent
            ) {
                Picker("Default Output", selection: $audioEngine.selectedOutputDeviceID) {
                    ForEach(audioEngine.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .onChange(of: audioEngine.selectedOutputDeviceID) { newValue in
                    audioEngine.selectOutputDevice(newValue)
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            DeviceControlRow(
                icon: "mic.fill",
                title: "Auto Mic",
                subtitle: audioEngine.currentInputDeviceName,
                accent: .mint
            ) {
                HStack(spacing: 10) {
                    InputDeviceMenu()
                        .disabled(!audioEngine.microphoneGuardEnabled)
                        .opacity(audioEngine.microphoneGuardEnabled ? 1 : 0.46)

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { audioEngine.microphoneGuardEnabled },
                            set: { audioEngine.setMicrophoneGuardEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

            if let message = audioEngine.microphoneStatusMessage {
                StatusBanner(message: message, compact: true)
            }
        }
        .panelSurface()
    }

    private var defaultOutputName: String {
        audioEngine.outputDevices.first(where: { $0.id == audioEngine.selectedOutputDeviceID })?.name ?? "Default Output"
    }
}

private struct DeviceControlRow<Accessory: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let accent: Color
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            accessory
        }
    }
}

private struct MasterVolumePanel: View {
    @EnvironmentObject private var audioEngine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: audioEngine.masterVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 18)

                Text("Master")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(Int(audioEngine.masterVolume * 100))%")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Slider(value: $audioEngine.masterVolume, in: 0...1)
                .controlSize(.small)
                .tint(AppTheme.accent)
                .onChange(of: audioEngine.masterVolume) { value in
                    audioEngine.setMasterVolume(value)
                }
        }
        .panelSurface()
    }
}

private struct AppsPanel: View {
    @EnvironmentObject private var audioEngine: AudioEngine
    let activeCountText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apps")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(activeCountText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 2)

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
}

private struct AppVolumeRow: View {
    @EnvironmentObject private var audioEngine: AudioEngine
    let session: ProcessAudioSession

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(icon: session.icon)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)

                        if let subtitle = session.subtitle {
                            Text(subtitle)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.38))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

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
                    .tint(session.isMuted ? .gray : AppTheme.accent)

                    Text("\(Int(session.volume * 100))%")
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Button {
                audioEngine.toggleMute(for: session.id)
            } label: {
                Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle(isDestructive: session.isMuted))
            .help(session.isMuted ? "Unmute" : "Mute")
        }
        .padding(12)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var rowBackground: Color {
        let opacity = session.isTapRunning || !audioEngine.isProcessing ? 0.082 : 0.045
        return Color.white.opacity(opacity)
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
            HStack(spacing: 5) {
                Text(session.outputDeviceUID == nil ? "Default" : session.outputDeviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.36))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.62))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 138, alignment: .trailing)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .help("Route this app to an output device")
    }
}

private struct InputDeviceMenu: View {
    @EnvironmentObject private var audioEngine: AudioEngine

    private var selectedName: String {
        guard let uid = audioEngine.preferredInputDeviceUID,
              let device = audioEngine.inputDevices.first(where: { $0.uid == uid }) else {
            return "Auto"
        }
        return device.name
    }

    var body: some View {
        Menu {
            Button {
                audioEngine.setPreferredInputDeviceUID(nil)
            } label: {
                Label("Auto-select", systemImage: audioEngine.preferredInputDeviceUID == nil ? "checkmark" : "mic")
            }

            Divider()

            ForEach(audioEngine.inputDevices) { device in
                Button {
                    audioEngine.setPreferredInputDeviceUID(device.uid)
                } label: {
                    Label(inputLabel(for: device), systemImage: iconName(for: device))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: 138, alignment: .trailing)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .help("Preferred system input device")
    }

    private func inputLabel(for device: AudioInputDevice) -> String {
        device.isLikelyHeadsetMicrophone ? "\(device.name) - headset mic" : device.name
    }

    private func iconName(for device: AudioInputDevice) -> String {
        if audioEngine.preferredInputDeviceUID == device.uid {
            return "checkmark"
        }
        return device.isLikelyHeadsetMicrophone ? "headphones" : "mic"
    }
}

private struct StatusBanner: View {
    let message: StatusMessage
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.style == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundStyle(message.style == .warning ? .yellow : AppTheme.accent)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(message.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(message.detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(compact ? 2 : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(compact ? 9 : 11)
        .background((message.style == .warning ? Color.yellow : AppTheme.accent).opacity(0.095))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((message.style == .warning ? Color.yellow : AppTheme.accent).opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EmptyAppsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppTheme.accent.opacity(0.82))
            Text("No apps playing audio")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
            Text("Start playback and AppMixer will pick it up.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.46))
        }
        .frame(maxWidth: .infinity, minHeight: 148)
        .background(Color.white.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AppIconView: View {
    let icon: NSImage?

    var body: some View {
        Image(nsImage: icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
            .resizable()
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
    }
}

private struct StatusDot: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? Color.green : Color.white.opacity(0.28))
            .frame(width: 7, height: 7)
            .shadow(color: (isActive ? Color.green : .clear).opacity(0.5), radius: 5)
    }
}

private struct PrimaryPillButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(isProminent ? Color.black : Color.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(isProminent ? AppTheme.accent : Color.white.opacity(0.11))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct IconButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isDestructive ? Color.red : Color.white.opacity(0.72))
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.075))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private extension View {
    func panelSurface() -> some View {
        padding(12)
            .background(AppTheme.panelBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum AppTheme {
    static let accent = Color(red: 0.20, green: 0.91, blue: 1.0)
    static let windowBackground = LinearGradient(
        colors: [
            Color(red: 0.045, green: 0.047, blue: 0.055),
            Color(red: 0.075, green: 0.078, blue: 0.09)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let panelBackground = Color.white.opacity(0.068)
    static let footerBackground = Color.black.opacity(0.22)
}
