# Recent Files for macOS

A native macOS utility built with SwiftUI and AppKit. It watches the top level of configured folders (Downloads and Desktop by default), shows files modified or created within the selected time period, and provides search, Finder reveal, copy path, appearance, login item, and global shortcut settings.

## Build

Open `macos/RecentFiles.xcodeproj` in Xcode and build the `RecentFiles` scheme, or run:

```sh
xcodebuild -project macos/RecentFiles.xcodeproj -scheme RecentFiles -configuration Release -destination 'platform=macOS' build
```

## Install

Download the latest `Recent Files-macOS.dmg` from GitHub Releases, open the disk image, and drag `Recent Files.app` to Applications. This release is ad-hoc signed and is not notarized; macOS may require opening it from Finder's context menu the first time.

The deployment target remains macOS 12.0. The launch-at-login option uses `SMAppService` and is available on macOS 13 and later.

The global shortcut uses a local macOS event tap so another app cannot respond to the same selected combination. macOS requires the user to grant Recent Files Accessibility access for this feature; the app only handles key codes and modifier flags, and does not record or transmit typed text. The supplied light and dark logos are bundled separately: the main view and running Dock icon follow the app's selected theme.

Existing preferences are read from the prior app's `com.example.recentFiles1` UserDefaults domain. Folder paths, theme, and keyboard shortcut are retained; recent file entries are rebuilt from the watched folders as before.
