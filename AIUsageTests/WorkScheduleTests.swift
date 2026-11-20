import XCTest
@testable import AIUsage

final class WorkScheduleTests: XCTestCase {
    private let schedule = WorkSchedule.standard // Mon–Fri 9–18
    private let hour: TimeInterval = 3_600
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ProviderParsing.date(iso)!
    }

    // MARK: - Working time

    func testWorkingTimeCountsOnlyHoursInsideTheSchedule() {
        XCTAssertEqual(
            schedule.workingTime(from: date("2027-01-18T08:00:00Z"), to: date("2027-01-18T12:00:00Z"), calendar: calendar),
            3 * hour
        )
        XCTAssertEqual(
            schedule.workingTime(from: date("2027-01-22T17:00:00Z"), to: date("2027-01-25T08:00:00Z"), calendar: calendar),
            1 * hour
        )
        XCTAssertEqual(
            schedule.workingTime(from: date("2027-01-18T08:00:00Z"), to: date("2027-01-25T08:00:00Z"), calendar: calendar),
            45 * hour
        )
    }

    func testWorkingTimeIsZeroBackwardsOrWithoutWorkingDays() {
        XCTAssertEqual(
            schedule.workingTime(from: date("2027-01-19T12:00:00Z"), to: date("2027-01-18T12:00:00Z"), calendar: calendar),
            0
        )
        let none = WorkSchedule(weekdays: [], startHour: 9, endHour: 18)
        XCTAssertEqual(
            none.workingTime(from: date("2027-01-18T08:00:00Z"), to: date("2027-01-25T08:00:00Z"), calendar: calendar),
            0
        )
    }

    func testAddingWorkingTimeSkipsNightsAndWeekends() {
        XCTAssertEqual(
            schedule.date(byAddingWorkingTime: 1 * hour, to: date("2027-01-18T10:30:00Z"), calendar: calendar),
            date("2027-01-18T11:30:00Z")
        )
        XCTAssertEqual(
            schedule.date(byAddingWorkingTime: 3 * hour, to: date("2027-01-22T17:00:00Z"), calendar: calendar),
            date("2027-01-25T11:00:00Z")
        )
        XCTAssertNil(
            WorkSchedule(weekdays: [], startHour: 9, endHour: 18)
                .date(byAddingWorkingTime: hour, to: date("2027-01-18T08:00:00Z"), calendar: calendar)
        )
    }

    // MARK: - Projection

    private func weekly(used: Double) -> QuotaWindow {
        QuotaWindow(
            kind: .weekly,
            usedPercent: used,
            resetsAt: date("2027-01-25T08:00:00Z"),
            startsAt: date("2027-01-18T08:00:00Z")
        )
    }

    func testWorkingHoursDropTheWeekendFalseAlarm() {
        let window = weekly(used: 70)
        let friday = date("2027-01-22T17:00:00Z")
        XCTAssertNotNil(window.projectedExhaustion(measuredAt: friday))
        XCTAssertNil(window.projectedExhaustion(measuredAt: friday, schedule: schedule, calendar: calendar))
    }

    func testWorkingHoursProjectIntoWorkingTime() {
        let window = weekly(used: 40)
        XCTAssertEqual(
            window.projectedExhaustion(
                measuredAt: date("2027-01-19T12:00:00Z"),
                schedule: schedule,
                calendar: calendar
            ),
            date("2027-01-21T12:00:00Z")
        )
    }

    func testWorkingHoursNeedTenPercentOfTheWindowsWorkingTime() {
        let window = weekly(used: 10)
        XCTAssertNil(window.projectedExhaustion(
            measuredAt: date("2027-01-18T13:00:00Z"),
            schedule: schedule,
            calendar: calendar
        ))
    }

    func testWindowsOfADayOrLessIgnoreTheSchedule() {
        let saturday = date("2027-01-23T10:00:00Z")
        let session = QuotaWindow(
            kind: .session,
            usedPercent: 40,
            resetsAt: saturday.addingTimeInterval(4 * hour),
            startsAt: saturday.addingTimeInterval(-hour)
        )
        XCTAssertEqual(
            session.projectedExhaustion(measuredAt: saturday, schedule: schedule, calendar: calendar),
            session.projectedExhaustion(measuredAt: saturday)
        )
        XCTAssertNotNil(session.projectedExhaustion(measuredAt: saturday))

        let daily = QuotaWindow(
            kind: .daily,
            usedPercent: 60,
            resetsAt: saturday.addingTimeInterval(14 * hour),
            startsAt: saturday.addingTimeInterval(-10 * hour)
        )
        XCTAssertEqual(
            daily.projectedExhaustion(measuredAt: saturday, schedule: schedule, calendar: calendar),
            daily.projectedExhaustion(measuredAt: saturday)
        )
        XCTAssertNotNil(daily.projectedExhaustion(measuredAt: saturday))
    }
}
