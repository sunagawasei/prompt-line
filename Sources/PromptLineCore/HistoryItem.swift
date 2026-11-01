import Foundation

/// history.jsonl の 1 行。Electron 版が書いた既存の履歴と同じ形式で読み書きする。
public struct HistoryItem: Codable, Equatable, Sendable {
    public var text: String
    public var timestamp: Int64
    public var id: String
    public var appName: String?
    public var directory: String?
    public var itermSessionId: String?

    public init(
        text: String,
        timestamp: Int64,
        id: String,
        appName: String? = nil,
        directory: String? = nil,
        itermSessionId: String? = nil
    ) {
        self.text = text
        self.timestamp = timestamp
        self.id = id
        self.appName = appName
        self.directory = directory
        self.itermSessionId = itermSessionId
    }

    /// history.jsonl の 1 行(改行なし)。Electron 版と同じキー順
    /// (text, timestamp, id, appName, directory, itermSessionId)で、スラッシュはエスケープしない。
    /// JSONEncoder はキー順を保証しないので、値ごとに符号化して並べる。
    public func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func string(_ value: String) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }

        var parts = [
            "\"text\":" + (try string(text)),
            "\"timestamp\":\(timestamp)",
            "\"id\":" + (try string(id)),
        ]
        if let appName { parts.append("\"appName\":" + (try string(appName))) }
        if let directory { parts.append("\"directory\":" + (try string(directory))) }
        if let itermSessionId { parts.append("\"itermSessionId\":" + (try string(itermSessionId))) }
        return Data(("{" + parts.joined(separator: ",") + "}").utf8)
    }
}
