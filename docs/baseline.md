# 計測結果

`bench`(`Sources/bench`)で Electron 版と Swift 版を同じ手順で測る。
ホットキーは実キーボードと同じ順で送る(修飾キー押下→キー→解放を `cgSessionEventTap` へ)。HID 層へ直接送ると Carbon のホットキーが反応しない。

```bash
swift build -c release --product bench
bench show --runs 10 --owner "Prompt Line"                                 # Electron 版: Cmd+Shift+Space
bench show --runs 10 --mods ctrl+opt --key 35 --owner "Prompt Line"        # Swift 版(開発中のホットキー ctrl+opt+p)
bench rss                                                                  # Electron 版のRSS合計
bench rss --match "$PWD/build/PromptLine.app"                              # Swift 版のRSS合計
bench e2e --mods ctrl+opt --key 35 --owner "Prompt Line"                   # 貼り付けまでの動作確認
bench cold --app "/Applications/Prompt Line.app" --proc "Prompt Line" --runs 8 --retry-ms 250   # Electron 版の起動(終了→起動を繰り返す)
bench cold --app "$PWD/build/PromptLine.app" --proc PromptLine --runs 8 --retry-ms 100        # Swift 版の起動
```

## 結果(2026-11-01、Apple Silicon、各10回)

| 項目 | Electron 版 | Swift 版 | 備考 |
|---|---|---|---|
| ホットキー→パネル表示(中央値) | 183ms | 51ms | 起点はキー本体の押下 |
| 同(最小〜最大) | 155〜207ms | 45〜61ms | |
| 常駐メモリ(RSS 合計) | 398MB(4プロセス) | 72MB(1プロセス) | Electron 版は 372〜398MB で変動 |
| アプリのサイズ | 287MB | 約0.1MB | |
| 起動→最初のパネル表示(中央値) | 680ms | 320ms | 各8回。`open` の起動時間を含む。ホットキーを再送しながら測る |

Swift 版の表示は、アプリを前面にしない入力パネルを再利用するため、ウィンドウの再生成・履歴の再読込・外部コマンドの起動が無い。
