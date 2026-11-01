import Foundation
import Testing
@testable import PromptLineCore

@Suite struct HistoryItemTests {
    @Test func decodesElectronEraLine() throws {
        let line = #"{"text":"画像の機能","timestamp":1793531027094,"id":"mvxq2dg65coeq91ti","appName":"WezTerm","directory":"/Users/example/project"}"#
        let item = try JSONDecoder().decode(HistoryItem.self, from: Data(line.utf8))
        #expect(item.text == "画像の機能")
        #expect(item.timestamp == 1_793_531_027_094)
        #expect(item.appName == "WezTerm")
        #expect(item.itermSessionId == nil)
    }

    @Test func omitsAbsentOptionalFields() throws {
        let item = HistoryItem(text: "a", timestamp: 1, id: "x")
        let json = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        #expect(!json.contains("directory"))
        #expect(!json.contains("appName"))
    }
}
