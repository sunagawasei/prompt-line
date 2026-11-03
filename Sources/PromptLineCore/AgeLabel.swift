import Foundation

/// 履歴の各行の右端に出す、入力した時刻の短い表記(「3分前」「昨日」「11/1」)
public enum AgeLabel {
    public static func text(forTimestamp milliseconds: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let then = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let seconds = now.timeIntervalSince(then)
        if seconds < 60 { return "たった今" }
        if seconds < 3600 { return "\(Int(seconds / 60))分前" }
        if seconds < 86400, calendar.isDate(then, inSameDayAs: now) { return "\(Int(seconds / 3600))時間前" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(then, inSameDayAs: yesterday) {
            return "昨日"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: then)
        let monthDay = "\(parts.month ?? 0)/\(parts.day ?? 0)"
        return parts.year == calendar.component(.year, from: now) ? monthDay : "\(parts.year ?? 0)/" + monthDay
    }
}
