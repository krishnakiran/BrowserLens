import Foundation

public struct SearchFilter: Equatable, Sendable {
    public var sources: Set<BrowserSource>
    public var requiredKind: BrowserItemKind?
    public var dateRange: ClosedRange<Date>?

    public init(
        sources: Set<BrowserSource> = Set(BrowserSource.allCases),
        requiredKind: BrowserItemKind? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) {
        self.sources = sources
        self.requiredKind = requiredKind
        self.dateRange = dateRange
    }

    public func includes(_ item: BrowserItem) -> Bool {
        guard !sources.isDisjoint(with: item.sources) else {
            return false
        }

        if let requiredKind, !item.kind.contains(requiredKind) {
            return false
        }

        if let dateRange, !dateRange.contains(item.lastSeen) {
            return false
        }

        return true
    }
}

