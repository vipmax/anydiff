import Foundation

/// Automatic update checks run at launch and then at the top of every hour.
public enum UpdateSchedule {
    /// The next top-of-the-hour (minute 0, second 0) strictly after `date`.
    public static func nextHourlyCheck(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: date,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(60 * 60)
    }
}
