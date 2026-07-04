import BrowserLensCore
import Foundation

let tempRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("BrowserLensSelfTest-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempRoot) }

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Self-test failed: \(message)\n", stderr)
        exit(1)
    }
}

let canonicalizer = URLCanonicalizer()
let trackedURL = URL(string: "HTTPS://Example.com/docs/?utm_source=newsletter&b=2&a=1#section")!
let trackedCanonical = canonicalizer.canonicalString(for: trackedURL)
require(
    trackedCanonical == "https://example.com/docs?a=1&b=2",
    "canonical URL should strip tracking params, sort query items, and drop fragments; got \(trackedCanonical)"
)

let appleURL = URL(string: "https://www.apple.com/safari/")!
require(canonicalizer.domain(for: appleURL) == "apple.com", "domain should drop www prefix")

let base = Date(timeIntervalSince1970: 1_000)
let closeVisits = [
    visit(domain: "sqlite.org", at: base),
    visit(domain: "developer.apple.com", at: base.addingTimeInterval(60)),
    visit(domain: "sqlite.org", at: base.addingTimeInterval(120))
]
let closeSessions = Sessionizer(inactivityGap: 300).group(closeVisits)
require(closeSessions.count == 1, "close visits should group into one session")
require(closeSessions[0].visits.count == 3, "session should contain all close visits")
require(closeSessions[0].primaryDomain == "sqlite.org", "primary domain should use most common domain")

let distantVisits = [
    visit(domain: "sqlite.org", at: base),
    visit(domain: "apple.com", at: base.addingTimeInterval(3_600))
]
let distantSessions = Sessionizer(inactivityGap: 300).group(distantVisits)
require(distantSessions.count == 2, "distant visits should split across sessions")

verifyDateFilterPresets()
try await verifyChromeImporter(in: tempRoot)
try verifyChromeProfileDiscovery(in: tempRoot)
try await verifySafariImporter(in: tempRoot)
await verifyPersistentIndex(in: tempRoot)
await verifySchemaMigration(in: tempRoot)
await verifyFilteredSearchAppliesBeforeLimit(in: tempRoot)

print("BrowserLens self-test passed")

func visit(domain: String, at date: Date) -> BrowserVisit {
    BrowserVisit(
        title: domain,
        url: URL(string: "https://\(domain)")!,
        canonicalURL: "https://\(domain)",
        domain: domain,
        source: .safari,
        kind: .history,
        visitedAt: date
    )
}

func verifyDateFilterPresets() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 1

    let now = calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 4,
        hour: 15,
        minute: 30
    ))!
    let todayMorning = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 7, day: 4, hour: 9))!
    let yesterdayNoon = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 7, day: 3, hour: 12))!
    let lastWeek = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 6, day: 29, hour: 12))!
    let lastMonth = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 6, day: 1, hour: 12))!

    require(DateFilterPreset.all.dateRange(now: now, calendar: calendar) == nil, "all date preset should not constrain results")
    require(DateFilterPreset.today.dateRange(now: now, calendar: calendar)!.contains(todayMorning), "today preset should include same-day visits")
    require(!DateFilterPreset.today.dateRange(now: now, calendar: calendar)!.contains(yesterdayNoon), "today preset should exclude yesterday")
    require(DateFilterPreset.yesterday.dateRange(now: now, calendar: calendar)!.contains(yesterdayNoon), "yesterday preset should include previous-day visits")
    require(DateFilterPreset.thisWeek.dateRange(now: now, calendar: calendar)!.contains(lastWeek), "this week preset should include current calendar week")
    require(DateFilterPreset.olderThan30Days.dateRange(now: now, calendar: calendar)!.contains(lastMonth), "older-than preset should include dates before cutoff")
    require(!DateFilterPreset.olderThan30Days.dateRange(now: now, calendar: calendar)!.contains(todayMorning), "older-than preset should exclude recent visits")
}

