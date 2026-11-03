# Prompt Line

ホットキーで開く入力パネルに文章を書き、Cmd+Enter で直前に使っていたアプリへ貼り付ける macOS 常駐アプリ。
日本語入力を前提に、Swift のネイティブ単一プロセスで作っている(macOS 14 以上)。

[nkmr-jp/prompt-line](https://github.com/nkmr-jp/prompt-line)(Electron 版)の fork で、個人用に Swift で書き直した。
上流とは独立して作っており、上流への変更提案は出さない。ライセンスは上流と同じ([LICENSE](LICENSE))。

## 操作

| キー | 動作 |
|---|---|
| Cmd+Shift+Space / Cmd+Shift+P | パネルを開く・閉じる |
| Cmd+Enter | 貼り付け先のアプリへ貼り付けて閉じる |
| Esc | 閉じる(下書きは残る) |
| Ctrl+j / Ctrl+k | 履歴を古い方・新しい方へ送る |
| Cmd+f | 履歴を検索する(スペース区切りで絞り込み。Enter で確定、Esc で取消) |

下書きは自動で保存され、貼り付けたときだけ消える。履歴は直近 5,000 件を検索・送りの対象にする。

## ビルドと実行

```bash
swift test                    # コアのテスト
./scripts/build-app.sh        # build/PromptLine.app を作る
open build/PromptLine.app
```

貼り付けのキー送信にアクセシビリティの許可が要る。`build-app.sh` は、キーチェーンに "Prompt Line" という名前のコード署名証明書があればそれで署名する。
同じ証明書で署名し続けると、作り直しても許可が残る。無ければアドホック署名になり、作り直すたびに許可し直す。

起動時の引数(テスト用): `--hotkey ctrl+opt+p,...` でホットキーを差し替え、`--data-dir <dir>` でデータの置き場を差し替える。

## データ

`~/.prompt-line/` に置く。

- `history.jsonl`: 履歴。1 行 1 件の JSON で、追記だけを行う(Electron 版と同じ形式)。
- `draft-swift.json`: 下書き。

どちらも所有者だけが読める権限(0600)で作る。

## 計測とテスト

`Sources/bench` は、表示時間・メモリ・貼り付けまでの動作を実機で測る補助ツール(アプリには含まれない)。使い方と結果は [docs/baseline.md](docs/baseline.md)、既知の制約は [docs/known-issues.md](docs/known-issues.md)。

```bash
swift build -c release --product bench
.build/release/bench e2e --app "$PWD/build/PromptLine.app"          # 貼り付け・履歴の追記
.build/release/bench e2e-draft --app "$PWD/build/PromptLine.app"    # 下書き
.build/release/bench e2e-history --app "$PWD/build/PromptLine.app"  # 履歴送り
.build/release/bench e2e-search --app "$PWD/build/PromptLine.app"   # 検索
```

専用のデータ置き場とホットキー(Ctrl+Opt+P)で自前のインスタンスを起動するので、使っているアプリには触れない。
キーは実機の入力経路で送るため、実行中(数十秒)にキーボードやマウスに触れると入力が混ざって失敗する。実行のたびに通知を出すので、通知が出ている間は触らない。
