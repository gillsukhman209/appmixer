import Foundation

final class InstallerHelper {
    enum InstallerError: LocalizedError {
        case missingScript
        case failed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .missingScript:
                return "Install script was not found inside the app bundle. Build from the repository or run Scripts/install_driver.sh manually."
            case .failed(let status, let output):
                return "Driver install failed with status \(status): \(output)"
            }
        }
    }

    func installVirtualDevice() throws {
        let scriptURL: URL
        if let bundledScript = Bundle.main.url(forResource: "install_driver", withExtension: "sh") {
            scriptURL = bundledScript
        } else {
            scriptURL = URL(fileURLWithPath: "/Users/sukhmansingh/Desktop/Coding/2026/AppMixer/Scripts/install_driver.sh")
        }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw InstallerError.missingScript
        }
        let process = Process()
        let pipe = Pipe()
        let escapedPath = scriptURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script quoted form of \"\(escapedPath)\" with administrator privileges"
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw InstallerError.failed(process.terminationStatus, output)
        }
    }
}
