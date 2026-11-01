/// Ctrl+j / Ctrl+k で入力欄の中身を履歴に入れ替えていくときの位置と、送り始める前に入力していた文章。
/// 履歴は新しい順(先頭が最新)。
public struct HistoryNavigator {
    /// -1 は履歴を送っていない(入力中の文章を表示している)
    public private(set) var index = -1
    /// 送り始める前の入力。送り終えて戻ったときと、閉じたときの下書きに使う
    public private(set) var stash = ""

    public var isNavigating: Bool { index >= 0 }

    public init() {}

    /// 古い方へ 1 件。表示する文章を返す。履歴が空・一番古い件まで来ていれば nil(何も変えない)
    public mutating func older(in items: [HistoryItem], current: String) -> String? {
        guard !items.isEmpty else { return nil }
        if index == -1 {
            stash = current
            index = 0
        } else if index < items.count - 1 {
            index += 1
        } else {
            return nil
        }
        return items[index].text
    }

    /// 新しい方へ 1 件。最新の件から更に進むと、送り始める前の入力へ戻る。送っていなければ nil
    public mutating func newer(in items: [HistoryItem]) -> String? {
        guard index >= 0 else { return nil }
        if index == 0 {
            index = -1
            return stash
        }
        index -= 1
        return items[index].text
    }

    /// 送りをやめる(入力を直接編集した・貼り付けた・閉じたとき)
    public mutating func reset() {
        index = -1
        stash = ""
    }
}
