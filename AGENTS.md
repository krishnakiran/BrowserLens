# Repository Guidelines

## Project Structure & Module Organization

BrowserLens is a Swift Package Manager project for a local-first macOS menu bar app. Core indexing, import, database, URL, session, and search logic lives in `Sources/BrowserLensCore/`. The app entry point and AppKit/SwiftUI shell live in `Sources/BrowserLensApp/`. The executable self-test target is in `Tools/BrowserLensSelfTest/`. `Tests/BrowserLensCoreTests/` exists for future XCTest coverage, but current verification is driven by the self-test executable. Design notes are in `docs/design.md`, and release packaging helpers are in `scripts/`.

## Build, Test, and Development Commands

- `swift build` builds all package targets in debug mode.
- `swift run BrowserLens` launches the menu bar app locally.
- `swift run BrowserLensSelfTest` runs the current regression suite for canonicalization, session grouping, import fixtures, and persistent SQLite indexing.
- `swift build --configuration release --product BrowserLens` builds the release executable.
- `./scripts/package-app.sh` creates `.build/BrowserLens.app`; use `open .build/BrowserLens.app` to launch the packaged app.

Browser history and bookmark imports may require Full Disk Access for Terminal or `BrowserLens.app`.

## Coding Style & Naming Conventions

Use Swift 5.9 conventions with 4-space indentation, explicit access control for public APIs, and clear value types where possible. Follow existing names: types use `UpperCamelCase` (`BrowserItem`, `URLCanonicalizer`), functions and properties use `lowerCamelCase`, and enum cases stay lowercase (`.safari`, `.chrome`). Prefer small files grouped by domain in `BrowserLensCore`, and keep app UI code out of core indexing/import logic. Avoid broad refactors unless they directly support the change.

## Testing Guidelines

Run `swift run BrowserLensSelfTest` before submitting changes. Add new checks there when changing importer behavior, URL canonicalization, session logic, or SQLite persistence. If adding XCTest coverage, place tests under `Tests/BrowserLensCoreTests/` and name files after the unit under test, such as `URLCanonicalizerTests.swift`.

## Commit & Pull Request Guidelines

This repository currently has no commit history, so no established message convention exists. Use short imperative commits, for example `Add Safari bookmark fixture` or `Fix FTS date filtering`. Pull requests should include a summary, testing performed, and screenshots or screen recordings for visible macOS UI changes. Link related issues when available, and call out any privacy or Full Disk Access implications.

## Security & Configuration Tips

Keep BrowserLens local-first. Do not add network sync, telemetry, or external services without explicit product approval. Treat browser history, bookmarks, and the SQLite database in `~/Library/Application Support/BrowserLens/BrowserLens.sqlite` as sensitive local data.