func verifyChromeImporter(in root: URL) async throws {
    let profile = root.appendingPathComponent("ChromeProfile", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    let history = profile.appendingPathComponent("History")
    try runSQLite(history, sql: """
    CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT,url LONGVARCHAR,title LONGVARCHAR,visit_count INTEGER DEFAULT 0 NOT NULL,typed_count INTEGER DEFAULT 0 NOT NULL,last_visit_time INTEGER NOT NULL,hidden INTEGER DEFAULT 0 NOT NULL);
    CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT,url INTEGER NOT NULL,visit_time INTEGER NOT NULL,from_visit INTEGER,transition INTEGER DEFAULT 0 NOT NULL,segment_id INTEGER,visit_duration INTEGER DEFAULT 0 NOT NULL,incremented_omnibox_typed_score BOOLEAN DEFAULT FALSE NOT NULL);
    INSERT INTO urls(id,url,title,visit_count,typed_count,last_visit_time,hidden) VALUES(1,'https://example.com/docs?utm_source=test&q=swift','Example Docs',2,0,13380163200000000,0);
    INSERT INTO visits(url,visit_time) VALUES(1,13380163200000000);
    """)

    let bookmarks = [
        "roots": [
            "bookmark_bar": [
                "type": "folder",
                "children": [
                    [
                        "type": "url",
                        "name": "Apple Safari",
                        "url": "https://www.apple.com/safari/",
                        "date_added": "13380163200000000"
                    ]
                ]
            ]
        ]
    ]
    let bookmarkData = try JSONSerialization.data(withJSONObject: bookmarks, options: [.prettyPrinted])
    try bookmarkData.write(to: profile.appendingPathComponent("Bookmarks"))

    let visits = try await ChromeImporter(profileDirectory: profile, maxHistoryItems: 10).importVisits()
    require(visits.count == 2, "Chrome importer should parse one history item and one bookmark")
    require(visits.contains { $0.kind.contains(.history) && $0.canonicalURL == "https://example.com/docs?q=swift" }, "Chrome history should canonicalize URL")
    require(visits.contains { $0.kind.contains(.bookmark) && $0.domain == "apple.com" }, "Chrome bookmarks should parse nested bookmark URLs")
}

func verifyChromeProfileDiscovery(in root: URL) throws {
    let chromeRoot = root.appendingPathComponent("Chrome", isDirectory: true)
    let defaultProfile = chromeRoot.appendingPathComponent("Default", isDirectory: true)
    let workProfile = chromeRoot.appendingPathComponent("Profile 1", isDirectory: true)
    let guestProfile = chromeRoot.appendingPathComponent("Guest Profile", isDirectory: true)
    let systemProfile = chromeRoot.appendingPathComponent("System Profile", isDirectory: true)

    for profile in [defaultProfile, workProfile, guestProfile, systemProfile] {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    }
    FileManager.default.createFile(atPath: defaultProfile.appendingPathComponent("History").path, contents: Data())
    FileManager.default.createFile(atPath: workProfile.appendingPathComponent("Bookmarks").path, contents: Data())
    FileManager.default.createFile(atPath: guestProfile.appendingPathComponent("History").path, contents: Data())
    FileManager.default.createFile(atPath: systemProfile.appendingPathComponent("History").path, contents: Data())

    let importers = ChromeImporter.discoverProfiles(chromeDirectory: chromeRoot, maxHistoryItems: 99)
    let names = importers.map { $0.profileDirectory.lastPathComponent }

    require(names == ["Default", "Profile 1"], "Chrome discovery should include all real profiles and skip guest/system profiles; got \(names)")
    require(importers.allSatisfy { $0.maxHistoryItems == 99 }, "Chrome discovery should pass max history item limit to every profile importer")
}

func verifySafariImporter(in root: URL) async throws {
    let library = root.appendingPathComponent("Safari", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let history = library.appendingPathComponent("History.db")
    try runSQLite(history, sql: """
    CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT,url TEXT NOT NULL UNIQUE,domain_expansion TEXT NULL,visit_count INTEGER NOT NULL,daily_visit_counts BLOB NOT NULL,weekly_visit_counts BLOB NULL,autocomplete_triggers BLOB NULL,should_recompute_derived_visit_counts INTEGER NOT NULL,visit_count_score INTEGER NOT NULL, status_code INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT,history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,visit_time REAL NOT NULL,title TEXT NULL,load_successful BOOLEAN NOT NULL DEFAULT 1,http_non_get BOOLEAN NOT NULL DEFAULT 0,synthesized BOOLEAN NOT NULL DEFAULT 0,redirect_source INTEGER NULL UNIQUE REFERENCES history_visits(id) ON DELETE CASCADE,redirect_destination INTEGER NULL UNIQUE REFERENCES history_visits(id) ON DELETE CASCADE,origin INTEGER NOT NULL DEFAULT 0,generation INTEGER NOT NULL DEFAULT 0,attributes INTEGER NOT NULL DEFAULT 0,score INTEGER NOT NULL DEFAULT 0);
    INSERT INTO history_items(id,url,visit_count,daily_visit_counts,should_recompute_derived_visit_counts,visit_count_score,status_code) VALUES(1,'https://sqlite.org/docs/?utm_medium=email',1,X'',0,0,0);
    INSERT INTO history_visits(history_item,visit_time,title,load_successful) VALUES(1,804815119.0,'SQLite Docs',1);
    """)

    let plist: [String: Any] = [
        "Children": [
            [
                "WebBookmarkType": "WebBookmarkTypeLeaf",
                "URLString": "https://developer.apple.com/documentation/",
                "URIDictionary": ["title": "Apple Developer Documentation"]
            ]
        ]
    ]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: library.appendingPathComponent("Bookmarks.plist"))

    let visits = try await SafariImporter(libraryDirectory: library, maxHistoryItems: 10).importVisits()
    require(visits.count == 2, "Safari importer should parse one history item and one bookmark")
    require(visits.contains { $0.kind.contains(.history) && $0.canonicalURL == "https://sqlite.org/docs" }, "Safari history should canonicalize URL")
    require(visits.contains { $0.kind.contains(.bookmark) && $0.domain == "developer.apple.com" }, "Safari bookmarks should parse plist bookmark URLs")
    require(
        visits.contains { $0.kind.contains(.bookmark) && $0.visitedAt == Date.distantPast },
        "Safari bookmarks without per-bookmark dates should not inherit the bookmark file modification date"
    )
}

func verifyPersistentIndex(in root: URL) async {
    let db = root.appendingPathComponent("Index.sqlite")
    let index = MemoryIndex(databaseURL: db)
    let priorSeen = Date(timeIntervalSince1970: 1_699_999_900)
    let historySeen = Date(timeIntervalSince1970: 1_700_000_000)
    let laterSeen = Date(timeIntervalSince1970: 1_700_000_120)
    let bookmarkAdded = Date(timeIntervalSince1970: 1_800_000_000)
    let prior = BrowserVisit(
        title: "Swift Forums",
        url: URL(string: "https://forums.swift.org/t/browserlens")!,
        canonicalURL: "https://forums.swift.org/t/browserlens",
        domain: "forums.swift.org",
        source: .safari,
        kind: .history,
        visitedAt: priorSeen,
        sourceItemID: "fixture:history:0"
    )
    let first = BrowserVisit(
        title: "Example Docs",
        url: URL(string: "https://example.com/docs?q=swift")!,
        canonicalURL: "https://example.com/docs?q=swift",
        domain: "example.com",
        source: .chrome,
        kind: .history,
        visitedAt: historySeen,
        sourceItemID: "fixture:history:1",
        occurrenceCount: 2
    )
    let later = BrowserVisit(
        title: "Apple Docs",
        url: URL(string: "https://developer.apple.com/documentation/swiftui")!,
        canonicalURL: "https://developer.apple.com/documentation/swiftui",
        domain: "developer.apple.com",
        source: .safari,
        kind: .history,
        visitedAt: laterSeen,
        sourceItemID: "fixture:history:2"
    )
    let duplicateURL = BrowserVisit(
        title: "Example Bookmark",
        url: URL(string: "https://example.com/docs?utm_source=test&q=swift")!,
        canonicalURL: "https://example.com/docs?q=swift",
        domain: "example.com",
        source: .safari,
        kind: .bookmark,
        visitedAt: bookmarkAdded,
        sourceItemID: "fixture:bookmark:1"
    )

    await index.ingest([prior, first, later, duplicateURL])
    await index.ingest([prior, first, later, duplicateURL])

    let results = await index.search("example")
    require(results.count == 1, "persistent index should dedupe canonical URLs")
    require(results[0].visitCount == 3, "persistent index should not inflate repeated imports")
    require(results[0].kind.contains(.history), "deduped item should retain history kind")
    require(results[0].kind.contains(.bookmark), "deduped item should retain bookmark kind")
    require(results[0].sources == [.chrome, .safari], "deduped item should retain both sources")
    require(
        abs(results[0].lastSeen.timeIntervalSince1970 - historySeen.timeIntervalSince1970) < 0.001,
        "deduped item lastSeen should prefer real history visits over newer bookmark timestamps"
    )
    require(results[0].sessionID != nil, "deduped item should retain a durable session id")
    require(results[0].sessionTitle != nil, "deduped item should retain a session label")

    guard let context = await index.context(for: "https://example.com/docs?q=swift") else {
        require(false, "context lookup should return selected item context")
        return
    }
    require(context.previousVisits.contains { $0.canonicalURL == "https://forums.swift.org/t/browserlens" }, "context should include prior nearby visits")
    require(context.nextVisits.contains { $0.canonicalURL == "https://developer.apple.com/documentation/swiftui" }, "context should include later nearby visits")
    require(context.sessionVisits.count == 3, "context should include same-session history visits")

    let savedTrail = await index.saveTrail(
        name: "Swift Research",
        canonicalURLs: context.sessionVisits.map(\.canonicalURL)
    )
    require(savedTrail != nil, "saveTrail should persist a named local trail")
    let savedContext = await index.context(for: "https://example.com/docs?q=swift")
    require(savedContext?.savedTrails.count == 1, "context should include saved trail membership")

    let tomorrow = Date().addingTimeInterval(24 * 60 * 60)
    let futureOnly = await index.search("example", filter: SearchFilter(dateRange: tomorrow...tomorrow.addingTimeInterval(60)))
    require(futureOnly.isEmpty, "date filter should exclude out-of-range results")

    await index.clear()
    let countAfterClear = await index.itemCount()
    require(countAfterClear == 0, "clear should remove indexed items")
}

func verifySchemaMigration(in root: URL) async {
    let db = root.appendingPathComponent("OldSchema.sqlite")
    try! runSQLite(db, sql: """
    CREATE TABLE imported_visits(id TEXT PRIMARY KEY, canonical_url TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, domain TEXT NOT NULL, source TEXT NOT NULL, kind INTEGER NOT NULL, visited_at REAL NOT NULL, occurrence_count INTEGER NOT NULL);
    CREATE INDEX imported_visits_canonical_idx ON imported_visits(canonical_url);
    CREATE INDEX imported_visits_seen_idx ON imported_visits(visited_at DESC);
    CREATE TABLE items(canonical_url TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL, domain TEXT NOT NULL, sources TEXT NOT NULL, kind INTEGER NOT NULL, first_seen REAL NOT NULL, last_seen REAL NOT NULL, visit_count INTEGER NOT NULL, session_title TEXT NULL);
    CREATE VIRTUAL TABLE item_fts USING fts5(canonical_url UNINDEXED, title, url, domain);
    """)

    let index = MemoryIndex(databaseURL: db)
    let visit = BrowserVisit(
        title: "Migrated Item",
        url: URL(string: "https://migrated.example/item")!,
        canonicalURL: "https://migrated.example/item",
        domain: "migrated.example",
        source: .chrome,
        kind: .history,
        visitedAt: Date(timeIntervalSince1970: 1_900_000_000),
        sourceItemID: "migration:history:1"
    )

    await index.ingest([visit])
    let results = await index.search("migrated")
    require(results.count == 1, "old schema should migrate and remain searchable")
    require(results[0].sessionID != nil, "old schema migration should add session identity support")
}

func verifyFilteredSearchAppliesBeforeLimit(in root: URL) async {
    let db = root.appendingPathComponent("FilterLimit.sqlite")
    let index = MemoryIndex(databaseURL: db)
    let recentBase = Date(timeIntervalSince1970: 2_000_000_000)
    var visits: [BrowserVisit] = []

    for offset in 0..<250 {
        visits.append(BrowserVisit(
            title: "Recent History \(offset)",
            url: URL(string: "https://recent\(offset).example/page")!,
            canonicalURL: "https://recent\(offset).example/page",
            domain: "recent\(offset).example",
            source: .chrome,
            kind: .history,
            visitedAt: recentBase.addingTimeInterval(TimeInterval(offset)),
            sourceItemID: "filter-limit:history:\(offset)"
        ))
    }

    let oldBookmark = BrowserVisit(
        title: "Older Bookmark",
        url: URL(string: "https://bookmarks.example/old")!,
        canonicalURL: "https://bookmarks.example/old",
        domain: "bookmarks.example",
        source: .safari,
        kind: .bookmark,
        visitedAt: Date(timeIntervalSince1970: 1_000_000_000),
        sourceItemID: "filter-limit:bookmark"
    )

    await index.ingest(visits + [oldBookmark])
    let bookmarkResults = await index.search(
        "",
        filter: SearchFilter(requiredKind: .bookmark),
        limit: 200
    )
    require(
        bookmarkResults.contains { $0.canonicalURL == oldBookmark.canonicalURL },
        "bookmark filter should be applied before result limit so older bookmarks remain visible"
    )

    let noSourceResults = await index.search(
        "",
        filter: SearchFilter(sources: []),
        limit: 200
    )
    require(noSourceResults.isEmpty, "empty source filter should return no results")
}

func runSQLite(_ database: URL, sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    try process.run()
    process.waitUntilExit()
    require(process.terminationStatus == 0, "sqlite fixture creation should succeed for \(database.lastPathComponent)")
}
