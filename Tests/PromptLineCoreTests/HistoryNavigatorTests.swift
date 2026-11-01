import Testing
@testable import PromptLineCore

private func items(_ texts: String...) -> [HistoryItem] {
    texts.enumerated().map { HistoryItem(text: $0.element, timestamp: Int64($0.offset), id: "id\($0.offset)") }
}

@Suite struct HistoryNavigatorTests {
    // 新しい順: 最新は "c"
    private let history = items("c", "b", "a")

    @Test func olderStartsAtNewestAndKeepsTheCurrentInput() {
        var nav = HistoryNavigator()
        #expect(nav.older(in: history, current: "書きかけ") == "c")
        #expect(nav.older(in: history, current: "c") == "b")
        #expect(nav.stash == "書きかけ")
    }

    @Test func olderStopsAtTheOldestItem() {
        var nav = HistoryNavigator()
        _ = nav.older(in: history, current: "")
        _ = nav.older(in: history, current: "c")
        #expect(nav.older(in: history, current: "b") == "a")
        #expect(nav.older(in: history, current: "a") == nil)
        #expect(nav.index == 2)
    }

    @Test func newerGoesBackToTheInputBeforeNavigating() {
        var nav = HistoryNavigator()
        _ = nav.older(in: history, current: "書きかけ")
        _ = nav.older(in: history, current: "c")
        #expect(nav.newer(in: history) == "c")
        #expect(nav.newer(in: history) == "書きかけ")
        #expect(!nav.isNavigating)
    }

    @Test func newerDoesNothingWhenNotNavigating() {
        var nav = HistoryNavigator()
        #expect(nav.newer(in: history) == nil)
    }

    @Test func emptyHistoryDoesNothing() {
        var nav = HistoryNavigator()
        #expect(nav.older(in: [], current: "x") == nil)
        #expect(!nav.isNavigating)
    }

    @Test func resetForgetsTheStash() {
        var nav = HistoryNavigator()
        _ = nav.older(in: history, current: "書きかけ")
        nav.reset()
        #expect(nav.index == -1)
        #expect(nav.stash == "")
    }
}
