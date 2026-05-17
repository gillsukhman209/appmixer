import AppKit
import CoreAudio

struct ProcessAudioSession: Identifiable, Equatable {
    let id: String
    let processObjectID: AudioObjectID
    let pid: pid_t
    let audioProcessBundleIdentifier: String
    let bundleIdentifier: String
    let displayName: String
    let icon: NSImage?
    let subtitle: String?
    var outputDeviceID: AudioObjectID
    var outputDeviceUID: String?
    var outputDeviceName: String
    var volume: Float
    var isMuted: Bool
    var isTapRunning: Bool
    var peakLevel: Float = 0

    static func == (lhs: ProcessAudioSession, rhs: ProcessAudioSession) -> Bool {
        lhs.id == rhs.id &&
        lhs.outputDeviceID == rhs.outputDeviceID &&
        lhs.outputDeviceUID == rhs.outputDeviceUID &&
        lhs.volume == rhs.volume &&
        lhs.isMuted == rhs.isMuted &&
        lhs.isTapRunning == rhs.isTapRunning &&
        lhs.peakLevel == rhs.peakLevel
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let isLikelyHeadsetMicrophone: Bool
    let isLikelyBuiltInMicrophone: Bool
}

struct OutputProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var masterVolume: Float
    var appSettings: [String: OutputProfileAppSetting]
}

struct OutputProfileAppSetting: Codable, Equatable {
    var volume: Float
    var isMuted: Bool
    var outputDeviceUID: String?
}
