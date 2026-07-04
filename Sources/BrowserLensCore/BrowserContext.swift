import Foundation

public struct SavedTrail: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var itemCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        itemCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.itemCount = itemCount
    }
}

public struct BrowserContext: Equatable, Sendable {
    public var item: BrowserItem
    public var previousVisits: [BrowserVisit]
    public var nextVisits: [BrowserVisit]
    public var sessionVisits: [BrowserVisit]
    public var savedTrails: [SavedTrail]

    public init(
        item: BrowserItem,
        previousVisits: [BrowserVisit] = [],
        nextVisits: [BrowserVisit] = [],
        sessionVisits: [BrowserVisit] = [],
        savedTrails: [SavedTrail] = []
    ) {
        self.item = item
        self.previousVisits = previousVisits
        self.nextVisits = nextVisits
        self.sessionVisits = sessionVisits
        self.savedTrails = savedTrails
    }
}
