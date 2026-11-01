import Foundation
import Testing
@testable import PromptLineCore

private func tempDraftURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("pl-\(UUID().uuidString)/draft-swift.json")
}

@Suite struct DraftStoreTests {
    @Test func saveThenLoadRoundTrips() throws {
        let store = DraftStore(fileURL: tempDraftURL())
        #expect(try store.save(text: "書きかけ\n二行目", scrollTop: 12, now: Date(timeIntervalSince1970: 5)))
        #expect(store.load() == Draft(text: "書きかけ\n二行目", scrollTop: 12, timestamp: 5000))
    }

    @Test func fileIsOwnerOnly() throws {
        let url = tempDraftURL()
        try DraftStore(fileURL: url).save(text: "x")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func savingEmptyTextRemovesTheDraft() throws {
        let store = DraftStore(fileURL: tempDraftURL())
        try store.save(text: "x")
        #expect(try store.save(text: "") == false)
        #expect(store.load() == nil)
    }

    @Test func clearRemovesTheFile() throws {
        let url = tempDraftURL()
        let store = DraftStore(fileURL: url)
        try store.save(text: "x")
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func oversizedDraftIsNotSaved() throws {
        let store = DraftStore(fileURL: tempDraftURL())
        #expect(try store.save(text: String(repeating: "a", count: DraftStore.maxBytes)) == false)
        #expect(store.load() == nil)
    }

    @Test func readsElectronFormat() throws {
        let url = tempDraftURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"text":"あ","scrollTop":0,"timestamp":1793531027094,"version":"1.0"}"#.utf8).write(to: url)
        #expect(DraftStore(fileURL: url).load()?.text == "あ")
    }

    @Test func brokenFileLoadsAsNil() throws {
        let url = tempDraftURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: url)
        #expect(DraftStore(fileURL: url).load() == nil)
    }
}
