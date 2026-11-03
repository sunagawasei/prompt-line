import Foundation
import Testing
@testable import PromptLineCore

@Suite struct AgeLabelTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    /// 2026-11-03 12:00 JST
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))! }

    private func label(secondsAgo: Double) -> String {
        let ms = Int64((now.timeIntervalSince1970 - secondsAgo) * 1000)
        return AgeLabel.text(forTimestamp: ms, now: now, calendar: calendar)
    }

    private func label(_ components: DateComponents) -> String {
        let ms = Int64(calendar.date(from: components)!.timeIntervalSince1970 * 1000)
        return AgeLabel.text(forTimestamp: ms, now: now, calendar: calendar)
    }

    @Test func underAMinuteIsJustNow() {
        #expect(label(secondsAgo: 5) == "たった今")
        #expect(label(secondsAgo: -30) == "たった今")
    }

    @Test func underAnHourCountsMinutes() {
        #expect(label(secondsAgo: 180) == "3分前")
        #expect(label(secondsAgo: 59 * 60) == "59分前")
    }

    @Test func sameDayCountsHours() {
        #expect(label(secondsAgo: 3 * 3600) == "3時間前")
    }

    @Test func previousDayIsYesterday() {
        #expect(label(DateComponents(year: 2026, month: 11, day: 2, hour: 23)) == "昨日")
        #expect(label(DateComponents(year: 2026, month: 11, day: 2, hour: 1)) == "昨日")
    }

    @Test func olderShowsMonthDay() {
        #expect(label(DateComponents(year: 2026, month: 11, day: 1, hour: 9)) == "11/1")
    }

    @Test func otherYearShowsYear() {
        #expect(label(DateComponents(year: 2025, month: 12, day: 24, hour: 9)) == "2025/12/24")
    }
}
