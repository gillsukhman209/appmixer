import CoreAudio
import Foundation

final class VirtualAudioDevice {
    static let pluginBundleIdentifier = "com.clarity.appmixer.driver"
    static let deviceUID = "com.clarity.appmixer.virtual-output"

    private let outputDeviceManager = OutputDeviceManager()

    func installedDevice() -> OutputDevice? {
        outputDeviceManager.outputDevices().first { $0.uid == Self.deviceUID || $0.name == "AppMixer Virtual Output" }
    }

    func makeSystemOutput() -> OSStatus {
        guard let device = installedDevice() else {
            return kAudioHardwareBadDeviceError
        }
        return outputDeviceManager.setDefaultOutputDevice(device.id)
    }
}
