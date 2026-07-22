import AppKit
import Darwin
import Foundation

struct UpdateLaunchReadiness {
    private static let tokenArgument = "--y-clip-update-launch-token"
    private static let stateFileArgument = "--y-clip-update-launch-state"
    private static var current: UpdateLaunchReadiness?

    private let token: String
    private let stateFileURL: URL

    static func configureIfRequested(arguments: [String]) -> Bool {
        let tokens = argumentValues(for: tokenArgument, in: arguments)
        let stateFiles = argumentValues(for: stateFileArgument, in: arguments)
        guard !tokens.isEmpty || !stateFiles.isEmpty else {
            return true
        }
        guard
            tokens.count == 1,
            stateFiles.count == 1,
            UUID(uuidString: tokens[0]) != nil,
            stateFiles[0].hasPrefix("/")
        else {
            return false
        }

        let stateFileURL = URL(fileURLWithPath: stateFiles[0]).standardizedFileURL
        guard stateFileURL.path == stateFiles[0] else {
            return false
        }
        let parentURL = stateFileURL.deletingLastPathComponent()
        let parentValues = try? parentURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard
            parentValues?.isDirectory == true,
            parentValues?.isSymbolicLink != true,
            pathDoesNotExist(stateFileURL)
        else {
            return false
        }

        let readiness = UpdateLaunchReadiness(
            token: tokens[0],
            stateFileURL: stateFileURL
        )
        guard readiness.writeState("STARTING") else {
            return false
        }
        current = readiness
        return true
    }

    static func markApplicationReady() {
        _ = current?.writeState("READY")
    }

    private static func argumentValues(for name: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == name, arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
    }

    private static func pathDoesNotExist(_ url: URL) -> Bool {
        var fileStatus = stat()
        let result = url.path.withCString { path in
            lstat(path, &fileStatus)
        }
        return result != 0 && errno == ENOENT
    }

    private func writeState(_ state: String) -> Bool {
        var fileStatus = stat()
        let statusResult = stateFileURL.path.withCString { path in
            lstat(path, &fileStatus)
        }
        if statusResult == 0 {
            guard (fileStatus.st_mode & S_IFMT) == S_IFREG else {
                return false
            }
        } else if errno != ENOENT {
            return false
        }

        do {
            let content = "\(state) \(token) \(getpid())\n"
            try Data(content.utf8).write(to: stateFileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateFileURL.path
            )
            return true
        } catch {
            return false
        }
    }
}

private enum UpdatePathSwapHelper {
    static let swapCommand = "--transactional-update-swap"
    static let exclusiveRenameCommand = "--transactional-update-rename-exclusive"

    static func runIfRequested(arguments: [String]) -> Int32? {
        guard let command = arguments.dropFirst().first,
              command == swapCommand || command == exclusiveRenameCommand else {
            return nil
        }
        guard arguments.count == 4 else {
            return 64
        }

        let firstURL = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        let secondURL = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        guard firstURL.deletingLastPathComponent() == secondURL.deletingLastPathComponent() else {
            return 65
        }

        if command == swapCommand {
            guard
                isAllowedSwapPair(firstURL: firstURL, secondURL: secondURL),
                isRegularApplicationDirectory(firstURL),
                isRegularApplicationDirectory(secondURL)
            else {
                return 65
            }
            return rename(firstURL, secondURL, flags: UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY))
        }

        guard
            isAllowedExclusiveRenamePair(firstURL: firstURL, secondURL: secondURL),
            isRegularApplicationDirectory(firstURL),
            pathDoesNotExist(secondURL)
        else {
            return 65
        }
        return rename(firstURL, secondURL, flags: UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY))
    }

    private static func rename(_ firstURL: URL, _ secondURL: URL, flags: UInt32) -> Int32 {
        let result = firstURL.path.withCString { firstPath in
            secondURL.path.withCString { secondPath in
                renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, flags)
            }
        }
        return result == 0 ? 0 : 71
    }

    private static func isAllowedSwapPair(firstURL: URL, secondURL: URL) -> Bool {
        let names = Set([firstURL.lastPathComponent, secondURL.lastPathComponent])
        guard names.contains("Y-Clip.app") else {
            return false
        }
        return names.contains { name in
            name.hasPrefix(".Y-Clip-update-") || name.hasPrefix(".Y-Clip-backup-")
        }
    }

    private static func isAllowedExclusiveRenamePair(firstURL: URL, secondURL: URL) -> Bool {
        let names = [firstURL.lastPathComponent, secondURL.lastPathComponent]
        let movesPrimary = names.contains("Y-Clip.app")
            && names.contains { $0.hasPrefix(".Y-Clip-update-") }
        let movesBackup = names.contains { $0.hasPrefix(".Y-Clip-update-") }
            && names.contains { $0.hasPrefix(".Y-Clip-backup-") }
        let movesLegacy = names.contains("Global Clipboard.app")
            && names.contains { $0.hasPrefix(".Global-Clipboard-remove-") }
        return movesPrimary || movesBackup || movesLegacy
    }

    private static func isRegularApplicationDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func pathDoesNotExist(_ url: URL) -> Bool {
        var fileStatus = stat()
        let result = url.path.withCString { path in
            lstat(path, &fileStatus)
        }
        return result != 0 && errno == ENOENT
    }
}

if let exitStatus = UpdatePathSwapHelper.runIfRequested(arguments: CommandLine.arguments) {
    exit(exitStatus)
}
guard UpdateLaunchReadiness.configureIfRequested(arguments: CommandLine.arguments) else {
    exit(74)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
