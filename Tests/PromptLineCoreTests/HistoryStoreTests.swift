import Foundation
import Testing
@testable import PromptLineCore

private func tempFile(_ lines: [String] = [], trailingNewline: Bool = true) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("history.jsonl")
    var text = lines.joined(separator: "\n")
    if trailingNewline && !lines.isEmpty { text += "\n" }
    try Data(text.utf8).write(to: url)
    return url
}

private func line(_ n: Int) -> String {
    #"{"text":"item \#(n)","timestamp":\#(1000 + n),"id":"id\#(n)","appName":"WezTerm"}"#
}

@Suite struct HistoryStoreTests {
    @Test func loadsNewestFirstLimitedToTheLastN() throws {
        let url = try tempFile((1...12).map(line))
        let store = try HistoryStore(fileURL: url, limit: 5)
        #expect(store.items.map(\.text) == ["item 12", "item 11", "item 10", "item 9", "item 8"])
    }

    @Test func readsAcrossChunkBoundaries() throws {
        let url = try tempFile((1...200).map(line))
        // 1 行(約 70 バイト)より小さいチャンクで、行の途中でチャンクが切れる状況を作る
        let store = try HistoryStore(fileURL: url, limit: 150, chunkSize: 37)
        #expect(store.items.count == 150)
        #expect(store.items.first?.text == "item 200")
        #expect(store.items.last?.text == "item 51")
        #expect(store.skippedLines == 0)
    }

    @Test func returnsEverythingWhenFewerThanLimit() throws {
        let store = try HistoryStore(fileURL: try tempFile((1...3).map(line)), limit: 5000, chunkSize: 16)
        #expect(store.items.map(\.text) == ["item 3", "item 2", "item 1"])
    }

    @Test func skipsBrokenLinesAndCountsThem() throws {
        let url = try tempFile([line(1), "not json", line(2)])
        let store = try HistoryStore(fileURL: url)
        #expect(store.items.map(\.text) == ["item 2", "item 1"])
        #expect(store.skippedLines == 1)
    }

    @Test func createsMissingFileWithOwnerOnlyPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pl-\(UUID().uuidString)/nested")
        let url = dir.appendingPathComponent("history.jsonl")
        let store = try HistoryStore(fileURL: url)
        #expect(store.items.isEmpty)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func addAppendsOneValidLineInElectronFormat() throws {
        let url = try tempFile([line(1)])
        let store = try HistoryStore(fileURL: url)
        let item = try store.add(text: "  こんにちは/世界  \n", appName: "WezTerm", now: Date(timeIntervalSince1970: 2))
        #expect(item?.text == "こんにちは/世界")

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        // スラッシュはエスケープせず、キー順は text, timestamp, id, appName
        let last = String(lines[1])
        #expect(last.hasPrefix(#"{"text":"こんにちは/世界","timestamp":2000,"id":""#))
        #expect(last.hasSuffix(#","appName":"WezTerm"}"#))
        #expect(store.items.first?.text == "こんにちは/世界")
    }

    @Test func emptyTextIsIgnored() throws {
        let store = try HistoryStore(fileURL: try tempFile())
        #expect(try store.add(text: " \n ") == nil)
        #expect(store.items.isEmpty)
    }

    @Test func sameTextAsLatestOnlyUpdatesTimestampInMemory() throws {
        let url = try tempFile([line(1)])
        let store = try HistoryStore(fileURL: url)
        try store.add(text: "item 1", appName: "Slack", now: Date(timeIntervalSince1970: 9))
        #expect(store.items.count == 1)
        #expect(store.items[0].timestamp == 9000)
        #expect(store.items[0].appName == "Slack")
        #expect(try String(contentsOf: url, encoding: .utf8) == line(1) + "\n")
    }

    @Test func appendAfterFileWithoutTrailingNewlineKeepsLinesSeparate() throws {
        let url = try tempFile([line(1)], trailingNewline: false)
        let store = try HistoryStore(fileURL: url)
        try store.add(text: "next")
        let reloaded = try HistoryStore(fileURL: url)
        #expect(reloaded.items.map(\.text) == ["next", "item 1"])
        #expect(reloaded.skippedLines == 0)
    }

    @Test func keepsOnlyLimitItemsInMemory() throws {
        let store = try HistoryStore(fileURL: try tempFile((1...3).map(line)), limit: 3)
        try store.add(text: "new")
        #expect(store.items.map(\.text) == ["new", "item 3", "item 2"])
    }

    /// 実際の履歴で読める確認用。PROMPT_LINE_REAL_HISTORY に history.jsonl のパスを渡したときだけ動く
    @Test func readsRealHistoryWhenGiven() throws {
        guard let path = ProcessInfo.processInfo.environment["PROMPT_LINE_REAL_HISTORY"] else { return }
        let started = Date()
        let store = try HistoryStore(fileURL: URL(fileURLWithPath: path))
        print("real history: \(store.items.count) items, skipped \(store.skippedLines), \(Date().timeIntervalSince(started) * 1000) ms")
        #expect(store.items.count == HistoryStore.searchLimit)
        #expect(store.skippedLines == 0)
    }
}
