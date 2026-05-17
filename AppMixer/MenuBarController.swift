import AppKit

final class MenuBarController {
    func activate() {
        NSApp.setActivationPolicy(.accessory)
    }
}
