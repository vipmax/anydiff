import XCTest
@testable import AnyDiffCore

final class UpdateScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testNextCheckIsTopOfNextHour() {
        let now = date(hour: 10, minute: 30, second: 15)

        XCTAssertEqual(UpdateSchedule.nextHourlyCheck(after: now, calendar: calendar), date(hour: 11, minute: 0, second: 0))
    }

    func testCheckExactlyAtTopOfHourSchedulesNextHour() {
        let now = date(hour: 10, minute: 0, second: 0)

        XCTAssertEqual(UpdateSchedule.nextHourlyCheck(after: now, calendar: calendar), date(hour: 11, minute: 0, second: 0))
    }

    private func date(hour: Int, minute: Int, second: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: hour, minute: minute, second: second))!
    }
}
