import Darwin
import Foundation

/// Electron 版の draft.json と同じ形式の下書き。並走中は別ファイル(draft-swift.json)へ書く。
public struct Draft: Codable, Equatable {
    public var text: String
    public var scrollTop: Double
    public var timestamp: Int64
    public var version: String

    public init(text: String, scrollTop: Double = 0, timestamp: Int64, version: String = "1.0") {
        self.text = text
        self.scrollTop = scrollTop
        self.timestamp = timestamp
        self.version = version
    }
}

public final class DraftStore {
    /// Electron 版と同じ上限。超える下書きは保存しない
    public static let maxBytes = 1_000_000

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 読めない・壊れている場合は nil
    public func load() -> Draft? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Draft.self, from: data)
    }

    /// 空の本文は下書きとして残さない。保存したら true
    @discardableResult
    public func save(text: String, scrollTop: Double = 0, now: Date = Date()) throws -> Bool {
        guard !text.isEmpty else {
            clear()
            return false
        }
        let draft = Draft(text: text, scrollTop: scrollTop, timestamp: Int64(now.timeIntervalSince1970 * 1000))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(draft)
        guard data.count <= Self.maxBytes else { return false }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // 0600 で作った temp を rename する。書いた後に chmod すると、その間だけ他ユーザーから読める
        let temp = fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, fileURL.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(code)
        }
        return true
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
