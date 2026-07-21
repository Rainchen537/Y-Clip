import AppKit
import Foundation

enum SoftwareUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(String)
    case available(version: String, assetURL: URL, releaseURL: URL)
    case installing(String)
    case failed(String)
}

final class SoftwareUpdateController {
    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private struct UpdateValidationError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/Rainchen537/Y-Clip/releases/latest")!
    private var isChecking = false
    private var availableAssetURL: URL?
    var onStatusChange: ((SoftwareUpdateStatus) -> Void)?

    func checkForUpdates() {
        guard !isChecking else {
            return
        }

        isChecking = true
        availableAssetURL = nil
        onStatusChange?(.checking)

        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isChecking = false
            }

            if let error {
                DispatchQueue.main.async {
                    self?.onStatusChange?(.failed(error.localizedDescription))
                }
                return
            }

            guard
                let data,
                let release = try? JSONDecoder().decode(Release.self, from: data),
                !release.draft,
                !release.prerelease
            else {
                DispatchQueue.main.async {
                    self?.onStatusChange?(.failed("无法读取 GitHub 最新版本信息。"))
                }
                return
            }

            DispatchQueue.main.async {
                self?.handle(release: release)
            }
        }.resume()
    }

    func installAvailableUpdate() {
        guard let availableAssetURL else {
            checkForUpdates()
            return
        }

        downloadAndInstall(assetURL: availableAssetURL)
    }

    private func handle(release: Release) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

        guard isVersion(latestVersion, newerThan: currentVersion) else {
            onStatusChange?(.upToDate(currentVersion))
            return
        }

        let architecture = SoftwareUpdateAssetSelector.compiledArchitecture
        let expectedAssetName = SoftwareUpdateAssetSelector.expectedAssetName(
            releaseVersion: latestVersion,
            architecture: architecture
        )
        let selectedAssetName = SoftwareUpdateAssetSelector.selectAssetName(
            from: release.assets.map(\.name),
            releaseVersion: latestVersion,
            architecture: architecture
        )

        guard
            let selectedAssetName,
            let asset = release.assets.first(where: { $0.name == selectedAssetName })
        else {
            onStatusChange?(.failed("发现 \(release.tagName)，但缺少当前架构 \(architecture) 的完整资产 \(expectedAssetName ?? "未知")。已打开 Release 页面，请手动确认下载。"))
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        availableAssetURL = asset.browserDownloadURL
        onStatusChange?(.available(version: release.tagName, assetURL: asset.browserDownloadURL, releaseURL: release.htmlURL))
    }

    private func downloadAndInstall(assetURL: URL) {
        guard FileManager.default.isWritableFile(atPath: "/Applications") else {
            onStatusChange?(.failed("没有写入 /Applications 的权限，请手动下载 DMG 安装。"))
            return
        }

        onStatusChange?(.installing("正在下载更新…"))

        URLSession.shared.downloadTask(with: assetURL) { [weak self] temporaryURL, _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.onStatusChange?(.failed(error.localizedDescription))
                }
                return
            }

            guard let temporaryURL else {
                DispatchQueue.main.async {
                    self?.onStatusChange?(.failed("没有收到安装包文件。"))
                }
                return
            }

            do {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("YClipUpdate-\(UUID().uuidString).dmg")
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                DispatchQueue.main.async {
                    self?.onStatusChange?(.installing("正在安装并重启…"))
                    self?.installAndRestart(from: destination)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.onStatusChange?(.failed(error.localizedDescription))
                }
            }
        }.resume()
    }

    private func installAndRestart(from dmgURL: URL) {
        var preparedApplicationURL: URL?
        do {
            let validatedApplicationURL = try prepareIncomingApplication(from: dmgURL)
            preparedApplicationURL = validatedApplicationURL
            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("install-y-clip-\(UUID().uuidString).zsh")
            let script = """
            #!/bin/zsh
            set -euo pipefail
            DMG="$1"
            SOURCE="$2"
            SOURCE_ROOT="$(dirname "$SOURCE")"
            DEST="\(YClipApplicationIdentity.installedApplicationPath)"
            LEGACY_DEST="/Applications/Global Clipboard.app"
            EXEC="GlobalClipboard"
            BUNDLE_ID="\(YClipApplicationIdentity.bundleIdentifier)"
            TEAM_ID="\(YClipApplicationIdentity.teamIdentifier)"
            EXPECTED_ARCH="\(SoftwareUpdateAssetSelector.compiledArchitecture)"
            LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            CANDIDATE="/Applications/.Y-Clip-update-$(uuidgen).app"
            BACKUP="/Applications/.Y-Clip-backup-$(uuidgen).app"

            cleanup() {
              rm -rf "$CANDIDATE" "$SOURCE_ROOT"
              rm -f "$DMG" "$0"
            }
            trap cleanup EXIT

            validate_app() {
              local app="$1"
              [[ -d "$app" && ! -L "$app" ]]
              local plist_bundle_id executable_name executable_path actual_archs
              plist_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
              [[ "$plist_bundle_id" == "$BUNDLE_ID" ]]
              executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
              [[ "$executable_name" == "$EXEC" ]]
              executable_path="$app/Contents/MacOS/$executable_name"
              [[ -f "$executable_path" && ! -L "$executable_path" ]]
              actual_archs="$(/usr/bin/lipo -archs "$executable_path")"
              [[ "$actual_archs" == "$EXPECTED_ARCH" ]]
              /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null
              local signature_info
              signature_info="$(/usr/bin/codesign -dvvv "$app" 2>&1)"
              grep -Fqx "Identifier=$BUNDLE_ID" <<< "$signature_info"
              grep -Fqx "TeamIdentifier=$TEAM_ID" <<< "$signature_info"
              grep -Fq "Authority=Developer ID Application:" <<< "$signature_info"
              grep -Fq "($TEAM_ID)" <<< "$signature_info"
              grep -q "flags=.*runtime" <<< "$signature_info"
              /usr/sbin/spctl -a -t exec -vvv "$app" >/dev/null
            }

            validate_app "$SOURCE"
            while pgrep -x "$EXEC" >/dev/null 2>&1; do
              sleep 0.2
            done

            /usr/bin/ditto "$SOURCE" "$CANDIDATE"
            validate_app "$CANDIDATE"

            if [[ -e "$DEST" || -L "$DEST" ]]; then
              mv "$DEST" "$BACKUP"
            fi
            if ! mv "$CANDIDATE" "$DEST"; then
              [[ -e "$BACKUP" || -L "$BACKUP" ]] && mv "$BACKUP" "$DEST"
              exit 1
            fi
            rm -rf "$BACKUP"

            if [[ "$LEGACY_DEST" != "$DEST" && ( -e "$LEGACY_DEST" || -L "$LEGACY_DEST" ) ]]; then
              rm -rf "$LEGACY_DEST"
            fi
            [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
            touch "$DEST"
            /usr/bin/open -n "$DEST" >/dev/null 2>&1 || /usr/bin/open "$DEST"
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, dmgURL.path, validatedApplicationURL.path]
            try process.run()

            NSApp.terminate(nil)
        } catch {
            if let preparedApplicationURL {
                try? FileManager.default.removeItem(at: preparedApplicationURL.deletingLastPathComponent())
            }
            try? FileManager.default.removeItem(at: dmgURL)
            onStatusChange?(.failed(error.localizedDescription))
        }
    }

    private func prepareIncomingApplication(from dmgURL: URL) throws -> URL {
        try runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--verbose=4", dmgURL.path],
            failureMessage: "下载的 DMG 签名无效。"
        )
        try runProcess(
            executable: "/usr/sbin/spctl",
            arguments: ["-a", "-vvv", "-t", "open", "--context", "context:primary-signature", dmgURL.path],
            failureMessage: "下载的 DMG 未通过 Gatekeeper 验证。"
        )

        let fileManager = FileManager.default
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("YClipUpdate-\(UUID().uuidString)", isDirectory: true)
        let mountURL = stagingRoot.appendingPathComponent("mount", isDirectory: true)
        let preparedApplicationURL = stagingRoot.appendingPathComponent("Y-Clip.app", isDirectory: true)
        try fileManager.createDirectory(at: mountURL, withIntermediateDirectories: true)
        var isMounted = false

        do {
            try runProcess(
                executable: "/usr/bin/hdiutil",
                arguments: [
                    "attach",
                    dmgURL.path,
                    "-mountpoint",
                    mountURL.path,
                    "-nobrowse",
                    "-noautoopen",
                    "-readonly"
                ],
                failureMessage: "无法挂载下载的 DMG。"
            )
            isMounted = true

            let primaryApplicationURL = mountURL.appendingPathComponent("Y-Clip.app", isDirectory: true)
            let legacyApplicationURL = mountURL.appendingPathComponent("Global Clipboard.app", isDirectory: true)
            let incomingApplicationURL: URL
            if fileManager.fileExists(atPath: primaryApplicationURL.path) {
                incomingApplicationURL = primaryApplicationURL
            } else if fileManager.fileExists(atPath: legacyApplicationURL.path) {
                incomingApplicationURL = legacyApplicationURL
            } else {
                throw UpdateValidationError(message: "DMG 中没有找到 Y-Clip.app。")
            }

            guard YSettingRuntimeIdentity.isValidSignedApplication(
                atPath: incomingApplicationURL.path,
                expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier,
                expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier
            ) else {
                throw UpdateValidationError(
                    message: "更新包中的 App 身份无效。必须是 Bundle ID 为 \(YClipApplicationIdentity.bundleIdentifier)、团队为 \(YClipApplicationIdentity.teamIdentifier) 的 Developer ID Application 签名，并启用 hardened runtime。"
                )
            }

            try verifyIncomingApplicationArchitecture(at: incomingApplicationURL)
            try verifyIncomingApplication(at: incomingApplicationURL)
            try runProcess(
                executable: "/usr/bin/ditto",
                arguments: [incomingApplicationURL.path, preparedApplicationURL.path],
                failureMessage: "无法准备已验证的更新 App。"
            )

            guard YSettingRuntimeIdentity.isValidSignedApplication(
                atPath: preparedApplicationURL.path,
                expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier,
                expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier
            ) else {
                throw UpdateValidationError(message: "复制后的更新 App 身份验证失败。")
            }
            try verifyIncomingApplicationArchitecture(at: preparedApplicationURL)
            try verifyIncomingApplication(at: preparedApplicationURL)
        } catch {
            if isMounted {
                _ = try? runProcess(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", mountURL.path, "-force"],
                    failureMessage: ""
                )
            }
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }

        if isMounted {
            do {
                try runProcess(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", mountURL.path],
                    failureMessage: "无法卸载更新 DMG。"
                )
                isMounted = false
            } catch {
                _ = try? runProcess(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", mountURL.path, "-force"],
                    failureMessage: ""
                )
                try? fileManager.removeItem(at: stagingRoot)
                throw error
            }
        }
        try? fileManager.removeItem(at: mountURL)
        return preparedApplicationURL
    }

    private func verifyIncomingApplicationArchitecture(at applicationURL: URL) throws {
        let infoPlistURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        let infoPlistData: Data
        do {
            infoPlistData = try Data(contentsOf: infoPlistURL)
        } catch {
            throw UpdateValidationError(message: "无法读取更新 App 的 Info.plist。")
        }

        guard
            let infoDictionary = try? PropertyListSerialization.propertyList(
                from: infoPlistData,
                options: [],
                format: nil
            ) as? [String: Any],
            let executableName = infoDictionary["CFBundleExecutable"] as? String,
            executableName == "GlobalClipboard"
        else {
            throw UpdateValidationError(message: "更新 App 的主可执行文件标识无效。")
        }

        let executableURL = applicationURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        let resourceValues: URLResourceValues
        do {
            resourceValues = try executableURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw UpdateValidationError(message: "无法检查更新 App 的主可执行文件。")
        }
        guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else {
            throw UpdateValidationError(message: "更新 App 的主可执行文件无效。")
        }

        let reportedArchitectures = try runProcess(
            executable: "/usr/bin/lipo",
            arguments: ["-archs", executableURL.path],
            failureMessage: "无法读取更新 App 的主可执行文件架构。"
        )
        let expectedArchitecture = SoftwareUpdateAssetSelector.compiledArchitecture
        guard SoftwareUpdateAssetSelector.isExpectedThinArchitecture(
            reportedArchitectures: reportedArchitectures,
            expectedArchitecture: expectedArchitecture
        ) else {
            throw UpdateValidationError(
                message: "更新 App 必须是当前架构 \(expectedArchitecture) 的 thin binary，实际架构为 \(reportedArchitectures.isEmpty ? "未知" : reportedArchitectures)。现有 App 未被替换。"
            )
        }
    }

    private func verifyIncomingApplication(at applicationURL: URL) throws {
        try runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", applicationURL.path],
            failureMessage: "更新 App 未通过 codesign 验证。"
        )
        try runProcess(
            executable: "/usr/sbin/spctl",
            arguments: ["-a", "-t", "exec", "-vvv", applicationURL.path],
            failureMessage: "更新 App 未通过 Gatekeeper 验证。"
        )
    }

    @discardableResult
    private func runProcess(
        executable: String,
        arguments: [String],
        failureMessage: String
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw UpdateValidationError(message: "\(failureMessage) \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = output.isEmpty ? "" : "\n\(output)"
            throw UpdateValidationError(message: "\(failureMessage)\(detail)")
        }
        return output
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r {
                return l > r
            }
        }

        return false
    }
}
