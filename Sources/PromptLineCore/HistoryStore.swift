import Darwin
import Foundation

/// history.jsonl の読み書き。Electron 版と同じ形式で、追記だけを行う(既存の行は書き換えない)。
/// 並走中の Electron 版と同じファイルを共有するため、1 行を 1 回の write(2) で追記する。
public final class HistoryStore {
    /// 検索・送りの対象にする直近件数(Electron 版の LIMITS.MAX_SEARCH_ITEMS と同じ)
    public static let searchLimit = 5000

    /// 新しい順
    public private(set) var items: [HistoryItem] = []
    /// 読み込み時に JSON として読めず捨てた行の数
    public private(set) var skippedLines = 0

    private let fileURL: URL
    private let limit: Int

    public init(fileURL: URL, limit: Int = HistoryStore.searchLimit, chunkSize: Int = 64 * 1024) throws {
        self.fileURL = fileURL
        self.limit = limit
        try Self.ensureFile(fileURL)

        let decoder = JSONDecoder()
        var loaded: [HistoryItem] = []
        for line in try Self.readLastLines(of: fileURL, count: limit, chunkSize: chunkSize) {
            if let item = try? decoder.decode(HistoryItem.self, from: line) {
                loaded.append(item)
            } else {
                skippedLines += 1
            }
        }
        items = loaded.reversed()
    }

    /// 履歴へ追加する。空文字は nil。直前と同じ本文なら時刻とアプリ名だけを更新し、ファイルには書かない
    /// (Electron 版と同じ)。
    @discardableResult
    public func add(text: String, appName: String? = nil, now: Date = Date()) throws -> HistoryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let timestamp = Int64(now.timeIntervalSince1970 * 1000)

        if var latest = items.first, latest.text == trimmed {
            latest.timestamp = timestamp
            if let appName { latest.appName = appName }
            items[0] = latest
            return latest
        }

        let item = HistoryItem(text: trimmed, timestamp: timestamp, id: Self.makeID(), appName: appName)
        try append(item)
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast() }
        return item
    }

    // MARK: - ファイル

    private static func ensureFile(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // 確認と作成の間に Electron 版が作って追記しても切り詰めないよう、createFile(contents: nil) ではなく
            // O_APPEND で開く(O_TRUNC を付けない)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(fd)
        }
    }

    private func append(_ item: HistoryItem) throws {
        var bytes = try item.jsonLine()
        bytes.append(0x0A)
        // 最終行が改行で終わっていないと、追記した行が前の行に連結してしまう
        if try Self.endsWithoutNewline(fileURL) { bytes.insert(0x0A, at: 0) }

        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func endsWithoutNewline(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return false }
        try handle.seek(toOffset: size - 1)
        return try handle.read(upToCount: 1)?.first != 0x0A
    }

    /// ファイルの末尾から後ろ向きに読み、最後の count 行を古い順で返す(全体を読まない)
    static func readLastLines(of url: URL, count: Int, chunkSize: Int) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        var buffer = Data()
        var newlines = 0

        // 先頭の行は途中で切れているかもしれないので、count + 1 個の改行が揃うまで読む
        while offset > 0 && newlines <= count {
            let step = UInt64(min(chunkSize, Int(offset)))
            offset -= step
            try handle.seek(toOffset: offset)
            let chunk = try handle.read(upToCount: Int(step)) ?? Data()
            newlines += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            buffer = chunk + buffer
        }

        var lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        // 先頭まで届いていなければ、最初の行は途中から始まっているので捨てる
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.suffix(count))
    }

    private static func makeID() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<17).map { _ in alphabet.randomElement()! })
    }
}
