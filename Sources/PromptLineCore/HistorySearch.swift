import Foundation

public enum HistorySearch {
    /// 検索語を空白(全角空白も)で区切ったキーワード。大文字小文字は区別しない比較に使う前提で小文字にする
    public static func keywords(_ query: String) -> [String] {
        query.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    /// 空白(全角空白も)で区切ったキーワードを、すべて含む履歴だけを返す。大文字小文字は区別しない。
    /// 並びは元のまま(新しい順)。キーワードが空なら全件。
    public static func filter(_ items: [HistoryItem], query: String) -> [HistoryItem] {
        let keywords = keywords(query)
        guard !keywords.isEmpty else { return items }
        return items.filter { item in
            let text = item.text.lowercased()
            return keywords.allSatisfy { text.contains($0) }
        }
    }
}
