# 移植範囲の分類(Electron 版 main → Swift 版)

分類元は main ブランチの `src/handlers/` の `ipcMain.handle` 53本、`UserSettings` のキー、`src/renderer/shortcut-handler.ts` のキー操作。
Swift 版は単一プロセスなので IPC は無く、「残す」は同じ振る舞いをネイティブ実装で再現することを指す。

## 残す(振る舞いを再現する)

| Electron 版のチャネル/操作 | Swift 版での扱い |
|---|---|
| `paste-text` | クリップボードへ書き込み→直前アプリを activate→Cmd+V を送る。貼付後に履歴へ追記し、下書きを消す |
| `show-window` / `hide-window` / `focus-window` | 入力パネルの表示・非表示・フォーカス。パネルは作り直さず再利用する |
| `get-history` / `search-history` | 起動時に直近5,000件をメモリへ読み、Cmd+f で部分一致検索する。5,000件より古い履歴は検索できない(現行と同じ) |
| `get-draft` / `save-draft` / `clear-draft` | 下書きを `draft-swift.json` に自動保存・復元する(並走中は `draft.json` と分離) |
| `window-shown`(main→renderer) | パネル表示のたびに履歴・下書きを入力欄へ反映する |
| Ctrl+j / Ctrl+k | 履歴を古い方/新しい方へ送る。IME の変換中は無効にする |
| Cmd+Enter / Escape | 貼付して閉じる / 貼らずに閉じる(下書きは残す) |
| Cmd+f | 履歴検索の切替。IME の変換中は無効にする |
| Cmd+z | NSTextView 標準の取り消しに任せる |
| Tab | 入力欄へのタブ挿入(Electron 版 `handleTabKey` と同じ挙動か実装時に確認する) |

## 削る(移植しない)

| Electron 版のチャネル/操作 | 理由 |
|---|---|
| `paste-image` | 画像の保存先が空で、履歴に画像パスが0件。使用実績が無い |
| `save-draft-to-history`(Cmd+S) | 下書きを履歴へ手動保存する操作。appName の無い履歴25件は初期の動作確認で、使用実績が読み取れない。要望があれば復活する |
| `clear-history` / `remove-history-item` | 履歴の削除 UI は使う機能に選ばれていない |
| `get-draft-directory` / `set-draft-directory` | cwd の保存。cwd 検出を削る |
| `register-at-path` / `get-registered-at-paths` / `register-global-at-path` / `get-global-at-paths` | `@` ファイル参照。履歴に0件 |
| `record-file-usage` / `record-symbol-usage` / `record-agent-usage` / `get-file-usage-bonuses` / `get-symbol-usage-bonuses` / `get-agent-usage-bonuses` / `get-usage-bonuses` | 検索候補の並び替え用。検索を削る |
| `search-symbols` / `get-cached-symbols` / `clear-symbol-cache` / `check-rg` / `get-supported-languages` | シンボル検索(`@lang:`)。履歴に0件 |
| `get-file-search-max-suggestions` / `get-custom-search-max-suggestions` / `get-custom-search-prefixes` / `get-custom-search-last-change` / `invalidate-custom-search` / `execute-custom-search-command` | ファイル検索・custom-search |
| `get-agent-skills` / `get-agents` / `get-agent-skill-file-path` / `get-agent-file-path` / `has-command-file` / `get-global-agent-skills` / `register-global-agent-skill` | スラッシュコマンド・エージェントスキル。履歴に `/` 始まりが0件 |
| `check-file-exists` / `open-file-in-editor` / `open-external-url` / `reveal-in-finder` | `@` 参照したファイルを開く機能 |
| `execute-shortcut-command` / `customShortcuts` | `input=` / `run=` の独自ショートカット。設定に使用なし |
| `get-config` / `get-app-info` / `open-settings` / `open-settings-directory`(Cmd+, / Shift+Cmd+,) | 設定 YAML を削るため不要 |
| `settings-updated`(main→renderer) | 設定のホットリロードを削る |
| plugin 関連(`PluginManager`・`plugins-changed`) | `plugins` は全コメントアウト |

## 設定キー

| キー | 扱い |
|---|---|
| `shortcuts.main` / `paste` / `close` / `historyNext` / `historyPrev` / `search` | コード内の定数にする(既定値のまま使っている) |
| `window.position` / `width` / `height` | 定数にする(画面中央 / 640 / 220+履歴リスト) |
| `fileOpener` / `commands` / `agents` / `agentBuiltIn` / `agentSkills` / `fileSearch` / `symbolSearch` / `customSearch` / `mentionEnable` / `mentionDisable` / `customShortcuts` / `imagesDirectory` / `plugins` / `additionalPaths` | 削る |

## 起動時の副作用

| Electron 版 | Swift 版 |
|---|---|
| `~/.prompt-line` の作成、`PluginManager.initialize` | `~/.prompt-line` の作成のみ。plugin は削る |
| `settings.yaml` の生成・移行 | 削る(読まない・書かない) |
| `history.jsonl` を `ensureHistoryFile` で作成 | 同じ(無ければ空ファイルを作る。追記以外では書き換えない) |
| `app.dock.hide` + メニューバー項目 | `LSUIElement` + 終了だけのメニューバー項目 |
