# Ditto for macOS

This directory contains the macOS target for the Ditto repository. The Windows
application remains under the existing Visual Studio solution; this target is a
native AppKit application that can be built and packaged from the same
repository on a macOS runner.

## Current scope

The first macOS target is intentionally small:

- menu bar application
- polling-based `NSPasteboard` text capture
- local history stored under `~/Library/Application Support/Ditto/history.json`
- history window
- copy selected history item back to the pasteboard
- login auto-start through a user LaunchAgent
- LaunchAgent `KeepAlive` restart after crashes or unexpected exits
- `.app` and `.dmg` packaging script

The existing Windows project is MFC/Win32-heavy, so the macOS target does not
attempt to compile the Windows UI or clipboard integration. Shared behavior
should be extracted gradually after the macOS target is buildable.

## Build on macOS

```bash
swift build --package-path platform/macos -c release
```

## Run on macOS

```bash
swift run --package-path platform/macos DittoMac
```

## Package on macOS

```bash
bash platform/macos/scripts/package-dmg.sh
```

The generated package is written to:

```text
platform/macos/dist/Ditto-macOS.dmg
```

The DMG contains `Ditto.app` and an `/Applications` shortcut. For a stable login
item path, drag `Ditto.app` into `/Applications` before launching it.

On launch, Ditto writes this user LaunchAgent:

```text
~/Library/LaunchAgents/org.ditto-cp.Ditto.plist
```

The agent uses `RunAtLoad` and `KeepAlive`, so Ditto starts on login and is
restarted by launchd after unexpected exits. Choosing `Quit Ditto` from the menu
bar item removes the LaunchAgent before terminating the app.

## Migration direction

Keep platform code separated:

- `src`, `CP_Main_10.sln`, and `DittoSetup` remain the Windows target.
- `platform/macos` remains the macOS target.
- Shared logic should move into a future `core` library only when it has no MFC,
  Win32, AppKit, or Cocoa dependencies.

Good candidates for future shared extraction are clip metadata, search ranking,
dedupe rules, import/export format decisions, and database schema migration
rules. Bad candidates are window code, tray/menu-bar code, clipboard listeners,
hotkeys, paste simulation, and OS permission handling.
