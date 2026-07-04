import Foundation

public struct BrowserSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var primaryDomain: String
    public var visits: [BrowserVisit]

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date,
        primaryDomain: String,
        visits: [BrowserVisit]
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.primaryDomain = primaryDomain
        self.visits = visits
    }
}

public struct Sessionizer: Sendable {
    public var inactivityGap: TimeInterval

    public init(inactivityGap: TimeInterval = 30 * 60) {
        self.inactivityGap = inactivityGap
    }

    public func group(_ visits: [BrowserVisit]) -> [BrowserSession] {
        let ordered = visits.sorted { $0.visitedAt < $1.visitedAt }
        var sessions: [BrowserSession] = []
        var current: [BrowserVisit] = []

        for visit in ordered {
            guard let last = current.last else {
                current = [visit]
                continue
            }

            let sameDomain = visit.domain == last.domain
            let closeEnough = visit.visitedAt.timeIntervalSince(last.visitedAt) <= inactivityGap

            if sameDomain || closeEnough {
                current.append(visit)
            } else {
                sessions.append(makeSession(from: current))
                current = [visit]
            }
        }

        if !current.isEmpty {
            sessions.append(makeSession(from: current))
        }

        return sessions
    }

    private func makeSession(from visits: [BrowserVisit]) -> BrowserSession {
        let domainCounts = Dictionary(grouping: visits, by: \.domain)
            .mapValues(\.count)
        let primaryDomain = domainCounts.max { left, right in
            if left.value == right.value {
                return left.key > right.key
            }
            return left.value < right.value
        }?.key ?? "unknown"
        let first = visits.first?.visitedAt ?? Date()
        let last = visits.last?.visitedAt ?? first

        return BrowserSession(
            id: deterministicSessionID(for: visits, primaryDomain: primaryDomain, first: first, last: last),
            title: title(for: primaryDomain, count: visits.count),
            startedAt: first,
            endedAt: last,
            primaryDomain: primaryDomain,
            visits: visits
        )
    }

    private func title(for domain: String, count: Int) -> String {
        count == 1 ? domain : "\(domain) and \(count - 1) related visits"
    }

    private func deterministicSessionID(
        for visits: [BrowserVisit],
        primaryDomain: String,
        first: Date,
        last: Date
    ) -> UUID {
        let visitIDs = visits.map(\.sourceItemID).joined(separator: "|")
        let seed = "\(primaryDomain)|\(first.timeIntervalSince1970)|\(last.timeIntervalSince1970)|\(visitIDs)"
        return UUID(uuidString: deterministicUUIDString(from: seed)) ?? UUID()
    }
}

private func deterministicUUIDString(from string: String) -> String {
    var hash = UInt64(14_695_981_039_346_656_037)
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    let hex = String(format: "%016llx%016llx", hash, hash ^ 0x9e3779b97f4a7c15)
    return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
}
