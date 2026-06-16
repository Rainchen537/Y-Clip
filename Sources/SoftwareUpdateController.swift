import AppKit
import Foundation

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

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/Rainchen537/global-clipboard/releases/latest")!
    private var isChecking = false

    func checkForUpdates(userInitiated: Bool) {
        guard !isChecking else {
            return
        }

        isChecking = true

        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isChecking = false
            }

            if let error {
                DispatchQueue.main.async {
                    if userInitiated {
                        self?.showAlert(title: "检查更新失败", message: error.localizedDescription)
                    }
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
                    if userInitiated {
                        self?.showAlert(title: "检查更新失败", message: "无法读取 GitHub 最新版本信息。")
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self?.handle(release: release, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handle(release: Release, userInitiated: Bool) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

        guard isVersion(latestVersion, newerThan: currentVersion) else {
            if userInitiated {
                showAlert(title: "已经是最新版", message: "当前版本 \(currentVersion) 已是最新。")
            }
            return
        }

        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            showUpdateReleasePageAlert(release: release)
            return
        }

        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.tagName)"
        alert.informativeText = "可以自动下载并安装最新版。安装时应用会短暂退出并重新打开。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "打开 GitHub")
        alert.addButton(withTitle: "稍后")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            downloadAndInstall(assetURL: asset.browserDownloadURL)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    private func downloadAndInstall(assetURL: URL) {
        guard FileManager.default.isWritableFile(atPath: "/Applications") else {
            showAlert(
                title: "无法自动安装",
                message: "当前用户没有写入 /Applications 的权限。请从 GitHub Release 手动下载 DMG 安装。"
            )
            return
        }

        let waitingAlert = NSAlert()
        waitingAlert.messageText = "正在下载更新"
        waitingAlert.informativeText = "下载完成后会自动安装并重启应用。"
        waitingAlert.alertStyle = .informational
        waitingAlert.addButton(withTitle: "好")
        waitingAlert.runModal()

        URLSession.shared.downloadTask(with: assetURL) { [weak self] temporaryURL, _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.showAlert(title: "下载更新失败", message: error.localizedDescription)
                }
                return
            }

            guard let temporaryURL else {
                DispatchQueue.main.async {
                    self?.showAlert(title: "下载更新失败", message: "没有收到安装包文件。")
                }
                return
            }

            do {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GlobalClipboardUpdate-\(UUID().uuidString).dmg")
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                DispatchQueue.main.async {
                    self?.installAndRestart(from: destination)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showAlert(title: "保存更新失败", message: error.localizedDescription)
                }
            }
        }.resume()
    }

    private func installAndRestart(from dmgURL: URL) {
        do {
            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("install-global-clipboard-\(UUID().uuidString).zsh")
            let script = """
            #!/bin/zsh
            set -euo pipefail
            DMG="$1"
            DEST="/Applications/Global Clipboard.app"
            EXEC="GlobalClipboard"
            MOUNT="$(hdiutil attach "$DMG" -nobrowse -noautoopen | awk '/\\/Volumes\\// { for (i=3; i<=NF; i++) { printf "%s%s", (i==3 ? "" : " "), $i } print ""; exit }')"
            APP="$MOUNT/Global Clipboard.app"
            while pgrep -x "$EXEC" >/dev/null 2>&1; do
              sleep 0.2
            done
            rm -rf "$DEST"
            ditto "$APP" "$DEST"
            xattr -cr "$DEST"
            hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
            rm -f "$DMG" "$0"
            open "$DEST"
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, dmgURL.path]
            try process.run()

            NSApp.terminate(nil)
        } catch {
            showAlert(title: "安装更新失败", message: error.localizedDescription)
        }
    }

    private func showUpdateReleasePageAlert(release: Release) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.tagName)"
        alert.informativeText = "没有找到可自动安装的 DMG 附件，可以打开 GitHub Release 手动下载。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开 GitHub")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
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
