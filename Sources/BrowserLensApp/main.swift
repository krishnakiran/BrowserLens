import AppKit
import BrowserLensCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let importInterval: TimeInterval = 60

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var searchWindow: NSWindow?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private let index = MemoryIndex()
    private lazy var importScheduler = ImportScheduler(
        index: index,
        importers: [SafariImporter()] + ChromeImporter.discoverProfiles(),
        interval: Self.importInterval
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureHotkey()
        Task {
            await importScheduler.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalHotkeyMonitor {
            NSEvent.removeMonitor(globalHotkeyMonitor)
        }
        if let localHotkeyMonitor {
            NSEvent.removeMonitor(localHotkeyMonitor)
        }
        Task {
            await importScheduler.stop()
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "eye.circle", accessibilityDescription: "BrowserLens")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func configureHotkey() {
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.isBrowserLensHotkey else { return }
            DispatchQueue.main.async {
                self?.showSearchWindow()
            }
        }

        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.isBrowserLensHotkey else { return event }
            self?.showSearchWindow()
            return nil
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu(from: sender)
        } else {
            showSearchWindow()
        }
    }

    private func showStatusMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open BrowserLens", action: #selector(openSearchFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit BrowserLens", action: #selector(quitBrowserLens), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func openSearchFromMenu() {
        showSearchWindow()
    }

    @objc private func quitBrowserLens() {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSearchWindow()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeSearchWindowToMenuBar()
        return false
    }

    private func showSearchWindow() {
        NSApp.setActivationPolicy(.regular)

        if let existingWindow = searchWindow {
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let view = SearchView(index: index, scheduler: importScheduler) { [weak self] in
            self?.closeSearchWindowToMenuBar()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BrowserLens"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        searchWindow = window
    }

    private func closeSearchWindowToMenuBar() {
        searchWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct BrowserLensApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

private struct LensPalette {
    let background: Color
    let surface: Color
    let elevated: Color
    let selected: Color
    let selectedSoft: Color
    let border: Color
    let primary: Color
    let primaryInverted: Color
    let muted: Color
    let faint: Color
    let hover: Color
}

private enum LensTheme {
    static let night = LensPalette(
        background: Color(red: 0.075, green: 0.075, blue: 0.085),
        surface: Color(red: 0.115, green: 0.115, blue: 0.13),
        elevated: Color(red: 0.155, green: 0.155, blue: 0.175),
        selected: Color(red: 0.84, green: 0.20, blue: 0.24),
        selectedSoft: Color(red: 0.84, green: 0.20, blue: 0.24).opacity(0.18),
        border: Color.white.opacity(0.08),
        primary: .white,
        primaryInverted: .white,
        muted: Color.white.opacity(0.52),
        faint: Color.white.opacity(0.32),
        hover: Color.white.opacity(0.06)
    )

    static let day = LensPalette(
        background: Color(red: 0.965, green: 0.965, blue: 0.975),
        surface: Color(red: 0.925, green: 0.925, blue: 0.94),
        elevated: .white,
        selected: Color(red: 0.80, green: 0.16, blue: 0.20),
        selectedSoft: Color(red: 0.80, green: 0.16, blue: 0.20).opacity(0.12),
        border: Color.black.opacity(0.08),
        primary: Color(red: 0.10, green: 0.10, blue: 0.12),
        primaryInverted: .white,
        muted: Color.black.opacity(0.58),
        faint: Color.black.opacity(0.36),
        hover: Color.black.opacity(0.05)
    )
}

private struct LensPaletteKey: EnvironmentKey {
    static let defaultValue = LensTheme.night
}

private extension EnvironmentValues {
    var lensPalette: LensPalette {
        get { self[LensPaletteKey.self] }
        set { self[LensPaletteKey.self] = newValue }
    }
}

struct SearchView: View {
    @AppStorage("BrowserLensAppearanceMode") private var appearanceMode = "night"
    @State private var query = ""
    @State private var selectedSource: BrowserSource?
    @State private var selectedKind: BrowserItemKind?
    @State private var selectedDatePreset: DateFilterPreset = .all
    @State private var results: [BrowserItem] = []
    @State private var selectedIndex = 0
    @State private var importStatus = ImportStatus(
        isRunning: false,
        isImporting: false,
        lastImportDate: nil,
        lastImportedCount: 0,
        lastError: nil
    )
    @State private var itemCount = 0
    @State private var localKeyMonitor: Any?
    @State private var browserContext: BrowserContext?
    @State private var contextIsLoading = false
    @State private var contextTask: Task<Void, Never>?
    @FocusState private var searchIsFocused: Bool

    let index: MemoryIndex
    let scheduler: ImportScheduler
    let close: () -> Void

    private var isNightMode: Bool {
        appearanceMode != "day"
    }

    private var palette: LensPalette {
        isNightMode ? LensTheme.night : LensTheme.day
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            filterBar
            Divider().overlay(palette.border)
            HSplitView {
                resultList
                    .frame(minWidth: 500)
                contextPane
                    .frame(minWidth: 300, idealWidth: 340)
            }
            Divider().overlay(palette.border)
            utilityBar
        }
        .frame(minWidth: 940, minHeight: 620)
        .background(palette.background)
        .environment(\.lensPalette, palette)
        .preferredColorScheme(isNightMode ? .dark : .light)
        .task {
            await loadAndMonitorImportStatus()
        }
        .onChange(of: query) { _ in
            Task { await refreshResults() }
        }
        .onChange(of: selectedIndex) { _ in
            loadContextForSelection()
        }
        .onAppear(perform: installKeyboardMonitor)
        .onDisappear(perform: removeKeyboardMonitor)
    }

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(palette.faint)
            TextField("Search Safari and Chrome memory", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .medium, design: .default))
                .foregroundStyle(palette.primary)
                .focused($searchIsFocused)
            if importStatus.isImporting {
                ProgressView()
                    .scaleEffect(0.62)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            FilterButton(title: "All", systemImage: "magnifyingglass", isSelected: selectedSource == nil && selectedKind == nil) {
                selectedSource = nil
                selectedKind = nil
                Task { await refreshResults() }
            }
            FilterButton(title: "Safari", systemImage: "safari", isSelected: selectedSource == .safari) {
                toggleSource(.safari)
                Task { await refreshResults() }
            }
            FilterButton(title: "Chrome", systemImage: "circle.hexagongrid", isSelected: selectedSource == .chrome) {
                toggleSource(.chrome)
                Task { await refreshResults() }
            }
            FilterButton(title: "History", systemImage: "clock.arrow.circlepath", isSelected: selectedKind == .history) {
                toggleKind(.history)
                Task { await refreshResults() }
            }
            FilterButton(title: "Bookmarks", systemImage: "bookmark", isSelected: selectedKind == .bookmark) {
                toggleKind(.bookmark)
                Task { await refreshResults() }
            }
            DateFilterMenu(selectedPreset: $selectedDatePreset) {
                Task { await refreshResults() }
            }
            Spacer()
            Label("Local", systemImage: "lock")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.faint)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        Button {
                            open(item)
                        } label: {
                            BrowserResultRow(item: item, isSelected: index == selectedIndex)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .help("Open \(item.url.absoluteString)")
                    }
                }
            }
            .onChange(of: selectedIndex) { newValue in
                guard results.indices.contains(newValue) else { return }
                proxy.scrollTo(results[newValue].id, anchor: .center)
            }
            .overlay {
                if results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 32))
                            .foregroundStyle(palette.faint)
                        Text("No browser memory found")
                            .font(.headline)
                        Text(importStatus.isImporting ? "Indexing Safari and Chrome..." : "Use Reindex Now after granting browser file access.")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }
            }
            .background(palette.background)
        }
    }

    private var utilityBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                UtilityButton(title: "Reindex", systemImage: "arrow.clockwise") {
                    Task {
                        importStatus = await scheduler.importNow()
                        await refreshResults()
                    }
                }
                .disabled(importStatus.isImporting)

                UtilityButton(title: importStatus.isRunning ? "Pause" : "Resume", systemImage: importStatus.isRunning ? "pause" : "play") {
                    Task {
                        if importStatus.isRunning {
                            await scheduler.stop()
                        } else {
                            await scheduler.start()
                        }
                        importStatus = await scheduler.status()
                    }
                }

                UtilityButton(title: "Clear", systemImage: "trash") {
                    Task {
                        await index.clear()
                        await refreshResults()
                    }
                }

                if needsFullDiskAccess {
                    UtilityButton(title: "Privacy", systemImage: "gearshape") {
                        openFullDiskAccessSettings()
                    }
                }

                UtilityButton(title: "Quit", systemImage: "xmark") {
                    NSApp.terminate(nil)
                }

                UtilityButton(title: isNightMode ? "Day" : "Night", systemImage: isNightMode ? "sun.max" : "moon") {
                    appearanceMode = isNightMode ? "day" : "night"
                }

                Spacer()

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(importStatus.lastError == nil ? palette.muted : .red)
            }

            HStack(spacing: 6) {
                Text("DB")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                Text(index.databaseURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([index.databaseURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.muted)
                .help("Reveal database")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(palette.surface)
    }

    private var contextPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Context", systemImage: "map")
                    .font(.headline.weight(.semibold))
                Spacer()
                if contextIsLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(palette.border)

            if let browserContext {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ContextSummaryView(context: browserContext) {
                            Task {
                                await saveCurrentTrail()
                            }
                        }
                        VisitSection(title: "Before", visits: browserContext.previousVisits)
                        VisitSection(title: "Same Session", visits: browserContext.sessionVisits)
                        VisitSection(title: "After", visits: browserContext.nextVisits)
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 28))
                        .foregroundStyle(palette.faint)
                    Text("Select a result")
                        .font(.headline)
                    Text("Nearby visits and saved trails appear here.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .background(palette.surface)
    }

    private func refreshResults() async {
        var sources = Set(BrowserSource.allCases)
        if let selectedSource {
            sources = [selectedSource]
        }
        let filter = SearchFilter(
            sources: sources,
            requiredKind: selectedKind,
            dateRange: selectedDatePreset.dateRange
        )
        results = await index.search(query, filter: filter)
        itemCount = await index.itemCount()
        selectedIndex = min(selectedIndex, max(0, results.count - 1))
        loadContextForSelection()
    }

    private func loadAndMonitorImportStatus() async {
        importStatus = await scheduler.status()
        var lastObservedImportDate = importStatus.lastImportDate
        await refreshResults()
        searchIsFocused = true

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            } catch {
                return
            }

            let latestStatus = await scheduler.status()
            let completedNewImport = latestStatus.lastImportDate != nil
                && latestStatus.lastImportDate != lastObservedImportDate
                && !latestStatus.isImporting

            importStatus = latestStatus

            if completedNewImport {
                lastObservedImportDate = latestStatus.lastImportDate
                await refreshResults()
            }
        }
    }

    private func toggleSource(_ source: BrowserSource) {
        selectedSource = selectedSource == source ? nil : source
    }

    private func toggleKind(_ kind: BrowserItemKind) {
        selectedKind = selectedKind == kind ? nil : kind
    }

    private var statusText: String {
        if importStatus.isImporting {
            return "Indexing..."
        }
        if let lastError = importStatus.lastError {
            return lastError
        }
        if let lastImportDate = importStatus.lastImportDate {
            return "\(itemCount) items · imported \(importStatus.lastImportedCount) records · \(lastImportDate.formatted(date: .omitted, time: .shortened))"
        }
        return "\(itemCount) items · \(importStatus.isRunning ? "indexing every 1 min" : "indexing paused")"
    }

    private var needsFullDiskAccess: Bool {
        importStatus.lastError?.contains("Full Disk Access") == true
    }

    private func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func installKeyboardMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private func removeKeyboardMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        contextTask?.cancel()
        contextTask = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)

        if command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            copySelectedURL()
            return true
        }

        if command, event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }

        switch event.keyCode {
        case 36, 76:
            openSelected()
            return true
        case 53:
            close()
            return true
        case 125:
            selectedIndex = min(selectedIndex + 1, max(0, results.count - 1))
            return true
        case 126:
            selectedIndex = max(selectedIndex - 1, 0)
            return true
        default:
            return false
        }
    }

    private func openSelected() {
        guard results.indices.contains(selectedIndex) else {
            return
        }
        open(results[selectedIndex])
    }

    private func copySelectedURL() {
        guard results.indices.contains(selectedIndex) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(results[selectedIndex].url.absoluteString, forType: .string)
    }

    private func open(_ item: BrowserItem) {
        NSWorkspace.shared.open(item.url)
    }

    private func loadContextForSelection() {
        contextTask?.cancel()
        guard results.indices.contains(selectedIndex) else {
            browserContext = nil
            contextIsLoading = false
            return
        }

        let canonicalURL = results[selectedIndex].canonicalURL
        contextIsLoading = true
        contextTask = Task {
            let context = await index.context(for: canonicalURL)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard results.indices.contains(selectedIndex),
                      results[selectedIndex].canonicalURL == canonicalURL
                else {
                    return
                }
                browserContext = context
                contextIsLoading = false
            }
        }
    }

    private func saveCurrentTrail() async {
        guard let browserContext else {
            return
        }
        let canonicalURLs = browserContext.sessionVisits.isEmpty
            ? [browserContext.item.canonicalURL]
            : browserContext.sessionVisits.map(\.canonicalURL)
        let name = browserContext.item.sessionTitle ?? browserContext.item.domain
        _ = await index.saveTrail(name: name, canonicalURLs: canonicalURLs)
        await MainActor.run {
            loadContextForSelection()
        }
    }
}

