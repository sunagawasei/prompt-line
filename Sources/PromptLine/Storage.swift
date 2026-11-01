import Foundation

/// 起動引数(`--name value`)を優先し、無ければ環境変数から読む。テストが専用のインスタンスを立てるときに使う。
func option(_ name: String, env: String) -> String? {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count { return args[i + 1] }
    return ProcessInfo.processInfo.environment[env]
}

/// データの置き場。Electron 版と同じ ~/.prompt-line を既定にし、テストでは差し替える。
enum Storage {
    static var directory: URL {
        if let path = option("data-dir", env: "PROMPT_LINE_DATA_DIR") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".prompt-line", isDirectory: true)
    }

    /// Electron 版と共有する(追記のみなので衝突しない)
    static var historyFile: URL { directory.appendingPathComponent("history.jsonl") }
    /// Electron 版の draft.json とは別ファイル。並走中に互いの下書きを上書き・削除しない
    static var draftFile: URL { directory.appendingPathComponent("draft-swift.json") }
}
