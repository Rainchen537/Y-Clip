# Changelog

All notable Y-Clip release changes are tracked here.

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