struct ContextSummaryView: View {
    @Environment(\.lensPalette) private var palette

    let context: BrowserContext
    var saveTrail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(context.item.title.isEmpty ? context.item.domain : context.item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(2)
            Text(context.item.url.absoluteString)
                .font(.caption2)
                .foregroundStyle(palette.muted)
                .lineLimit(2)
            HStack(spacing: 8) {
                Label("\(context.item.visitCount)", systemImage: "clock.arrow.circlepath")
                if !context.savedTrails.isEmpty {
                    Label("\(context.savedTrails.count)", systemImage: "pin")
                }
            }
            .font(.caption)
            .foregroundStyle(palette.faint)

            Button {
                saveTrail()
            } label: {
                Label("Save Trail", systemImage: "pin")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
        }
        .padding(12)
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

struct VisitSection: View {
    @Environment(\.lensPalette) private var palette

    let title: String
    let visits: [BrowserVisit]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.faint)
                Spacer()
                Text("\(visits.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(palette.faint)
            }

            if visits.isEmpty {
                Text("No visits")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            } else {
                ForEach(visits) { visit in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: visit.kind.contains(.bookmark) ? "bookmark.fill" : "clock")
                            .font(.caption2)
                            .foregroundStyle(palette.faint)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visit.title.isEmpty ? visit.domain : visit.title)
                                .font(.caption)
                                .foregroundStyle(palette.primary.opacity(0.88))
                                .lineLimit(1)
                            Text("\(visit.domain) · \(visit.visitedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

struct BrowserResultRow: View {
    @Environment(\.lensPalette) private var palette

    let item: BrowserItem
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? palette.selected : palette.elevated)
                Image(systemName: rowIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? palette.primaryInverted : palette.primary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.isEmpty ? item.domain : item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                Text(item.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(metadataText)
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                    if let sessionTitle = item.sessionTitle, !sessionTitle.isEmpty {
                        Text("Session: \(sessionTitle)")
                            .font(.caption2)
                            .foregroundStyle(palette.faint)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Image(systemName: "arrow.up.forward.app")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.muted)
                .opacity(isHovering || isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? palette.selected.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return palette.selectedSoft
        }
        if isHovering {
            return palette.hover
        }
        return Color.clear
    }

    private var rowIcon: String {
        if item.kind.contains(.bookmark) && !item.kind.contains(.history) {
            return "bookmark.fill"
        }
        if item.sources.contains(.safari) && !item.sources.contains(.chrome) {
            return "safari"
        }
        if item.sources.contains(.chrome) && !item.sources.contains(.safari) {
            return "circle.hexagongrid"
        }
        return "globe"
    }

    private var metadataText: String {
        if item.kind == .bookmark && item.lastSeen < Date(timeIntervalSince1970: 0) {
            return "\(item.domain) · bookmark · date unknown"
        }
        return "\(item.domain) · \(item.visitCount) visits · last seen \(item.lastSeen.formatted(date: .abbreviated, time: .shortened))"
    }
}

private extension NSEvent {
    var isBrowserLensHotkey: Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command)
            && flags.contains(.shift)
            && charactersIgnoringModifiers?.lowercased() == "b"
    }
}

struct DateFilterMenu: View {
    @Environment(\.lensPalette) private var palette

    @Binding var selectedPreset: DateFilterPreset
    var onChange: () -> Void

    var body: some View {
        Menu {
            ForEach(DateFilterPreset.allCases) { preset in
                Button {
                    selectedPreset = preset
                    onChange()
                } label: {
                    if preset == selectedPreset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(selectedPreset.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(selectedPreset == .all ? palette.muted : palette.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selectedPreset == .all ? palette.elevated : palette.selectedSoft)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selectedPreset == .all ? palette.border : palette.selected.opacity(0.35), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct FilterButton: View {
    @Environment(\.lensPalette) private var palette

    var title: String
    var systemImage: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isSelected ? palette.primaryInverted : palette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? palette.selected : palette.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? palette.selected.opacity(0.6) : palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct UtilityButton: View {
    @Environment(\.lensPalette) private var palette

    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.primary.opacity(0.86))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(palette.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
