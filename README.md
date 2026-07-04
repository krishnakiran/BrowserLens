# BrowserLens

BrowserLens is a local-first macOS menu bar app for fast recall across Safari and Chrome history and bookmarks.

The product thesis is narrow by design: BrowserLens indexes browser memory only, keeps it local, deduplicates URLs, and presents a fast Apple-style search surface with source, type, date, and session context.

## Current MVP

- Swift package with a native macOS executable target.
- AppKit menu bar shell with a SwiftUI search window.
- Core models for browser items, canonical URLs, and activity sessions.
- URL canonicalization for dedupe.
- Session grouping for the Memory Map Architecture.
- Persistent local SQLite database in Application Support.
- FTS5-backed local search.
- Safari and Chrome importers for local history/bookmarks.
- Chrome profile discovery for normal local profiles.
- Background import scheduler that runs on launch and refreshes every minute while the app is running.
- Date, browser, and history/bookmark filters.
- Click or press Enter to open a result in the default browser.
- Cmd+C copies the selected result URL.
- Esc closes the search window.
- Cmd+Shift+B toggles BrowserLens while the app is running.
- Reindex, pause/resume indexing, clear index, and reveal local DB controls.
- Self-test executable covering canonicalization, session grouping, importer fixtures, and persistent index behavior.

## Run

```bash
swift run BrowserLens
```

The local database is stored at:

```text
~/Library/Application Support/BrowserLens/BrowserLens.sqlite
```

## Browser Data Permissions

Safari history/bookmarks and some Chrome profile files are protected by macOS privacy controls.

If you launch with `swift run BrowserLens`, grant **Full Disk Access** to your terminal app.

If you launch `.build/BrowserLens.app`, grant **Full Disk Access** to `BrowserLens.app`.

Path:

```text
System Settings -> Privacy & Security -> Full Disk Access
```

After granting access, restart BrowserLens and click **Reindex Now**.

## Package App

```bash
./scripts/package-app.sh
open .build/BrowserLens.app
```

## Test

```bash
swift run BrowserLensSelfTest
```

## Design

The approved office-hours design is in [docs/design.md](docs/design.md).
