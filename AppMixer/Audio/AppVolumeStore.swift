import Foundation

final class AppVolumeStore {
    private let defaults = UserDefaults.standard
    private let volumeKey = "AppMixer.volumes"
    private let muteKey = "AppMixer.mutes"
    private let outputKey = "AppMixer.outputs"
    private let masterKey = "AppMixer.masterVolume"
    private let preferredInputKey = "AppMixer.preferredInputUID"
    private let microphoneGuardKey = "AppMixer.microphoneGuardEnabled"

    var masterVolume: Float {
        get {
            let value = defaults.object(forKey: masterKey) as? Double
            return Self.clampVolume(Float(value ?? 1.0))
        }
        set {
            defaults.set(Double(Self.clampVolume(newValue)), forKey: masterKey)
        }
    }

    func volume(for bundleID: String) -> Float {
        let values = defaults.dictionary(forKey: volumeKey) as? [String: Double] ?? [:]
        return Self.clampVolume(Float(values[bundleID] ?? 1.0))
    }

    func setVolume(_ volume: Float, for bundleID: String) {
        var values = defaults.dictionary(forKey: volumeKey) as? [String: Double] ?? [:]
        values[bundleID] = Double(Self.clampVolume(volume))
        defaults.set(values, forKey: volumeKey)
    }

    func isMuted(_ bundleID: String) -> Bool {
        let values = defaults.dictionary(forKey: muteKey) as? [String: Bool] ?? [:]
        return values[bundleID] ?? false
    }

    func setMuted(_ muted: Bool, for bundleID: String) {
        var values = defaults.dictionary(forKey: muteKey) as? [String: Bool] ?? [:]
        values[bundleID] = muted
        defaults.set(values, forKey: muteKey)
    }

    func outputUID(for bundleID: String) -> String? {
        let values = defaults.dictionary(forKey: outputKey) as? [String: String] ?? [:]
        return values[bundleID]
    }

    func setOutputUID(_ outputUID: String?, for bundleID: String) {
        var values = defaults.dictionary(forKey: outputKey) as? [String: String] ?? [:]
        values[bundleID] = outputUID
        defaults.set(values, forKey: outputKey)
    }

    var preferredInputUID: String? {
        get {
            defaults.string(forKey: preferredInputKey)
        }
        set {
            defaults.set(newValue, forKey: preferredInputKey)
        }
    }

    var microphoneGuardEnabled: Bool {
        get {
            defaults.object(forKey: microphoneGuardKey) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: microphoneGuardKey)
        }
    }

    private static func clampVolume(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
