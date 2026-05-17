import AppKit
import CoreAudio
import Darwin
import Foundation

@MainActor
final class AudioEngine: ObservableObject {
    @Published var sessions: [ProcessAudioSession] = []
    @Published var outputDevices: [OutputDevice] = []
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedOutputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    @Published var preferredInputDeviceUID: String?
    @Published var currentInputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    @Published var currentInputDeviceName = "Unknown"
    @Published var microphoneGuardEnabled: Bool
    @Published var microphoneStatusMessage: StatusMessage?
    @Published var statusMessage: StatusMessage?
    @Published var isProcessing = false
    @Published var masterVolume: Float

    private let store = AppVolumeStore()
    private let outputManager = OutputDeviceManager()
    private let inputManager = InputDeviceManager()
    private let permissionsManager = PermissionsManager()
    private let virtualDevice = VirtualAudioDevice()
    private let tapMixer = AMCoreAudioTapMixer()
    private var refreshTask: Task<Void, Never>?
    private var identityCache: [String: AppDisplayIdentity] = [:]

    var backendDescription: String {
        if #available(macOS 14.2, *) {
            "CoreAudio process taps"
        } else {
            "AudioServerPlugIn virtual device"
        }
    }

    init() {
        masterVolume = store.masterVolume
        preferredInputDeviceUID = store.preferredInputUID
        microphoneGuardEnabled = store.microphoneGuardEnabled
        tapMixer.masterVolume = masterVolume
    }

    func start() async {
        reloadOutputs()
        reloadInputs()
        enforceMicrophonePolicy()
        refreshNow()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    self?.refreshNow()
                }
            }
        }
    }

    func refreshNow() {
        reloadOutputs()
        reloadInputs()
        enforceMicrophonePolicy()
        let fresh = enumerateAudioProcesses()
        sessions = fresh
        if isProcessing {
            syncTaps()
        }
    }

    func toggleProcessing() {
        if isProcessing {
            tapMixer.stop()
            isProcessing = false
            statusMessage = nil
            sessions = sessions.map { session in
                var updated = session
                updated.isTapRunning = false
                return updated
            }
            return
        }

        guard permissionsManager.canUseProcessTaps else {
            statusMessage = StatusMessage(
                title: "Unsupported macOS Version",
                detail: permissionsManager.processTapAvailabilityMessage ?? "Per-app audio capture requires macOS 14.2 or later.",
                style: .warning
            )
            if let device = virtualDevice.installedDevice() {
                selectedOutputDeviceID = device.id
                let status = virtualDevice.makeSystemOutput()
                if status != noErr {
                    statusMessage = StatusMessage(title: "Output Switch Failed", detail: "AppMixer could not select the virtual output device.", style: .warning)
                }
            }
            return
        }

        let outputID = selectedOutputDeviceID == kAudioObjectUnknown ? outputManager.defaultOutputDeviceID() : selectedOutputDeviceID
        do {
            try tapMixer.start(withOutputDeviceID: outputID)
        } catch {
            statusMessage = StatusMessage(title: "Audio Capture Needs Attention", detail: userFacingAudioError(error), style: .warning)
            return
        }
        isProcessing = true
        statusMessage = nil
        syncTaps()
    }

    func setVolume(_ value: Float, for id: String) {
        let clampedValue = value.clampedVolume
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].volume = clampedValue
        let bundleIdentifier = sessions[index].bundleIdentifier
        store.setVolume(clampedValue, for: bundleIdentifier)
        for session in sessions where session.bundleIdentifier == bundleIdentifier {
            tapMixer.setVolume(clampedValue, forBundleIdentifier: session.audioProcessBundleIdentifier)
        }
        sessions = sessions.map { session in
            guard session.bundleIdentifier == bundleIdentifier else { return session }
            var updated = session
            updated.volume = clampedValue
            return updated
        }
    }

    func toggleMute(for id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].isMuted.toggle()
        let bundleIdentifier = sessions[index].bundleIdentifier
        let isMuted = sessions[index].isMuted
        store.setMuted(isMuted, for: bundleIdentifier)
        for session in sessions where session.bundleIdentifier == bundleIdentifier {
            tapMixer.setMuted(isMuted, forBundleIdentifier: session.audioProcessBundleIdentifier)
        }
        sessions = sessions.map { session in
            guard session.bundleIdentifier == bundleIdentifier else { return session }
            var updated = session
            updated.isMuted = isMuted
            return updated
        }
    }

    func setMasterVolume(_ value: Float) {
        let clampedValue = value.clampedVolume
        masterVolume = clampedValue
        store.masterVolume = clampedValue
        tapMixer.masterVolume = clampedValue
    }

    func setMicrophoneGuardEnabled(_ isEnabled: Bool) {
        microphoneGuardEnabled = isEnabled
        store.microphoneGuardEnabled = isEnabled
        if isEnabled {
            if preferredInputDeviceUID == nil {
                preferredInputDeviceUID = bestFallbackInputDevice()?.uid
                store.preferredInputUID = preferredInputDeviceUID
            }
            enforceMicrophonePolicy(forcePreferred: true)
        } else {
            microphoneStatusMessage = nil
        }
    }

    func setPreferredInputDeviceUID(_ uid: String?) {
        preferredInputDeviceUID = uid
        store.preferredInputUID = uid
        if microphoneGuardEnabled {
            enforceMicrophonePolicy(forcePreferred: uid != nil)
        }
    }

    func selectOutputDevice(_ deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown else { return }
        do {
            try tapMixer.setOutputDeviceID(deviceID)
            selectedOutputDeviceID = deviceID
            updateDefaultRoutedSessions(to: deviceID)
        } catch {
            statusMessage = StatusMessage(title: "Output Switch Failed", detail: "Choose another output device and try again.", style: .warning)
        }
    }

    func setOutputDeviceUID(_ outputUID: String?, for id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let bundleIdentifier = session.bundleIdentifier
        store.setOutputUID(outputUID, for: bundleIdentifier)

        let target = outputTarget(for: bundleIdentifier, explicitUID: outputUID)
        do {
            for routedSession in sessions where routedSession.bundleIdentifier == bundleIdentifier {
                try tapMixer.setOutputDeviceID(target.id, forBundleIdentifier: routedSession.audioProcessBundleIdentifier)
            }
            sessions = sessions.map { routedSession in
                guard routedSession.bundleIdentifier == bundleIdentifier else { return routedSession }
                var updated = routedSession
                updated.outputDeviceID = target.id
                updated.outputDeviceUID = outputUID
                updated.outputDeviceName = target.name
                return updated
            }
        } catch {
            statusMessage = StatusMessage(title: "Output Route Failed", detail: "AppMixer could not route \(session.displayName) to that device.", style: .warning)
        }
    }

    private func reloadOutputs() {
        outputDevices = outputManager.outputDevices()
        if selectedOutputDeviceID == kAudioObjectUnknown {
            selectedOutputDeviceID = outputManager.defaultOutputDeviceID()
        }
    }

    private func reloadInputs() {
        inputDevices = inputManager.inputDevices()
        currentInputDeviceID = inputManager.defaultInputDeviceID()
        currentInputDeviceName = inputDevices.first(where: { $0.id == currentInputDeviceID })?.name ?? "Unknown"

        if let preferredInputDeviceUID,
           !inputDevices.contains(where: { $0.uid == preferredInputDeviceUID }) {
            microphoneStatusMessage = StatusMessage(
                title: "Preferred Mic Unavailable",
                detail: "AppMixer will use a built-in or external microphone until your preferred input reconnects.",
                style: .info
            )
        } else if microphoneStatusMessage?.title == "Preferred Mic Unavailable" {
            microphoneStatusMessage = nil
        }
    }

    private func enforceMicrophonePolicy(forcePreferred: Bool = false) {
        guard microphoneGuardEnabled else { return }
        guard !inputDevices.isEmpty else { return }

        let current = inputDevices.first(where: { $0.id == currentInputDeviceID })
        let preferred = preferredInputDeviceUID.flatMap { uid in
            inputDevices.first(where: { $0.uid == uid })
        }

        let target: AudioInputDevice?
        if let preferred, (forcePreferred || current?.id != preferred.id) {
            target = preferred
        } else if current?.isLikelyHeadsetMicrophone == true {
            target = bestFallbackInputDevice()
        } else {
            target = nil
        }

        guard let target, target.id != currentInputDeviceID else { return }
        let status = inputManager.setDefaultInputDevice(target.id)
        if status == noErr {
            currentInputDeviceID = target.id
            currentInputDeviceName = target.name
            if preferredInputDeviceUID == nil {
                preferredInputDeviceUID = target.uid
                store.preferredInputUID = target.uid
            }
            microphoneStatusMessage = nil
        } else {
            microphoneStatusMessage = StatusMessage(
                title: "Mic Switch Failed",
                detail: "AppMixer could not set \(target.name) as the system input device. CoreAudio returned \(status).",
                style: .warning
            )
        }
    }

    private func bestFallbackInputDevice() -> AudioInputDevice? {
        inputDevices.first(where: { $0.isLikelyBuiltInMicrophone }) ??
            inputDevices.first(where: { !$0.isLikelyHeadsetMicrophone }) ??
            inputDevices.first
    }

    private func syncTaps() {
        var updatedSessions = sessions
        var failedIDs = Set<String>()
        var failureDetails: [String] = []
        let liveBundleIDs = updatedSessions.map(\.audioProcessBundleIdentifier)

        for index in updatedSessions.indices {
            var session = updatedSessions[index]
            do {
                try tapMixer.upsertProcessTap(
                    withProcessObjectID: session.processObjectID,
                    pid: session.pid,
                    bundleIdentifier: session.audioProcessBundleIdentifier,
                    volume: session.volume,
                    muted: session.isMuted,
                    outputDeviceID: session.outputDeviceID
                )
            } catch {
                failureDetails.append("\(session.displayName): \(shortAudioError(error))")
                if session.outputDeviceUID != nil, let fallback = defaultOutputTarget() {
                    do {
                        try tapMixer.upsertProcessTap(
                            withProcessObjectID: session.processObjectID,
                            pid: session.pid,
                            bundleIdentifier: session.audioProcessBundleIdentifier,
                            volume: session.volume,
                            muted: session.isMuted,
                            outputDeviceID: fallback.id
                        )
                        store.setOutputUID(nil, for: session.bundleIdentifier)
                        session.outputDeviceID = fallback.id
                        session.outputDeviceUID = nil
                        session.outputDeviceName = fallback.name
                        updatedSessions[index] = session
                    } catch {
                        failedIDs.insert(session.id)
                        failureDetails.append("\(session.displayName) default route: \(shortAudioError(error))")
                    }
                } else {
                    failedIDs.insert(session.id)
                }
            }
        }
        tapMixer.removeMissingBundleIdentifiers(liveBundleIDs)

        if !updatedSessions.isEmpty && failedIDs.count == updatedSessions.count {
            tapMixer.stop()
            isProcessing = false
            statusMessage = StatusMessage(
                title: "Audio Capture Could Not Start",
                detail: captureFailureMessage(from: failureDetails),
                style: .warning
            )
        } else if failedIDs.isEmpty {
            statusMessage = nil
        } else {
            statusMessage = nil
        }

        sessions = updatedSessions.map { session in
            var updated = session
            updated.isTapRunning = isProcessing && !failedIDs.contains(session.id)
            return updated
        }
    }

    private func enumerateAudioProcesses() -> [ProcessAudioSession] {
        let processObjects = readProcessObjectList()
        return processObjects.compactMap { objectID -> ProcessAudioSession? in
            guard isRunningOutput(objectID),
                  let pid = readPID(objectID),
                  pid != ProcessInfo.processInfo.processIdentifier else {
                return nil
            }

            let audioBundleID = readBundleID(objectID) ?? "pid.\(pid)"
            let identity = resolveDisplayIdentity(pid: pid, audioBundleID: audioBundleID)
            let volume = store.volume(for: identity.bundleIdentifier)
            let muted = store.isMuted(identity.bundleIdentifier)
            let outputTarget = outputTarget(for: identity.bundleIdentifier)
            return ProcessAudioSession(
                id: audioBundleID,
                processObjectID: objectID,
                pid: pid,
                audioProcessBundleIdentifier: audioBundleID,
                bundleIdentifier: identity.bundleIdentifier,
                displayName: identity.displayName,
                icon: identity.icon,
                subtitle: identity.subtitle,
                outputDeviceID: outputTarget.id,
                outputDeviceUID: outputTarget.explicitUID,
                outputDeviceName: outputTarget.name,
                volume: volume,
                isMuted: muted,
                isTapRunning: false
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func readProcessObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var values = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &values) == noErr else {
            return []
        }
        return values
    }

    private func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }

    private func readBundleID(_ objectID: AudioObjectID) -> String? {
        var bundleID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &bundleID) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        let value = bundleID as String
        return value.isEmpty ? nil : value
    }

    private func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    private func outputTarget(for bundleIdentifier: String, explicitUID: String? = nil) -> AppOutputTarget {
        let storedUID = explicitUID ?? store.outputUID(for: bundleIdentifier)
        if let storedUID, let device = outputDevices.first(where: { $0.uid == storedUID }) {
            return AppOutputTarget(id: device.id, explicitUID: storedUID, name: device.name)
        }

        let defaultID = selectedOutputDeviceID == kAudioObjectUnknown ? outputManager.defaultOutputDeviceID() : selectedOutputDeviceID
        let defaultName = outputDevices.first(where: { $0.id == defaultID })?.name ?? "Default Output"
        return AppOutputTarget(id: defaultID, explicitUID: nil, name: defaultName)
    }

    private func defaultOutputTarget() -> AppOutputTarget? {
        let defaultID = selectedOutputDeviceID == kAudioObjectUnknown ? outputManager.defaultOutputDeviceID() : selectedOutputDeviceID
        guard defaultID != kAudioObjectUnknown else { return nil }
        let defaultName = outputDevices.first(where: { $0.id == defaultID })?.name ?? "Default Output"
        return AppOutputTarget(id: defaultID, explicitUID: nil, name: defaultName)
    }

    private func updateDefaultRoutedSessions(to deviceID: AudioObjectID) {
        let deviceName = outputDevices.first(where: { $0.id == deviceID })?.name ?? "Default Output"
        sessions = sessions.map { session in
            guard session.outputDeviceUID == nil else { return session }
            var updated = session
            updated.outputDeviceID = deviceID
            updated.outputDeviceName = deviceName
            if isProcessing {
                try? tapMixer.setOutputDeviceID(deviceID, forBundleIdentifier: session.audioProcessBundleIdentifier)
            }
            return updated
        }
    }

    private func resolveDisplayIdentity(pid: pid_t, audioBundleID: String) -> AppDisplayIdentity {
        let cacheKey = "\(pid):\(audioBundleID)"
        if let cached = identityCache[cacheKey] {
            return cached
        }

        if let bundleIdentity = displayIdentityFromProcessBundle(pid: pid, audioBundleID: audioBundleID) {
            identityCache[cacheKey] = bundleIdentity
            return bundleIdentity
        }

        let runningApp = NSRunningApplication(processIdentifier: pid)
        let runningApps = NSWorkspace.shared.runningApplications
        let candidateBundleIDs = displayBundleCandidates(for: audioBundleID)

        let matchedApp = candidateBundleIDs.compactMap { candidate in
            runningApps.first { $0.bundleIdentifier == candidate }
        }.first

        if let knownIdentity = knownBrowserIdentity(audioBundleID: audioBundleID, runningApps: runningApps) {
            identityCache[cacheKey] = knownIdentity
            return knownIdentity
        }

        let app = matchedApp ?? runningApp
        let bundleID = matchedApp?.bundleIdentifier ?? canonicalBundleIdentifier(for: audioBundleID)
        let rawName = app?.localizedName ?? bundleID
        let displayName = prettifiedAppName(rawName, bundleID: bundleID)
        let subtitle = audioBundleID == bundleID ? nil : "Audio helper"

        let identity = AppDisplayIdentity(
            bundleIdentifier: bundleID,
            displayName: displayName,
            icon: app?.icon,
            subtitle: subtitle
        )
        identityCache[cacheKey] = identity
        return identity
    }

    private func displayIdentityFromProcessBundle(pid: pid_t, audioBundleID: String) -> AppDisplayIdentity? {
        guard let executablePath = processExecutablePath(pid) else { return nil }
        for appURL in appBundleURLs(containingExecutableAt: executablePath) {
            guard let bundle = Bundle(url: appURL) else { continue }
            let bundleID = bundle.bundleIdentifier ?? audioBundleID
            let rawName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ??
                appURL.deletingPathExtension().lastPathComponent
            let displayName = prettifiedAppName(rawName, bundleID: bundleID)
            guard !displayName.isLikelyHelperName else { continue }

            return AppDisplayIdentity(
                bundleIdentifier: bundleID,
                displayName: displayName,
                icon: NSWorkspace.shared.icon(forFile: appURL.path),
                subtitle: audioBundleID == bundleID ? nil : "Audio helper"
            )
        }
        return nil
    }

    private func processExecutablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private func appBundleURLs(containingExecutableAt executablePath: String) -> [URL] {
        let pathURL = URL(fileURLWithPath: executablePath)
        let components = pathURL.pathComponents
        var appURLs: [URL] = []

        for index in components.indices where components[index].hasSuffix(".app") {
            let appPath = NSString.path(withComponents: Array(components[0...index]))
            appURLs.append(URL(fileURLWithPath: appPath))
        }

        return appURLs
    }

    private func knownBrowserIdentity(audioBundleID: String, runningApps: [NSRunningApplication]) -> AppDisplayIdentity? {
        let lowercasedBundleID = audioBundleID.lowercased()
        guard lowercasedBundleID.contains("company.thebrowser") else { return nil }

        let app = runningApps.first { app in
            app.localizedName == "Arc" ||
                app.bundleIdentifier?.lowercased().contains("thebrowser") == true
        }

        return AppDisplayIdentity(
            bundleIdentifier: app?.bundleIdentifier ?? "company.thebrowser.Browser",
            displayName: app?.localizedName ?? "Arc",
            icon: app?.icon ?? NSWorkspace.shared.icon(for: .applicationBundle),
            subtitle: "Audio helper"
        )
    }

    private func displayBundleCandidates(for bundleID: String) -> [String] {
        var candidates = [bundleID]
        let suffixes = [
            ".helper", ".Helper", ".helper.GPU", ".helper.Renderer", ".helper.Plugin",
            ".Helper.GPU", ".Helper.Renderer", ".Helper.Plugin", ".renderer", ".Renderer"
        ]
        for suffix in suffixes where bundleID.hasSuffix(suffix) {
            candidates.append(String(bundleID.dropLast(suffix.count)))
        }
        if let range = bundleID.range(of: ".helper", options: [.caseInsensitive, .backwards]) {
            candidates.append(String(bundleID[..<range.lowerBound]))
        }
        return candidates.uniqued()
    }

    private func canonicalBundleIdentifier(for bundleID: String) -> String {
        displayBundleCandidates(for: bundleID).last ?? bundleID
    }

    private func prettifiedAppName(_ name: String, bundleID: String) -> String {
        let helperWords = [" Helper", " helper", " Renderer", " GPU", " Plugin"]
        var value = name
        for word in helperWords {
            value = value.replacingOccurrences(of: word, with: "")
        }
        if value == bundleID, let last = bundleID.split(separator: ".").last {
            value = String(last)
        }
        return value.isEmpty ? "Unknown App" : value
    }

    private func userFacingAudioError(_ error: Error) -> String {
        let detail = error.localizedDescription
        if detail.localizedCaseInsensitiveContains("permission") || detail.localizedCaseInsensitiveContains("denied") {
            return "Allow AppMixer in System Settings > Privacy & Security > Screen & System Audio Recording, then restart the app."
        }
        return "AppMixer could not start system audio capture. Check Screen & System Audio Recording permission, then try again."
    }

    private func captureFailureMessage(from failureDetails: [String]) -> String {
        let detail = failureDetails.uniqued().prefix(2).joined(separator: "  ")
        if detail.isEmpty {
            return "CoreAudio rejected the process taps. If you just enabled AppMixer in System Settings, quit and reopen AppMixer."
        }
        return "\(detail). If AppMixer is already enabled in System Settings, quit and reopen AppMixer. During development, macOS can keep a stale audio-recording grant after each rebuilt app binary."
    }

    private func shortAudioError(_ error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "The operation couldn’t be completed. (com.clarity.appmixer.tap error ", with: "CoreAudio ")
            .replacingOccurrences(of: ".)", with: ")")
        return message
    }
}

struct StatusMessage: Equatable {
    enum Style {
        case warning
        case info
    }

    let title: String
    let detail: String
    let style: Style
}

private struct AppDisplayIdentity {
    let bundleIdentifier: String
    let displayName: String
    let icon: NSImage?
    let subtitle: String?
}

private struct AppOutputTarget {
    let id: AudioObjectID
    let explicitUID: String?
    let name: String
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Float {
    var clampedVolume: Float {
        min(max(self, 0), 1)
    }
}

private extension String {
    var isLikelyHelperName: Bool {
        let value = lowercased()
        return value == "helper" ||
            value.hasSuffix(" helper") ||
            value.contains(" renderer") ||
            value.contains(" gpu") ||
            value.contains(" plugin")
    }
}
