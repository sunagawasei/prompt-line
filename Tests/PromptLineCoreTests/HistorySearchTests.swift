import Testing
@testable import PromptLineCore

private func items(_ texts: String...) -> [HistoryItem] {
    texts.enumerated().map { HistoryItem(text: $0.element, timestamp: Int64($0.offset), id: "id\($0.offset)") }
}

@Suite struct HistorySearchTests {
    private let history = items("Banana split", "apple pie", "Apple tart と紅茶")

    @Test func emptyQueryReturnsEverything() {
        #expect(HistorySearch.filter(history, query: "  ") == history)
    }

    @Test func matchesCaseInsensitivelyAndKeepsOrder() {
        #expect(HistorySearch.filter(history, query: "APPLE").map(\.text) == ["apple pie", "Apple tart と紅茶"])
    }

    @Test func allKeywordsMustMatch() {
        #expect(HistorySearch.filter(history, query: "apple 紅茶").map(\.text) == ["Apple tart と紅茶"])
    }

    @Test func fullWidthSpaceSeparatesKeywords() {
        #expect(HistorySearch.filter(history, query: "apple\u{3000}紅茶").map(\.text) == ["Apple tart と紅茶"])
    }

    @Test func keywordsAreLowercasedAndSplitOnAnySpace() {
        #expect(HistorySearch.keywords(" Apple\u{3000}紅茶  PIE ") == ["apple", "紅茶", "pie"])
        #expect(HistorySearch.keywords("   ").isEmpty)
    }

    @Test func noMatchReturnsEmpty() {
        #expect(HistorySearch.filter(history, query: "zzz").isEmpty)
    }
}
