import Foundation

/// The hours someone works, used to measure the pace of windows longer than
/// a day in working time instead of calendar time.
struct WorkSchedule: Codable, Equatable, Sendable {
    /// `Calendar` weekday numbers: 1 is Sunday, 7 is Saturday.
    var weekdays: Set<Int>
    var startHour: Int
    var endHour: Int

    static let standard = WorkSchedule(weekdays: [2, 3, 4, 5, 6], startHour: 9, endHour: 18)

    /// Far enough ahead for a monthly window; bounds the day-by-day walks.
    private static let maximumDays = 400

    /// Working time between two dates; zero when `end` is not after `start`.
    func workingTime(from start: Date, to end: Date, calendar: Calendar) -> TimeInterval {
        guard start < end else { return 0 }
        var total: TimeInterval = 0
        var day = calendar.startOfDay(for: start)
        for _ in 0..<Self.maximumDays where day < end {
            if let hours = workingHours(on: day, calendar: calendar) {
                let from = max(hours.start, start)
                let to = min(hours.end, end)
                if from < to { total += to.timeIntervalSince(from) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return total
    }

    /// The moment `amount` of working time after `start`; `nil` when the
    /// schedule has no working time within the next year or so.
    func date(byAddingWorkingTime amount: TimeInterval, to start: Date, calendar: Calendar) -> Date? {
        var remaining = amount
        var day = calendar.startOfDay(for: start)
        for _ in 0..<Self.maximumDays {
            if let hours = workingHours(on: day, calendar: calendar) {
                let from = max(hours.start, start)
                if from < hours.end {
                    let available = hours.end.timeIntervalSince(from)
                    if remaining <= available { return from.addingTimeInterval(remaining) }
                    remaining -= available
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    private func workingHours(on day: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        guard weekdays.contains(calendar.component(.weekday, from: day)),
              startHour < endHour,
              let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day),
              let end = endHour >= 24
                ? calendar.date(byAdding: .day, value: 1, to: day)
                : calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day)
        else { return nil }
        return (start, end)
    }
}
