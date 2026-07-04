import Foundation

public enum DateFilterPreset: String, CaseIterable, Identifiable, Sendable {
    case all
    case today
    case yesterday
    case thisWeek
    case last7Days
    case thisMonth
    case last30Days
    case last90Days
    case thisYear
    case olderThan30Days
    case olderThan90Days

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .all: "All Dates"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This Week"
        case .last7Days: "Last 7 Days"
        case .thisMonth: "This Month"
        case .last30Days: "Last 30 Days"
        case .last90Days: "Last 90 Days"
        case .thisYear: "This Year"
        case .olderThan30Days: "Older Than 30 Days"
        case .olderThan90Days: "Older Than 90 Days"
        }
    }

    public func dateRange(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date>? {
        switch self {
        case .all:
            return nil
        case .today:
            return calendar.startOfDay(for: now)...now
        case .yesterday:
            let today = calendar.startOfDay(for: now)
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                return nil
            }
            return yesterday...today.addingTimeInterval(-0.001)
        case .thisWeek:
            return currentRange(for: .weekOfYear, now: now, calendar: calendar)
        case .last7Days:
            return trailingRange(component: .day, value: -7, now: now, calendar: calendar)
        case .thisMonth:
            return currentRange(for: .month, now: now, calendar: calendar)
        case .last30Days:
            return trailingRange(component: .day, value: -30, now: now, calendar: calendar)
        case .last90Days:
            return trailingRange(component: .day, value: -90, now: now, calendar: calendar)
        case .thisYear:
            return currentRange(for: .year, now: now, calendar: calendar)
        case .olderThan30Days:
            guard let cutoff = calendar.date(byAdding: .day, value: -30, to: now) else {
                return nil
            }
            return Date.distantPast...cutoff
        case .olderThan90Days:
            guard let cutoff = calendar.date(byAdding: .day, value: -90, to: now) else {
                return nil
            }
            return Date.distantPast...cutoff
        }
    }

    public var dateRange: ClosedRange<Date>? {
        dateRange()
    }

    private func trailingRange(
        component: Calendar.Component,
        value: Int,
        now: Date,
        calendar: Calendar
    ) -> ClosedRange<Date>? {
        guard let start = calendar.date(byAdding: component, value: value, to: now) else {
            return nil
        }
        return start...now
    }

    private func currentRange(
        for component: Calendar.Component,
        now: Date,
        calendar: Calendar
    ) -> ClosedRange<Date>? {
        guard let interval = calendar.dateInterval(of: component, for: now) else {
            return nil
        }
        return interval.start...min(now, interval.end.addingTimeInterval(-0.001))
    }
}
