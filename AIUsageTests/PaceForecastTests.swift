import XCTest
@testable import AIUsage

final class PaceForecastTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600

    private func session(
        used: Double,
        startsAt: Date? = nil,
        resetsAt: Date? = nil,
        noStart: Bool = false,
        noReset: Bool = false
    ) -> QuotaWindow {
        QuotaWindow(
            kind: .session,
            usedPercent: used,
            resetsAt: noReset ? nil : (resetsAt ?? t0.addingTimeInterval(5 * hour)),
            startsAt: noStart ? nil : (startsAt ?? t0)
        )
    }

    func testProjectsExhaustionBeforeReset() {
        let window = session(used: 40)
        XCTAssertEqual(
            window.projectedExhaustion(measuredAt: t0.addingTimeInterval(hour)),
            t0.addingTimeInterval(2.5 * hour)
        )
    }

    func testNoProjectionWhenPaceReachesResetFirst() {
        let window = session(used: 10)
        XCTAssertNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(hour)))
    }

    func testNoProjectionBeforeTenPercentElapsed() {
        let window = session(used: 30)
        XCTAssertNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(20 * 60)))
    }

    func testNoProjectionAtZeroUsage() {
        let window = session(used: 0)
        XCTAssertNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(2 * hour)))
    }

    func testNoProjectionAtOrAbove100Percent() {
        let window = session(used: 100)
        XCTAssertNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(hour)))
    }

    func testNoProjectionWithoutStartOrReset() {
        let measured = t0.addingTimeInterval(hour)
        XCTAssertNil(session(used: 40, noStart: true).projectedExhaustion(measuredAt: measured))
        XCTAssertNil(session(used: 40, noReset: true).projectedExhaustion(measuredAt: measured))
    }

    func testNoProjectionAfterReset() {
        let window = session(used: 50)
        XCTAssertNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(5 * hour)))
    }

    func testProjectionUsesMeasurementTimeNotRenderTime() {
        let window = session(used: 40)
        let measured = t0.addingTimeInterval(hour)
        let first = window.projectedExhaustion(measuredAt: measured)
        let second = window.projectedExhaustion(measuredAt: measured)
        XCTAssertEqual(first, t0.addingTimeInterval(2.5 * hour))
        XCTAssertEqual(first, second)
    }

    func testMonthlyStartIsOneCalendarMonthBeforeReset() {
        XCTAssertEqual(
            ProviderParsing.monthStart(endingAt: ProviderParsing.date("2027-03-01T00:00:00Z")),
            ProviderParsing.date("2027-02-01T00:00:00Z")
        )
        XCTAssertEqual(
            ProviderParsing.monthStart(endingAt: ProviderParsing.date("2027-03-31T00:00:00Z")),
            ProviderParsing.date("2027-02-28T00:00:00Z")
        )
        XCTAssertNil(ProviderParsing.monthStart(endingAt: nil))
    }
}
