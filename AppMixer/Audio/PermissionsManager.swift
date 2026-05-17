import Foundation

final class PermissionsManager {
    var canUseProcessTaps: Bool {
        if #available(macOS 14.2, *) {
            true
        } else {
            false
        }
    }

    var processTapAvailabilityMessage: String? {
        guard !canUseProcessTaps else { return nil }
        return "Apple's process tap API required for app-level capture is available on macOS 14.2+. On macOS 13, install the AudioServerPlugIn virtual device; per-client volume depends on HAL client buffers exposed to that plug-in."
    }
}
