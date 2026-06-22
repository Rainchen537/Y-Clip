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

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/Rainchen537/global-clipboard/releases/latest")!
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

        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            onStatusChange?(.failed("发现 \(release.tagName)，但没有可自动安装的 DMG。"))
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
        do {
            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("install-y-clip-\(UUID().uuidString).zsh")
            let script = """
            #!/bin/zsh
            set -euo pipefail
            DMG="$1"
            DEST="/Applications/Y-Clip.app"
            LEGACY_DEST="/Applications/Global Clipboard.app"
            EXEC="GlobalClipboard"
            BUNDLE_ID="com.lixingchen.GlobalClipboard"
            LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            MOUNT="$(hdiutil attach "$DMG" -nobrowse -noautoopen | awk '/\\/Volumes\\// { for (i=3; i<=NF; i++) { printf "%s%s", (i==3 ? "" : " "), $i } print ""; exit }')"
            APP="$MOUNT/Y-Clip.app"
            if [[ ! -d "$APP" ]]; then
              APP="$MOUNT/Global Clipboard.app"
            fi
            while pgrep -x "$EXEC" >/dev/null 2>&1; do
              sleep 0.2
            done
            if [[ -d "$DEST" ]]; then
              find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
            else
              mkdir -p "$DEST"
            fi
            ditto "$APP" "$DEST"
            xattr -cr "$DEST"
            codesign --verify --strict --verbose=2 "$DEST" >/dev/null
            if [[ "$LEGACY_DEST" != "$DEST" && -d "$LEGACY_DEST" ]]; then
              find "$LEGACY_DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
              rmdir "$LEGACY_DEST" 2>/dev/null || true
            fi
            [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
            touch "$DEST"
            hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
            rm -f "$DMG" "$0"
            open -b "$BUNDLE_ID" >/dev/null 2>&1 || open "$DEST"
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, dmgURL.path]
            try process.run()

            NSApp.terminate(nil)
        } catch {
            onStatusChange?(.failed(error.localizedDescription))
        }
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
