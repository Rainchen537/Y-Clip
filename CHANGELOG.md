# Changelog

All notable Y-Clip release changes are tracked here.

## v1.0.19 - 2026-07-22

- Bound the expected GitHub Release version to download and installation, rejecting malformed, same-version, downgrade, or renamed older App bundles.
- Added exact internal-version checks to the mounted App, prepared copy, same-volume candidate, and final destination alongside existing identity, Developer ID, hardened runtime, code-signing, Gatekeeper, and strict thin-architecture validation.
- Replaced direct replacement with candidate + backup atomic renames and rollback when copy, placement, final validation, or later legacy-cleanup checks fail.
- Protected the hidden legacy `Global Clipboard.app` path: unknown identities and symlinks are preserved, while a verified legacy copy is first moved to a private quarantine path and revalidated before removal.
- Added a fixed update-transaction lock and a bounded, shell-environment-independent installer readiness channel that requires `READY\n` followed by EOF, so concurrent updates, startup-output pollution, trailing bytes, cancellation, or a stalled installer fail without replacing the running App.
- The replacement is committed only after the newly installed App finishes its AppKit launch, reports a one-time token and exact process identity, and remains alive; failed launches restart only a verified previous version, while an incomplete rollback preserves the transaction lock and every recovery copy.
- Hardened the dual-architecture release source fingerprint so Git enumeration, raw symlink-target bytes (including trailing newlines), unusual filenames, manifest writes, and hashes fail closed, tracked working-tree deletions use a stable marker, repository-local vendored frameworks are mandatory, and source changes are checked immediately before artifact replacement and again before success.

## v1.0.18 - 2026-07-22

- Added separate Apple Silicon and Intel release artifacts named `Y-Clip-v1.0.18-arm64.dmg` and `Y-Clip-v1.0.18-x86_64.dmg`, with isolated thin builds and architecture verification throughout the signing and mounted-DMG checks.
- Updated automatic updates to select only the exact asset for the app's compiled architecture and to open the GitHub Release page instead of downloading an unrelated DMG when that asset is missing.
- Added defense-in-depth checks that reject mismatched or universal update executables before the existing app can be replaced.
- Added repeatable asset-selection and thin-architecture tests covering asset ordering, unrelated DMGs, missing architecture packages, mismatches, and universal binaries.
- Independently signed, notarized, stapled, Gatekeeper-checked, and mounted both architecture-specific DMGs before release.

## v1.0.17 - 2026-07-21

- Added a pin button to the clipboard history panel so it can remain above normal windows and be dragged like a regular floating panel.
- Added an independently configurable pinned-panel hotkey, defaulting to `Option+Shift+Command+V`, while the regular hotkey continues to open a temporary panel near the current caret or pointer.
- Remembered the pinned panel position, kept it visible after choosing history, and refreshed its rows live when clipboard history changes.
- Restored focus to the frontmost app before pinned-panel paste events, so the floating panel stays visible without intercepting the generated `Command+V`.
- Suspended both global hotkeys while recording a shortcut so conflicts can be detected and rolled back correctly.

## v1.0.16 - 2026-07-20

- Rebuilt the drag-to-install DMG with a light high-contrast Retina background so Finder's app labels remain readable in both light and dark system appearances.
- Removed visible `.background` and `.fseventsd` items from the final image, hid Finder's toolbar, status bar, path bar, and tab bar, and aligned the installation arrow from the saved App and Applications icon coordinates.
- Preserved the root-level `Global Clipboard.app` updater compatibility copy on APFS with a BSD hidden flag instead of an extra `.hidden` manifest, and saved its Finder icon outside the installation window so it cannot cover the layout when hidden files are shown.

## v1.0.15 - 2026-07-19

- Unified first-launch and later Accessibility guidance through the shared Y-Project permission prompt framework, including signed installed-copy checks, state-based duplicate suppression, and the existing app-scoped repair flow.
- Replaced the project-specific DMG layout code with the shared Y-Project DMG framework, which generates the correct product title, validates the saved Finder background and icon layout, and preserves the hidden `Global Clipboard.app` compatibility copy.
- Relaunches now use LaunchServices without forcing a second app instance.

## v1.0.14 - 2026-07-18

- Kept the Features preview visible while selected, restored it when reopening Settings, and preserved user-chosen window frames while adapting the settings/preview pair to narrow screens.
- Refreshed Accessibility status when returning from System Settings and moved permission-record resets off the main thread while keeping persisted trust state consistent.
- Added runtime diagnostics that distinguish the verified signed `/Applications` copy from development copies and can switch directly to the installed app.
- Scoped Accessibility TCC refreshes to Y-Clip's bundle identifier; repairs started from a development copy now continue authorization only in a validated formal install.
- Validated downloaded updates against Y-Clip's Bundle ID, Developer ID team, hardened runtime, code signature, and Gatekeeper before replacing the installed app.
- Constrained settings windows to the active display and added product identity to About.

## v1.0.13 - 2026-06-28

- Reworked settings from the menu bar popover into an independent settings window with a sidebar and unified Y-Project visual language.
- Simplified the menu bar item to open settings, reserve a More Y-Project entry, and quit the app.
- Kept clipboard panel sizing controls with a side preview beside the settings window.
- Vendored the shared Y-Project settings framework so the repository can be built independently from GitHub source checkouts.

## v1.0.12 - 2026-06-24

- Renamed the user-facing app to Y-Clip while preserving the original bundle identifier, executable name, data directory, and update compatibility.
- Fixed clipboard history sometimes reopening with a blank area above the first item after new clipboard content.
- Updated the history list layout so resetting to the top is more reliable.
- Kept a hidden legacy app copy in the DMG for older auto-updaters.
