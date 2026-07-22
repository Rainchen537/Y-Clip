import AppKit
import Darwin
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
    private var availableVersion: String?
    var onStatusChange: ((SoftwareUpdateStatus) -> Void)?

    func checkForUpdates() {
        guard !isChecking else {
            return
        }

        isChecking = true
        availableAssetURL = nil
        availableVersion = nil
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
        guard let availableAssetURL, let availableVersion else {
            checkForUpdates()
            return
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard SoftwareUpdateAssetSelector.isVersion(availableVersion, newerThan: currentVersion) else {
            self.availableAssetURL = nil
            self.availableVersion = nil
            onStatusChange?(.failed("待安装版本不再高于当前版本，已停止更新。请重新检查。"))
            return
        }

        downloadAndInstall(assetURL: availableAssetURL, expectedVersion: availableVersion)
    }

    private func handle(release: Release) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let latestVersion = SoftwareUpdateAssetSelector.normalizedVersionString(release.tagName)

        guard SoftwareUpdateAssetSelector.isVersion(latestVersion, newerThan: currentVersion) else {
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
        availableVersion = latestVersion
        onStatusChange?(.available(version: release.tagName, assetURL: asset.browserDownloadURL, releaseURL: release.htmlURL))
    }

    private func downloadAndInstall(assetURL: URL, expectedVersion: String) {
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
                    self?.installAndRestart(from: destination, expectedVersion: expectedVersion)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.onStatusChange?(.failed(error.localizedDescription))
                }
            }
        }.resume()
    }

    private func installAndRestart(from dmgURL: URL, expectedVersion: String) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard SoftwareUpdateAssetSelector.isVersion(expectedVersion, newerThan: currentVersion) else {
            try? FileManager.default.removeItem(at: dmgURL)
            onStatusChange?(.failed("下载版本不高于当前版本，已停止安装。"))
            return
        }

        let runningApplicationURL = Bundle.main.bundleURL.standardizedFileURL
        let primaryApplicationURL = URL(
            fileURLWithPath: YClipApplicationIdentity.installedApplicationPath,
            isDirectory: true
        ).standardizedFileURL
        let legacyApplicationURL = URL(
            fileURLWithPath: "/Applications/Global Clipboard.app",
            isDirectory: true
        ).standardizedFileURL
        guard
            runningApplicationURL == primaryApplicationURL || runningApplicationURL == legacyApplicationURL,
            YSettingRuntimeIdentity.isValidSignedApplication(
                atPath: runningApplicationURL.path,
                expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier,
                expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier
            )
        else {
            try? FileManager.default.removeItem(at: dmgURL)
            onStatusChange?(.failed("自动更新只支持 /Applications 中经过验证的 Y-Clip 正式安装副本。"))
            return
        }

        var preparedApplicationURL: URL?
        do {
            let validatedApplicationURL = try prepareIncomingApplication(
                from: dmgURL,
                expectedVersion: expectedVersion,
                currentVersion: currentVersion
            )
            preparedApplicationURL = validatedApplicationURL
            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("install-y-clip-\(UUID().uuidString).zsh")
            let script = """
            #!/bin/zsh
            set -euo pipefail
            DMG="$1"
            SOURCE="$2"
            EXPECTED_VERSION="$3"
            CURRENT_VERSION="$4"
            CURRENT_APP="$5"
            APP_PID="$6"
            SOURCE_ROOT="$(/usr/bin/dirname "$SOURCE")"
            DEST="\(YClipApplicationIdentity.installedApplicationPath)"
            LEGACY_DEST="/Applications/Global Clipboard.app"
            EXEC="GlobalClipboard"
            BUNDLE_ID="\(YClipApplicationIdentity.bundleIdentifier)"
            TEAM_ID="\(YClipApplicationIdentity.teamIdentifier)"
            EXPECTED_ARCH="\(SoftwareUpdateAssetSelector.compiledArchitecture)"
            LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            CANDIDATE=""
            BACKUP=""
            LEGACY_QUARANTINE=""
            candidate_owned=0
            primary_existed=0
            primary_swapped=0
            new_primary_created=0
            legacy_present=0
            legacy_quarantined=0
            parent_exit_authorized=0
            parent_wait_active=0
            lock_owned=0
            lock_directory=""
            launched_app_pid=""
            launch_state_directory=""
            launch_state_file=""
            launch_token=""
            transaction_committed=0
            transaction_state_change_active=0
            termination_pending=0

            validate_identity() {
              local app="$1"
              local info_plist="$app/Contents/Info.plist"
              local plist_bundle_id executable_name executable_path signature_info

              [[ -d "$app" && ! -L "$app" ]] || return 1
              [[ -f "$info_plist" && ! -L "$info_plist" ]] || return 1
              plist_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" || return 1
              [[ "$plist_bundle_id" == "$BUNDLE_ID" ]] || return 1
              executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" || return 1
              [[ "$executable_name" == "$EXEC" ]] || return 1
              executable_path="$app/Contents/MacOS/$executable_name"
              [[ -f "$executable_path" && ! -L "$executable_path" ]] || return 1
              /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null || return 1
              signature_info="$(/usr/bin/codesign -dvvv "$app" 2>&1)" || return 1
              /usr/bin/grep -Fqx "Identifier=$BUNDLE_ID" <<< "$signature_info" || return 1
              /usr/bin/grep -Fqx "TeamIdentifier=$TEAM_ID" <<< "$signature_info" || return 1
              /usr/bin/grep -Fq "Authority=Developer ID Application:" <<< "$signature_info" || return 1
              /usr/bin/grep -Fq "($TEAM_ID)" <<< "$signature_info" || return 1
              /usr/bin/grep -q "flags=.*runtime" <<< "$signature_info" || return 1
              /usr/sbin/spctl -a -t exec -vvv "$app" >/dev/null || return 1
            }

            validate_app() {
              local app="$1"
              local required_version="$2"
              local executable_path="$app/Contents/MacOS/$EXEC"
              local actual_archs actual_version

              validate_identity "$app" || return 1
              actual_archs="$(/usr/bin/lipo -archs "$executable_path" | /usr/bin/xargs)" || return 1
              [[ "$actual_archs" == "$EXPECTED_ARCH" ]] || return 1
              actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" || return 1
              [[ "$actual_version" == "$required_version" ]] || return 1
            }

            is_expected_app_process() {
              local pid="$1"
              local app="$2"
              local expected_executable="$app/Contents/MacOS/$EXEC"
              local actual_executable

              [[ "$pid" == <-> ]] || return 1
              /bin/kill -0 "$pid" 2>/dev/null || return 1
              actual_executable="$(/bin/ps -p "$pid" -o comm= | /usr/bin/xargs)" || return 1
              [[ "$actual_executable" == "$expected_executable" ]] || return 1
            }

            stop_app_process() {
              local pid="$1"
              local app="$2"
              local attempt

              is_expected_app_process "$pid" "$app" || return 0
              /bin/kill -TERM "$pid" 2>/dev/null || true
              for attempt in {1..20}; do
                is_expected_app_process "$pid" "$app" || return 0
                /bin/sleep 0.1
              done
              /bin/kill -KILL "$pid" 2>/dev/null || true
            }

            stop_launched_app() {
              local pid

              if [[ -n "$launched_app_pid" ]]; then
                stop_app_process "$launched_app_pid" "$DEST"
              fi
              for pid in $(/usr/bin/pgrep -x "$EXEC" 2>/dev/null); do
                stop_app_process "$pid" "$DEST"
              done
              launched_app_pid=""
            }

            restart_and_confirm_app() {
              local app="$1"
              local launch_attempt wait_attempt pid

              for launch_attempt in {1..3}; do
                /usr/bin/open -n "$app" >/dev/null 2>&1 || /usr/bin/open "$app" >/dev/null 2>&1 || true
                for wait_attempt in {1..50}; do
                  for pid in $(/usr/bin/pgrep -x "$EXEC" 2>/dev/null); do
                    if is_expected_app_process "$pid" "$app"; then
                      /bin/sleep 0.5
                      is_expected_app_process "$pid" "$app" && return 0
                    fi
                  done
                  /bin/sleep 0.1
                done
              done
              return 1
            }

            restart_verified_current_app() {
              if validate_app "$DEST" "$CURRENT_VERSION"; then
                restart_and_confirm_app "$DEST" && return 0
              fi
              if validate_app "$LEGACY_DEST" "$CURRENT_VERSION"; then
                restart_and_confirm_app "$LEGACY_DEST" && return 0
              fi
              if [[ -n "$BACKUP" ]] && validate_app "$BACKUP" "$CURRENT_VERSION"; then
                restart_and_confirm_app "$BACKUP" && return 0
              fi
              if [[ -n "$CANDIDATE" ]] && validate_app "$CANDIDATE" "$CURRENT_VERSION"; then
                restart_and_confirm_app "$CANDIDATE" && return 0
              fi
              if [[ -n "$LEGACY_QUARANTINE" ]] && validate_app "$LEGACY_QUARANTINE" "$CURRENT_VERSION"; then
                restart_and_confirm_app "$LEGACY_QUARANTINE" && return 0
              fi
              return 1
            }

            acquire_transaction_lock() {
              lock_directory="/Applications/.Y-Clip-update.lock"
              [[ ! -e "$lock_directory" && ! -L "$lock_directory" ]] || return 1
              /bin/mkdir -m 700 "$lock_directory" || return 1
              lock_owned=1
            }

            begin_transaction_state_change() {
              (( transaction_state_change_active == 0 )) || return 1
              transaction_state_change_active=1
            }

            finish_transaction_state_change() {
              transaction_state_change_active=0
              if (( termination_pending == 1 )); then
                termination_pending=0
                handle_termination
              fi
              return 0
            }

            handle_termination() {
              if (( transaction_state_change_active == 1 )); then
                termination_pending=1
                return 0
              fi
              if (( parent_wait_active == 1 )); then
                parent_exit_authorized=0
                parent_wait_active=0
              fi
              exit 143
            }

            cleanup() {
              local exit_status=$?
              local rollback_complete=0
              local recovery_confirmed=0
              local cleanup_allowed=0
              trap - EXIT TERM INT HUP

              if (( exit_status == 0 && transaction_committed != 1 )); then
                exit_status=1
              fi

              if (( exit_status != 0 && parent_exit_authorized == 1 )); then
                while /bin/kill -0 "$APP_PID" 2>/dev/null; do
                  /bin/sleep 0.1
                done
                stop_launched_app
                if (( transaction_committed == 1 )); then
                  if validate_app "$DEST" "$EXPECTED_VERSION" && restart_and_confirm_app "$DEST"; then
                    recovery_confirmed=1
                  fi
                else
                  if rollback_installation; then
                    rollback_complete=1
                  fi
                  if restart_verified_current_app; then
                    recovery_confirmed=1
                  fi
                fi
              fi

              if (( exit_status == 0 && transaction_committed == 1 )); then
                cleanup_allowed=1
              elif (( parent_exit_authorized == 0 )); then
                cleanup_allowed=1
              elif (( transaction_committed == 1 && recovery_confirmed == 1 )); then
                cleanup_allowed=1
              elif (( rollback_complete == 1 && recovery_confirmed == 1 )); then
                cleanup_allowed=1
              fi

              if (( cleanup_allowed == 1 )); then
                /bin/rm -rf "$SOURCE_ROOT" || true
                /bin/rm -f "$DMG" "$0" || true
                if (( lock_owned == 1 )); then
                  /bin/rmdir "$lock_directory" >/dev/null 2>&1 || true
                  lock_owned=0
                fi
              else
                echo "Y-Clip update recovery is incomplete; preserving the transaction lock and all recovery copies." >&2
              fi
              exit "$exit_status"
            }
            trap cleanup EXIT
            trap handle_termination TERM INT HUP

            atomic_swap() {
              local first="$1"
              local second="$2"
              local helper="$SOURCE/Contents/MacOS/$EXEC"

              validate_app "$SOURCE" "$EXPECTED_VERSION" || return 1
              [[ -f "$helper" && ! -L "$helper" ]] || return 1
              "$helper" --transactional-update-swap "$first" "$second" || return 1
            }

            exclusive_rename() {
              local source="$1"
              local destination="$2"
              local helper="$SOURCE/Contents/MacOS/$EXEC"

              validate_app "$SOURCE" "$EXPECTED_VERSION" || return 1
              [[ -f "$helper" && ! -L "$helper" ]] || return 1
              "$helper" --transactional-update-rename-exclusive "$source" "$destination" || return 1
            }

            restore_legacy_quarantine() {
              if (( legacy_quarantined == 0 )); then
                return 0
              fi
              [[ -d "$LEGACY_QUARANTINE" && ! -L "$LEGACY_QUARANTINE" ]] || return 1
              [[ ! -e "$LEGACY_DEST" && ! -L "$LEGACY_DEST" ]] || return 1
              begin_transaction_state_change || return 1
              if ! exclusive_rename "$LEGACY_QUARANTINE" "$LEGACY_DEST"; then
                finish_transaction_state_change
                return 1
              fi
              legacy_quarantined=0
              if ! validate_identity "$LEGACY_DEST"; then
                finish_transaction_state_change
                return 1
              fi
              finish_transaction_state_change
            }

            rollback_primary_installation() {
              if (( primary_swapped == 1 )); then
                local old_primary
                if [[ -d "$BACKUP" && ! -L "$BACKUP" ]]; then
                  old_primary="$BACKUP"
                elif [[ -d "$CANDIDATE" && ! -L "$CANDIDATE" ]]; then
                  old_primary="$CANDIDATE"
                else
                  return 1
                fi
                begin_transaction_state_change || return 1
                if ! atomic_swap "$old_primary" "$DEST"; then
                  finish_transaction_state_change
                  return 1
                fi
                primary_swapped=0
                if [[ "$old_primary" == "$CANDIDATE" ]]; then
                  candidate_owned=1
                fi
                if ! validate_app "$DEST" "$CURRENT_VERSION"; then
                  finish_transaction_state_change
                  return 1
                fi
                if ! /bin/rm -rf "$old_primary"; then
                  finish_transaction_state_change
                  return 1
                fi
                if [[ -e "$old_primary" || -L "$old_primary" ]]; then
                  finish_transaction_state_change
                  return 1
                fi
                candidate_owned=0
                finish_transaction_state_change
                return 0
              fi

              if (( new_primary_created == 1 )); then
                if (( legacy_present == 1 )) && validate_app "$LEGACY_DEST" "$CURRENT_VERSION"; then
                  [[ ! -e "$CANDIDATE" && ! -L "$CANDIDATE" ]] || return 1
                  begin_transaction_state_change || return 1
                  if ! exclusive_rename "$DEST" "$CANDIDATE"; then
                    finish_transaction_state_change
                    return 1
                  fi
                  candidate_owned=1
                  new_primary_created=0
                  if ! /bin/rm -rf "$CANDIDATE"; then
                    finish_transaction_state_change
                    return 1
                  fi
                  if [[ -e "$CANDIDATE" || -L "$CANDIDATE" ]]; then
                    finish_transaction_state_change
                    return 1
                  fi
                  candidate_owned=0
                  finish_transaction_state_change
                  return 0
                fi
                return 1
              fi
              return 0
            }

            rollback_installation() {
              local rollback_status=0
              restore_legacy_quarantine || rollback_status=1
              rollback_primary_installation || rollback_status=1
              if (( candidate_owned == 1 )); then
                if validate_app "$CANDIDATE" "$EXPECTED_VERSION"; then
                  /bin/rm -rf "$CANDIDATE" || true
                  candidate_owned=0
                elif validate_app "$CANDIDATE" "$CURRENT_VERSION"; then
                  rollback_status=1
                elif (( primary_swapped == 0 && new_primary_created == 0 )) &&
                     validate_app "$DEST" "$CURRENT_VERSION"; then
                  /bin/rm -rf "$CANDIDATE" || true
                  candidate_owned=0
                else
                  rollback_status=1
                fi
              fi
              return "$rollback_status"
            }

            launch_updated_app_and_wait() {
              local launch_uuid attempt phase reported_token reported_pid extra

              launch_uuid="$(/usr/bin/uuidgen)" || return 1
              launch_token="$(/usr/bin/uuidgen)" || return 1
              launch_state_directory="$SOURCE_ROOT/.Y-Clip-launch-$launch_uuid"
              launch_state_file="$launch_state_directory/state"
              [[ ! -e "$launch_state_directory" && ! -L "$launch_state_directory" ]] || return 1
              /bin/mkdir -m 700 "$launch_state_directory" || return 1
              [[ ! -e "$launch_state_file" && ! -L "$launch_state_file" ]] || return 1

              if ! /usr/bin/open -n "$DEST" --args \
                --y-clip-update-launch-token "$launch_token" \
                --y-clip-update-launch-state "$launch_state_file" >/dev/null 2>&1; then
                if ! /usr/bin/open "$DEST" --args \
                  --y-clip-update-launch-token "$launch_token" \
                  --y-clip-update-launch-state "$launch_state_file" >/dev/null 2>&1; then
                  return 1
                fi
              fi

              for attempt in {1..300}; do
                if [[ -f "$launch_state_file" && ! -L "$launch_state_file" ]]; then
                  phase=""
                  reported_token=""
                  reported_pid=""
                  extra=""
                  IFS=' ' read -r phase reported_token reported_pid extra < "$launch_state_file" || return 1
                  [[ -z "$extra" ]] || return 1
                  [[ "$reported_token" == "$launch_token" ]] || return 1
                  [[ "$reported_pid" == <-> ]] || return 1
                  launched_app_pid="$reported_pid"
                  is_expected_app_process "$launched_app_pid" "$DEST" || return 1
                  if [[ "$phase" == "READY" ]]; then
                    /bin/sleep 1
                    is_expected_app_process "$launched_app_pid" "$DEST" || return 1
                    return 0
                  fi
                  [[ "$phase" == "STARTING" ]] || return 1
                fi
                /bin/sleep 0.1
              done
              return 1
            }

            perform_transactional_install() {
              local update_uuid
              update_uuid="$(/usr/bin/uuidgen)" || return 1
              CANDIDATE="/Applications/.Y-Clip-update-$update_uuid.app"
              BACKUP="/Applications/.Y-Clip-backup-$update_uuid.app"
              LEGACY_QUARANTINE="/Applications/.Global-Clipboard-remove-$update_uuid.app"

              [[ ! -e "$CANDIDATE" && ! -L "$CANDIDATE" ]] || return 1
              [[ ! -e "$BACKUP" && ! -L "$BACKUP" ]] || return 1
              [[ ! -e "$LEGACY_QUARANTINE" && ! -L "$LEGACY_QUARANTINE" ]] || return 1

              if [[ -e "$DEST" || -L "$DEST" ]]; then
                validate_app "$DEST" "$CURRENT_VERSION" || return 1
                primary_existed=1
              fi
              if [[ -e "$LEGACY_DEST" || -L "$LEGACY_DEST" ]]; then
                validate_identity "$LEGACY_DEST" || return 1
                legacy_present=1
              fi
              if [[ "$CURRENT_APP" == "$DEST" ]]; then
                (( primary_existed == 1 )) || return 1
              elif [[ "$CURRENT_APP" == "$LEGACY_DEST" ]]; then
                (( legacy_present == 1 )) || return 1
                validate_app "$LEGACY_DEST" "$CURRENT_VERSION" || return 1
              else
                return 1
              fi

              candidate_owned=1
              if ! /usr/bin/ditto "$SOURCE" "$CANDIDATE"; then
                return 1
              fi
              validate_app "$CANDIDATE" "$EXPECTED_VERSION" || return 1

              if (( primary_existed == 1 )); then
                begin_transaction_state_change || return 1
                if ! atomic_swap "$CANDIDATE" "$DEST"; then
                  finish_transaction_state_change
                  return 1
                fi
                primary_swapped=1
                candidate_owned=0
                finish_transaction_state_change
                validate_app "$CANDIDATE" "$CURRENT_VERSION" || return 1
                exclusive_rename "$CANDIDATE" "$BACKUP" || return 1
              else
                begin_transaction_state_change || return 1
                if ! exclusive_rename "$CANDIDATE" "$DEST"; then
                  finish_transaction_state_change
                  return 1
                fi
                candidate_owned=0
                new_primary_created=1
                finish_transaction_state_change
              fi
              validate_app "$DEST" "$EXPECTED_VERSION" || return 1

              if (( legacy_present == 1 )); then
                begin_transaction_state_change || return 1
                if ! exclusive_rename "$LEGACY_DEST" "$LEGACY_QUARANTINE"; then
                  finish_transaction_state_change
                  return 1
                fi
                legacy_quarantined=1
                finish_transaction_state_change
                validate_identity "$LEGACY_QUARANTINE" || return 1
              fi

              validate_app "$DEST" "$EXPECTED_VERSION" || return 1
              [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
              /usr/bin/touch "$DEST" || true
              if ! launch_updated_app_and_wait; then
                stop_launched_app
                return 1
              fi

              transaction_committed=1
              primary_swapped=0
              new_primary_created=0
              legacy_quarantined=0
              /bin/rm -rf "$BACKUP" || true
              /bin/rm -rf "$LEGACY_QUARANTINE" || true
              return 0
            }

            validate_app "$SOURCE" "$EXPECTED_VERSION" || exit 1
            if [[ "$CURRENT_APP" == "$DEST" ]]; then
              validate_app "$DEST" "$CURRENT_VERSION" || exit 1
            elif [[ "$CURRENT_APP" == "$LEGACY_DEST" ]]; then
              validate_app "$LEGACY_DEST" "$CURRENT_VERSION" || exit 1
            else
              exit 1
            fi
            if [[ "$LEGACY_DEST" != "$CURRENT_APP" && ( -e "$LEGACY_DEST" || -L "$LEGACY_DEST" ) ]]; then
              if ! validate_identity "$LEGACY_DEST"; then
                echo "拒绝删除身份不明的 $LEGACY_DEST；现有 Y-Clip 保持不变。" >&2
                exit 1
              fi
            fi
            acquire_transaction_lock || exit 1

            parent_wait_active=1
            parent_exit_authorized=1
            if ! /usr/bin/printf 'READY\n'; then
              parent_exit_authorized=0
              parent_wait_active=0
              exit 1
            fi
            if ! exec 1>&-; then
              parent_exit_authorized=0
              parent_wait_active=0
              exit 1
            fi
            while /bin/kill -0 "$APP_PID" 2>/dev/null; do
              /bin/sleep 0.1
            done
            parent_wait_active=0

            if ! perform_transactional_install; then
              if ! rollback_installation; then
                echo "Y-Clip 更新失败；无法完整回滚，已保留所有可验证副本。" >&2
              fi
              exit 1
            fi
            (( transaction_committed == 1 )) || exit 1
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let process = Process()
            let readinessPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-f",
                scriptURL.path,
                dmgURL.path,
                validatedApplicationURL.path,
                expectedVersion,
                currentVersion,
                runningApplicationURL.path,
                "\(ProcessInfo.processInfo.processIdentifier)"
            ]
            process.standardOutput = readinessPipe
            process.standardError = FileHandle.nullDevice
            try process.run()

            try waitForInstallerReadiness(
                from: readinessPipe,
                process: process,
                timeout: 60
            )
            NSApp.terminate(nil)
        } catch {
            if let preparedApplicationURL {
                try? FileManager.default.removeItem(at: preparedApplicationURL.deletingLastPathComponent())
            }
            try? FileManager.default.removeItem(at: dmgURL)
            onStatusChange?(.failed(error.localizedDescription))
        }
    }

    private func waitForInstallerReadiness(
        from pipe: Pipe,
        process: Process,
        timeout: TimeInterval
    ) throws {
        let expectedData = Data("READY\n".utf8)
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start > UInt64.max - timeoutNanoseconds
            ? UInt64.max
            : start + timeoutNanoseconds
        let fileDescriptor = pipe.fileHandleForReading.fileDescriptor
        var receivedData = Data()

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                stopInstallerProcess(process)
                throw installerReadinessError()
            }

            let remainingNanoseconds = deadline - now
            let remainingMilliseconds = min(
                UInt64(Int32.max),
                (remainingNanoseconds + 999_999) / 1_000_000
            )
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Int32(remainingMilliseconds)
            )
            if pollResult < 0 && errno == EINTR {
                continue
            }
            guard
                pollResult > 0,
                descriptor.revents & Int16(POLLNVAL | POLLERR) == 0,
                descriptor.revents & Int16(POLLIN | POLLHUP) != 0
            else {
                stopInstallerProcess(process)
                throw installerReadinessError()
            }

            var buffer = [UInt8](
                repeating: 0,
                count: expectedData.count + 1 - receivedData.count
            )
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 && errno == EINTR {
                continue
            }
            guard bytesRead >= 0 else {
                stopInstallerProcess(process)
                throw installerReadinessError()
            }
            if bytesRead == 0 {
                break
            }
            receivedData.append(contentsOf: buffer.prefix(bytesRead))
            guard receivedData.count <= expectedData.count else {
                stopInstallerProcess(process)
                throw installerReadinessError()
            }
        }

        guard receivedData == expectedData else {
            stopInstallerProcess(process)
            throw installerReadinessError()
        }
    }

    private func stopInstallerProcess(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        process.terminate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func installerReadinessError() -> UpdateValidationError {
        UpdateValidationError(
            message: "更新安装器未通过替换前安全检查。现有 App 保持运行。"
        )
    }

    private func prepareIncomingApplication(
        from dmgURL: URL,
        expectedVersion: String,
        currentVersion: String
    ) throws -> URL {
        guard SoftwareUpdateAssetSelector.isVersion(expectedVersion, newerThan: currentVersion) else {
            throw UpdateValidationError(message: "更新版本不高于当前版本，已停止安装。")
        }
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

            try verifyIncomingApplicationVersion(
                at: incomingApplicationURL,
                expectedVersion: expectedVersion
            )
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
            try verifyIncomingApplicationVersion(
                at: preparedApplicationURL,
                expectedVersion: expectedVersion
            )
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

    private func verifyIncomingApplicationVersion(
        at applicationURL: URL,
        expectedVersion: String
    ) throws {
        let infoPlistURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        let infoPlistData: Data
        do {
            infoPlistData = try Data(contentsOf: infoPlistURL)
        } catch {
            throw UpdateValidationError(message: "无法读取更新 App 的版本信息。")
        }

        guard
            let infoDictionary = try? PropertyListSerialization.propertyList(
                from: infoPlistData,
                options: [],
                format: nil
            ) as? [String: Any],
            let actualVersion = infoDictionary["CFBundleShortVersionString"] as? String,
            SoftwareUpdateAssetSelector.isExpectedApplicationVersion(
                actualVersion: actualVersion,
                expectedVersion: expectedVersion
            )
        else {
            throw UpdateValidationError(
                message: "更新 App 的内部版本与 GitHub Release 不一致，已停止安装。"
            )
        }
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

}
