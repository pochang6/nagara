# nagara — agent instructions

Mac で AI エージェントのコメントを自分好みの音声で聴くための Player アプリ。
Swift 製のメニューバー常駐アプリ + 薄い入口スクリプト群。

## 最初に読むもの

**`DESIGN.md` を必ず読むこと。** 判断とその理由が書いてある。
そこに書かれた決定を覆す前に、理由を読んでから提案すること。読まずに手を入れると、
すでに片付いた議論をやり直すことになる。特に次の3つは何度も蒸し返されがち。

- これは**スクリーンリーダーではない**。画面は見ない。投げ込まれたテキストだけを読む
- 速度は再生側（`AVAudioUnitTimePitch`）で変える。AivisSpeech の `speedScale` は使わない
- 自動再生の既定は OFF。フックは常に投げるが鳴らさない。これは手抜きではなく設計の中心

## 構成

```
Sources/          メニューバーアプリ本体（swiftc で直接ビルド。SPM は使わない）
  App.swift       Controller と AppDelegate。全体の配線はここ
  Player.swift    再生の中身。文単位の合成・先読み・速度・1文戻る
  Aivis.swift     AivisSpeech Engine への HTTP クライアントと、起動／終了の面倒
  Ingest.swift    127.0.0.1 だけで待つ最小の HTTP サーバー
  Sanitizer.swift Markdown → 読める文へ。文への分割もここ
  Hotkeys.swift   Carbon の RegisterEventHotKey。許可は要らない
  MenuBar.swift   NSStatusItem のメニュー
  History.swift   届いたテキストの控えと、積むかどうかの判断
bin/nagara        CLI（送信と操作）
hooks/            Claude Code の Stop フック
commands/         /speak と /stop
build.sh          ビルド → 署名 → /Applications へ設置 → CLI 設置
install-claude.sh Claude Code 側へフックとコマンドを設置
```

## 触るときの手順

```bash
./build.sh                      # ビルドして設置まで一気に行う
open -g /Applications/nagara.app
curl -sS http://127.0.0.1:17371/status
tail -f ~/Library/Logs/nagara.log
```

- `build.sh` は署名の証明書を自動で探す。無ければ作り方を案内して止まる
- 設置先は必ず `/Applications`。パスが動くとログイン項目とサービス登録が迷子になる
- 既存プロセスは `build.sh` が落としてから入れ替える

## 動作確認のしかた

**音は聞こえない。** 鳴っているかどうかは、状態の遷移とログで確かめること。

```bash
nagara "検証用の文章です。二文目です。三文目です。"
nagara play
curl -sS http://127.0.0.1:17371/status   # sentence が進んでいくか
```

`state` が `playing` → `idle` へ移り、`sentence` が増えていけば、合成と再生は動いている。
**「いい感じに聞こえるか」の最終判断は本人にしかできない。** そこは必ず本人に委ねること。

フックの検証は、実際の応答を待たずに手で叩ける。

```bash
T=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
printf '{"transcript_path":"%s"}' "$T" | ~/.claude/hooks/nagara-stop-hook.sh
```

## 書きかた

- コメントは日本語。**何をしているか**ではなく**なぜそうしたか**を書く
- 決定の理由が長くなるものは `DESIGN.md` へ回し、コードからはそちらを指す
- 既存の日本語 UI 文言の調子に合わせる。過度に丁寧にも、ぶっきらぼうにもしない

## やらないこと

- Git の初期化や公開を勝手にやらない。公開は `/publish` スキルの担当
- 音声モデルをリポジトリに同梱しない。ライセンスが別物（`DESIGN.md` 10節）
- 画面を読む方向の機能（OCR・アクセシビリティ巡回）を足さない
