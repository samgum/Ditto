# Ditto for macOS

This directory contains the macOS target for the Ditto repository. The Windows
application remains under the existing Visual Studio solution; this target is a
native AppKit application that can be built and packaged from the same
repository on a macOS runner.

## Current scope

The first macOS target is intentionally small:

- menu bar application
- polling-based `NSPasteboard` text capture
- image clipboard capture and image restore to the pasteboard
- multi-format entries that can store text, RTF, HTML, PNG, and file URLs
- local history stored under `~/Library/Application Support/Ditto/history.json`
- history window
- search in the history window
- recent items in the menu bar menu
- favorites and group filtering in the history window
- global Option+Command+V shortcut to show history
- configurable global hot key from Preferences
- English, Simplified Chinese, and Traditional Chinese language packs
- copy selected history item back to the pasteboard
- paste selected history item back into the previous application
- delete selected history item and clear all history
- import and export a self-contained Ditto macOS history archive as JSON
- import Windows Ditto SQLite databases (`Ditto.db`) and Ditto SQLite export
  files into the macOS history
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

The CI package is ad-hoc signed so the app bundle has a valid local code
signature. It is not yet notarized with an Apple Developer ID certificate, so a
downloaded build can still require right-click Open or explicit approval in
System Settings > Privacy & Security.

On launch, Ditto writes this user LaunchAgent:

```text
~/Library/LaunchAgents/org.ditto-cp.Ditto.plist
```

The agent uses `RunAtLoad` and `KeepAlive`, so Ditto starts on login and is
restarted by launchd after unexpected exits. Choosing `Quit Ditto` from the menu
bar item removes the LaunchAgent before terminating the app.

Automatic paste uses a synthesized Command+V key event after restoring focus to
the previous application. macOS may require enabling Ditto in System Settings >
Privacy & Security > Accessibility before this works.

History import/export uses a macOS-specific JSON archive. RTF, HTML, and image
payloads are embedded as base64 so the archive can be moved between Macs.

Windows Ditto database migration is available from the menu bar item through
`Import Windows Ditto Database...`. It reads the original `Main` and `Data`
SQLite tables from `Ditto.db`, plus Ditto SQLite export files that store
compressed `lOriginalSize` payloads. The importer maps `CF_UNICODETEXT`,
`CF_TEXT`, `Rich Text Format`, `HTML Format`, `PNG`, `CF_DIB`, and `CF_HDROP`
into the macOS history. Windows-only clipboard formats are skipped because
macOS cannot paste those native Win32 payloads directly.

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
