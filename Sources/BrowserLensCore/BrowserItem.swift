import Foundation

public enum BrowserSource: String, Codable, CaseIterable, Sendable {
    case safari
    case chrome
}

public struct BrowserItemKind: OptionSet, Codable, Sendable {
    public let rawValue: Int

    public static let history = BrowserItemKind(rawValue: 1 << 0)
    public static let bookmark = BrowserItemKind(rawValue: 1 << 1)

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public struct BrowserItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var url: URL
    public var canonicalURL: String
    public var domain: String
    public var sources: Set<BrowserSource>
    public var kind: BrowserItemKind
    public var firstSeen: Date
    public var lastSeen: Date
    public var visitCount: Int
    public var sessionID: UUID?
    public var sessionTitle: String?

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        canonicalURL: String,
        domain: String,
        sources: Set<BrowserSource>,
        kind: BrowserItemKind,
        firstSeen: Date,
        lastSeen: Date,
        visitCount: Int,
        sessionID: UUID? = nil,
        sessionTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.canonicalURL = canonicalURL
        self.domain = domain
        self.sources = sources
        self.kind = kind
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.visitCount = visitCount
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
    }
}

public struct BrowserVisit: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var url: URL
    public var canonicalURL: String
    public var domain: String
    public var source: BrowserSource
    public var kind: BrowserItemKind
    public var visitedAt: Date
    public var sourceItemID: String
    public var occurrenceCount: Int

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        canonicalURL: String,
        domain: String,
        source: BrowserSource,
        kind: BrowserItemKind,
        visitedAt: Date,
        sourceItemID: String? = nil,
        occurrenceCount: Int = 1
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.canonicalURL = canonicalURL
        self.domain = domain
        self.source = source
        self.kind = kind
        self.visitedAt = visitedAt
        self.sourceItemID = sourceItemID ?? "\(source.rawValue)-\(kind.rawValue)-\(canonicalURL)"
        self.occurrenceCount = occurrenceCount
    }
}
