import Foundation

public struct ImportStatus: Equatable, Sendable {
    public var isRunning: Bool
    public var isImporting: Bool
    public var lastImportDate: Date?
    public var lastImportedCount: Int
    public var lastError: String?

    public init(
        isRunning: Bool,
        isImporting: Bool,
        lastImportDate: Date? = nil,
        lastImportedCount: Int,
        lastError: String? = nil
    ) {
        self.isRunning = isRunning
        self.isImporting = isImporting
        self.lastImportDate = lastImportDate
        self.lastImportedCount = lastImportedCount
        self.lastError = lastError
    }
}

public actor ImportScheduler {
    private let index: MemoryIndex
    private let importers: [any BrowserImporter]
    private let interval: TimeInterval
    private var task: Task<Void, Never>?
    private var isImporting = false
    private var lastImportDate: Date?
    private var lastImportedCount = 0
    private var lastError: String?

    public init(
        index: MemoryIndex,
        importers: [any BrowserImporter],
        interval: TimeInterval = 5 * 60
    ) {
        self.index = index
        self.importers = importers
        self.interval = interval
    }

    public func start() {
        guard task == nil else {
            return
        }

        task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func importNow() async -> ImportStatus {
        guard !isImporting else {
            return status()
        }

        isImporting = true
        defer { isImporting = false }

        var importedCount = 0
        var errors: [String] = []
        for importer in importers {
            do {
                let visits = try await importer.importVisits()
                importedCount += visits.count
                await index.ingest(visits)
            } catch {
                errors.append("\(importer.source.rawValue): \(error.localizedDescription)")
                // Keep the background loop alive. A later settings UI can surface these errors.
                fputs("BrowserLens import failed for \(importer.source.rawValue): \(error.localizedDescription)\n", stderr)
            }
        }

        lastImportDate = Date()
        lastImportedCount = importedCount
        lastError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        return status()
    }

    public func status() -> ImportStatus {
        ImportStatus(
            isRunning: task != nil,
            isImporting: isImporting,
            lastImportDate: lastImportDate,
            lastImportedCount: lastImportedCount,
            lastError: lastError
        )
    }

    private func runLoop() async {
        _ = await importNow()

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }

            _ = await importNow()
        }
    }
}
