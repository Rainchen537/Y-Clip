import AppKit
import ApplicationServices
import Darwin

enum YClipApplicationIdentity {
    static let bundleIdentifier = "com.lixingchen.GlobalClipboard"
    static let teamIdentifier = "A94225N8T5"
    static let installedApplicationPath = "/Applications/Y-Clip.app"
}

enum AccessibilityRepairResult {
    case authorizationRequested
    case switchingToInstalledCopy
    case installedCopyRequired
    case failed(String)
}

enum AccessibilityPermission {
    private struct ResetError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestPrompt() {
        _ = isTrusted(prompt: true)
    }

    static func resetAuthorization() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", YClipApplicationIdentity.bundleIdentifier]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        try waitForProcess(process, timeout: 10)

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ResetError(message: message?.isEmpty == false ? message! : "刷新辅助功能权限记录失败。")
        }
    }

    private static func waitForProcess(_ process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw ResetError(message: "刷新辅助功能权限记录超时。")
        }
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
