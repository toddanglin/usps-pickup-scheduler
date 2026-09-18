import Foundation

/// Computes valid USPS carrier pickup dates.
///
/// Rules:
/// - Pickups happen Monday through Saturday; never on Sunday or a USPS (federal) holiday.
/// - Same-day pickup may be requested until 2:00 AM Central Time; after that the earliest
///   available day is the next valid day.
/// - All date math is performed in the `America/Chicago` timezone, regardless of the user's
///   locale or device timezone.
enum PickupDateCalculator {
    static let timeZone = TimeZone(identifier: "America/Chicago")!

    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// The hour (in America/Chicago) after which same-day pickup can no longer be requested.
    private static let sameDayCutoffHour = 2

    /// Next `count` valid pickup days starting from `now` (rules above).
    /// Returned dates are at start-of-day in America/Chicago.
    static func availableDates(from now: Date, count: Int = 6) -> [Date] {
        let hour = calendar.component(.hour, from: now)
        let startOfToday = calendar.startOfDay(for: now)

        var candidate: Date
        if hour < sameDayCutoffHour {
            candidate = startOfToday
        } else {
            candidate = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        }

        var results: [Date] = []
        var iterations = 0
        let maxIterations = 60
        while results.count < count && iterations < maxIterations {
            if isValidPickupDay(candidate) {
                results.append(candidate)
            }
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
            iterations += 1
        }
        return results
    }

    private static func isValidPickupDay(_ date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        // Calendar weekday: 1 = Sunday
        if weekday == 1 { return false }
        if isHoliday(date) { return false }
        return true
    }

    /// "yyyy-MM-dd" in America/Chicago (the USPS API date format).
    static func apiDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// e.g. ("Fri", "19") for day chips.
    static func displayLabel(_ date: Date) -> (weekday: String, day: String) {
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.timeZone = timeZone
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.dateFormat = "EEE"

        let dayFormatter = DateFormatter()
        dayFormatter.timeZone = timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "d"

        return (weekdayFormatter.string(from: date), dayFormatter.string(from: date))
    }

    /// e.g. "Friday, September 19, 2026"
    static func longDisplay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: date)
    }

    /// True if the date (in America/Chicago) is a USPS holiday, applying observed rules.
    static func isHoliday(_ date: Date) -> Bool {
        let year = calendar.component(.year, from: date)
        let normalizedDate = calendar.startOfDay(for: date)
        // Also check next year: New Year's Day on a Saturday is observed on Dec 31 of the prior year.
        return (holidays(forYear: year) + holidays(forYear: year + 1))
            .contains { calendar.isDate($0, inSameDayAs: normalizedDate) }
    }

    // MARK: - Holiday computation

    private static var holidayCache: [Int: [Date]] = [:]

    private static func holidays(forYear year: Int) -> [Date] {
        if let cached = holidayCache[year] {
            return cached
        }
        var dates: [Date] = []

        // Fixed-date holidays (with observed weekend rules). Both the actual calendar date
        // and its shifted observed date are treated as non-pickup days: USPS does not operate
        // on the holiday itself even when it falls on a weekend, and the shifted weekday is
        // also closed.
        dates.append(contentsOf: observedDates(month: 1, day: 1, year: year))    // New Year's Day
        dates.append(contentsOf: observedDates(month: 6, day: 19, year: year))   // Juneteenth
        dates.append(contentsOf: observedDates(month: 7, day: 4, year: year))    // Independence Day
        dates.append(contentsOf: observedDates(month: 11, day: 11, year: year))  // Veterans Day
        dates.append(contentsOf: observedDates(month: 12, day: 25, year: year))  // Christmas

        // Floating holidays (always fall on a weekday, no observed-date adjustment needed).
        dates.append(nthWeekday(weekday: 2, n: 3, month: 1, year: year))   // MLK Day: 3rd Mon Jan
        dates.append(nthWeekday(weekday: 2, n: 3, month: 2, year: year))   // Presidents' Day: 3rd Mon Feb
        dates.append(lastWeekday(weekday: 2, month: 5, year: year))        // Memorial Day: last Mon May
        dates.append(nthWeekday(weekday: 2, n: 1, month: 9, year: year))   // Labor Day: 1st Mon Sep
        dates.append(nthWeekday(weekday: 2, n: 2, month: 10, year: year))  // Columbus Day: 2nd Mon Oct
        dates.append(nthWeekday(weekday: 5, n: 4, month: 11, year: year))  // Thanksgiving: 4th Thu Nov

        holidayCache[year] = dates
        return dates
    }

    /// Returns the non-pickup dates for a fixed-date holiday: the actual calendar date, plus
    /// (when the actual date falls on a weekend) its observed date: Saturday -> observed Friday,
    /// Sunday -> observed Monday.
    private static func observedDates(month: Int, day: Int, year: Int) -> [Date] {
        let actual = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        let weekday = calendar.component(.weekday, from: actual)
        if weekday == 7 { // Saturday
            return [actual, calendar.date(byAdding: .day, value: -1, to: actual)!]
        } else if weekday == 1 { // Sunday
            return [actual, calendar.date(byAdding: .day, value: 1, to: actual)!]
        }
        return [actual]
    }

    /// The nth occurrence of `weekday` (Calendar weekday: 1=Sunday...7=Saturday) in `month`/`year`.
    private static func nthWeekday(weekday: Int, n: Int, month: Int, year: Int) -> Date {
        let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        var offset = weekday - firstWeekday
        if offset < 0 { offset += 7 }
        let dayOfFirstOccurrence = 1 + offset
        let day = dayOfFirstOccurrence + (n - 1) * 7
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The last occurrence of `weekday` (Calendar weekday: 1=Sunday...7=Saturday) in `month`/`year`.
    private static func lastWeekday(weekday: Int, month: Int, year: Int) -> Date {
        let range = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month, day: 1))!)!
        let lastDay = range.upperBound - 1
        let lastOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: lastDay))!
        let lastWeekdayValue = calendar.component(.weekday, from: lastOfMonth)
        var offset = lastWeekdayValue - weekday
        if offset < 0 { offset += 7 }
        let day = lastDay - offset
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
