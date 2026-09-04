# nagara

**Mac で、聴きたいものを自分好みの音声で聴くための Player アプリ。**

AI エージェントの応答も、ブラウザの記事も、小説も。
コピーするか、投げ込むだけ。「ながら聞き」の *ながら* から名前を取りました。

> **English follows Japanese.** — [English version](#nagara-english) is below.

```
nagara は画面を読みません。投げ込まれたテキストだけを読みます。
```

---

## なぜ作ったか

**① AI エージェントの長い応答を、読むのではなく聴きたかった**

Claude Code の読み上げは、長くなると早口になり、声も選べません。
**Codex にはそもそも音声再生がありません**（2026年9月時点。ChatGPT にはあります）。

**② 世の中の読み上げは、いかにも「AI の自動読み上げ」で味気ない**

ブラウザにも読み上げ機能はあります。ただ、あの声でニュースを聞き流す気にはなれません。
**ブラウザで読める小説を Audible のように聴く**こともできるはずなのに、声がそれを台無しにします。

聴きたいものは AI の応答だけではありません。**何でも、自分の好きな声で聴きたい。**

**③ 既存のツールは「鳴らす」だけで、プレイヤーになっていない**

Claude Code × 読み上げのツールはいくつもありますが、どれも
「応答が終わったら鳴らす」で終わりです。**止める・戻す・速度を変える**がありません。
長文を流し聞きするのに要るのは、通知ではなく**プレイヤー**でした。

**④ 溜まっていてほしい**

そして使ってみて一番効いたのが、AI エージェントの応答が**自動でキューに溜まる**ことでした。
鳴りはしません。「これは聴きたい」と思った時点で、それはもう手元にあります。

---

## できること / しないこと

### やること

- 好きな音声モデルで読む（AivisSpeech / VOICEVOX のモデルなら何でも）
- 再生・一時停止・停止・**1文単位で戻る／進む**・速度の上げ下げ
- AI エージェントの応答を溜めておき、**聴きたくなったときに再生する**
- 選択したテキストや、クリップボードの中身を読む

### やらないこと

- 画面のスキャン、OCR、アクセシビリティツリーの巡回。**スクリーンリーダーではありません**
- 音声認識・対話。喋りかける側は [nobetsu](https://github.com/pochang6/nobetsu) の担当です
- 音声合成そのもの。AivisSpeech に HTTP で頼むだけで、同梱もリンクもしません

読むのは**明示的に渡されたテキストだけ**です。メニューバーやボタンのラベルが
勝手に読み上げられることはありません。

**macOS の許可（入力監視・アクセシビリティ）は一切要りません。**

---

## 3分で使い始める

**1. AivisSpeech を入れる**（未導入なら）

[AivisSpeech](https://aivis-project.com/) をインストールし、好きな音声モデルを1つ以上入れます。
**起動しっぱなしにする必要はありません。** nagara が必要なときに裏で起こします。

**2. ビルドして設置する**

```bash
./build.sh
open /Applications/nagara.app
```

コード署名の証明書を自動で探します。無ければ作り方を案内して止まります（1回だけの作業です）。

**3. Claude Code と繋ぐ**（AI エージェント連携が要らなければ省略可）

```bash
./install-claude.sh
```

Stop フックと `/speak` `/stop` が入ります。登録先は `~/.claude/settings.json` なので、
**ターミナル版でもデスクトップ版でも同じように効きます。**

**4. 声を選ぶ**

メニューバーの吹き出しアイコン → **声** から選びます。
一覧は AivisSpeech に問い合わせて作るので、モデルを足せば勝手に増えます。

**5. 聴く**

何か文章をコピーして `⌃⌥C`。それだけで読み始めます。

---

## ショートカット

| 操作 | キー |
|---|---|
| 再生 / 一時停止 | `⌃⌥P` |
| 速く（1段） | `⌃⌥→` |
| 遅く（1段） | `⌃⌥←` |
| 1文戻る | `⌃⌥↑` |
| 1文進む | `⌃⌥↓` |
| 大きく（1段） | `⌃⌥=` |
| 小さく（1段） | `⌃⌥-` |
| 停止 | `⌃⌥.` |
| クリップボードを読む | `⌃⌥C` |

`⌃` は Control、`⌥` は Option です。矢印は**左右が速さ、上下が文の移動**、
`=` `-` が音量。速度も音量も1段ずつ動き、端では止まります（一周しません）。

**覚えるのは `⌃⌥P` と `⌃⌥C` の2つで足ります。** 残りはメニューの右側に出ています。

> `⌥⌘→` / `⌥⌘←` を使っていないのは、Chrome・Safari・VS Code が
> 「次のタブ／前のタブ」に既定で割り当てているからです。
> グローバルに奪うと、全アプリでタブ切り替えが壊れます。

---

## 3つの入口

nagara 本体は1つで、テキストの出どころを知りません。入口は薄いスクリプトです。

### ① AI エージェントの応答（自動）

応答が終わるたび、その本文が nagara へ渡ります。**鳴りません。**
メニューバーのアイコンに未再生の件数が付くだけです。

**仕組みは Claude Code の Stop フックです。** スキルでもルールでもありません。
`~/.claude/settings.json` の `hooks.Stop` に登録したシェルスクリプトが、
**会話ログ（JSONL）から直前の応答本文だけを取り出して** nagara に POST します。
ターミナルの表示を拾うわけではないので、プロンプト記号も進捗表示もツールの出力も混ざりません。

`./install-claude.sh` がこの登録を代行します。`--uninstall` で外せます。

### ② CLI

```bash
nagara "読ませたい文章"      # 積むだけ（鳴らない）
echo "..." | nagara          # 標準入力から
nagara --now "すぐ読んで"     # 積んですぐ鳴らす

nagara play | pause | toggle | stop | back | next
nagara clipboard             # クリップボードの中身を読む
nagara rate                  # 1段速く
nagara rate 1.25             # 速度を指定する
nagara volume                # 1段大きく
nagara volume 0.6            # 音量を指定する（0.0〜1.0）
nagara status                # いまの状態
```

テキストを吐けるものなら何でも繋がります。cron でも自作スクリプトでも。

### ③ 選択したテキスト

**`⌘C` でコピー → `⌃⌥C`。** これが確実で、**どのアプリでも効きます**。
ブラウザの記事も、PDF も、メールも、これで聴けます。

右クリック →「**nagara で読む**」（macOS のサービス）もありますが、
**出てこないアプリがあります。** Electron 製のアプリ（Claude Code のデスクトップ版もそう）は
コンテキストメニューを自前で描いていて、macOS のサービスを載せません。
Safari・Mail・メモ・テキストエディットのような素の AppKit のテキスト欄なら出ます。

### スラッシュコマンド

- `/speak` — 直前の応答を読む
- `/stop` — 止める

`~/.claude/commands/*.md` に置かれるカスタムコマンドです。
ただし打っている間も喋り続けるので、**実用上は `⌃⌥.` のほうが速い**です。

---

## メニューバー

アイコンで状態が分かります。吹き出しを基本形にしているのは、
[nobetsu](https://github.com/pochang6/nobetsu) の波形アイコンと並んだときに見分けるためです。

| 見た目 | 状態 |
|---|---|
| 吹き出し（線） | 待機中。何も届いていない |
| 吹き出し（塗り）+ 数字 | 未再生あり。届いているが鳴っていない |
| スピーカー | 再生中 |
| 一時停止マーク | 一時停止中 |

```
未再生 3 件
─────────────────────────
最新を再生 / 一時停止        ⌃⌥P
停止                        ⌃⌥.
1文戻る                     ⌃⌥↑
1文進む                     ⌃⌥↓
─────────────────────────
クリップボードを読む          ⌃⌥C
─────────────────────────
速度 ▸ 速く ⌃⌥→ / 遅く ⌃⌥← / 1.0 … 1.5
音量 ▸ 大きく ⌃⌥= / 小さく ⌃⌥- / 20% … 100%
声   ▸ まい / コハク ▸ … / まお ▸ …
□ 自動再生
─────────────────────────
履歴 ▸ 直近15件（クリックで再生）
─────────────────────────
AivisSpeech ▸ 状態 / 起動・終了 / 使い終わったら…
─────────────────────────
☑ ログイン時に起動
設定ファイルを開く / ログを開く
nagara を終了
```

**自動再生は既定 OFF** です。応答のたびに喋られると邪魔なので、
「**届いてはいるが鳴っていない**」が通常の状態になります。

再生中に新しいものを再生すると、**新しいほうが優先されて読み替わります。**

---

## 常に使える状態にしておく

三重にしてあります。

1. **ログイン項目に登録**されるので、Mac を再起動しても勝手に常駐します
   （初回起動時に自動登録。メニューから外せます）
2. **CLI が本体を起こします。** `nagara ...` を叩いたとき落ちていれば起動します
3. **Stop フックも本体を起こします。** ただし待つのは**3秒まで**。
   フックが理由で AI エージェントが待たされるのは本末転倒なので、そこで諦めます

いま常駐しているかは `nagara status` の `loginItem` と `version` で分かります。

---

## AivisSpeech の扱い

必要になった時点で `open -g -j` で裏起動し、モデルの読み込みを待ちます（十数秒）。

- **一度起きたエンジンは置いておきます**（連続で使う日に毎回待たされないため）
- ただし **15分使われなければ静かに落とします**（一度きりの日に居座らないため）
  - 「15分」は**最後に1文を合成してから**の時間です。使うたびにゼロへ戻ります
  - 再生中・一時停止中は数えません
- **手で閉じたら追いかけません**（次に必要になったときだけ、また起こします）
- 落とすのは**自分で起こしたエンジンだけ**。あなたが手で開いたものには触りません
  - この印は pid でファイルに残るので、nagara を再起動しても引き継がれます
- **あなたが AivisSpeech を使い始めたら、そこで手を引きます**

nagara はエンジンを隠して起こすので、**窓が開いた／前面に出た**なら、それはあなたが
自分で使い始めた合図です。以後そのエンジンは nagara の持ち物ではなくなり、
15分たっても落としません。**これは片道で、取り返しません。**
読み上げのついでに AivisSpeech で作業を始めたのに、その最中に落とされる、を防ぐためです。

> 裏を返すと、**一度でも窓を開けたエンジンは自動では消えなくなります。**
> 「見えている＝作業中」と決めつけているためで、AivisSpeech 側に
> 「いま誰が使っているか」を返す API が無い以上、ここは代理指標に頼るしかありません。
> 外れる方向を「落とさない」側に倒した、という妥協です。
> 消したいときはメニューの「いま終了する」を使ってください。

メニューから「起動したままにする」「nagara の終了時に閉じる」にも変えられます。

> **既知の制約**: AivisSpeech は Electron 製で、起動時に自分でウィンドウを前面へ出します。
> nagara は見つけ次第 hide し続けますが、**一瞬ちらつくのは避けられません**。
> 完全に消すには GUI を持たない AivisSpeech-Engine 単体版に差し替える必要があります。

---

## 設定

`~/Library/Application Support/nagara/settings.json`

| 項目 | 既定 | 意味 |
|---|---|---|
| `speakerId` | `1431611904` | 話者のスタイル ID（まい / ノーマル） |
| `rate` | `1.0` | いまの再生速度。**そのまま次回の既定になります** |
| `rateLadder` | `[1.0 … 1.5]` | `⌃⌥→` `⌃⌥←` で1段ずつ動く段階 |
| `volume` | `0.8` | いまの音量。**そのまま次回の既定になります** |
| `volumeLadder` | `[0.2 … 1.0]` | `⌃⌥=` `⌃⌥-` で1段ずつ動く段階 |
| `autoPlay` | `false` | 届いた端から鳴らすか |
| `port` | `17371` | 受け口。`127.0.0.1` にしか bind しません |
| `engineURL` | `http://127.0.0.1:10101` | VOICEVOX なら `:50021` |
| `engineIdleQuitMinutes` | `15` | 使われないエンジンを閉じるまでの分数（`0` で閉じない） |
| `quitEngineOnExit` | `true` | nagara の終了時にエンジンも閉じるか |
| `hideEngineOnLaunch` | `true` | 起動してきたエンジンを押し戻すか |
| `skipCodeBlocks` | `true` | コードブロックを読み飛ばす |
| `minimumLength` | `12` | これより短い応答は積まない |
| `historyLimit` | `30` | 履歴に残す件数 |

**速度は 1.0〜1.5 の範囲だけ**にしてあります。それより遅くすると、
時間を引き伸ばす処理の都合で音が濁り、聞けたものではなくなるためです。
試したい場合は `rateLadder` に手で足せば出ます。

ログは `~/Library/Logs/nagara.log` です。

---

## 困ったとき

**まずログを見てください。** 押したホットキーは必ず記録されます。

```bash
tail -f ~/Library/Logs/nagara.log
```

| 症状 | 見るところ |
|---|---|
| ショートカットが効かない | `hotkey: …` が出るか。**出ないならキーが届いていない**（他のアプリに取られている） |
| 押すと動くのに音が出ない | `player: N文を読み込んだ` の後が続いているか。エンジン側の問題かもしれません |
| 何も溜まらない | `history: 受け取った …` が出るか。出ないならフックが動いていません |
| 右クリックに出てこない | そのアプリが Electron 製かもしれません。`⌘C` → `⌃⌥C` を使ってください |
| 操作応答（「再生を始めました」）が読み上げられる | `~/.claude/commands/speak.md` の `nagara:internal` の印が消えていないか |

本体が動いているかは `nagara status`、エンジンが応答しているかは
`curl -s http://127.0.0.1:10101/version` で分かります。

---

## いま出来ていないこと

- 任意の位置へのシーク（動けるのは1文ずつ）
- メディアキー・コントロールセンターからの操作（Now Playing 未対応）
- **Codex 連携**（CLI と `⌃⌥C` では今でも使えます）
- アバター表示

Codex については目処が立っています。Codex には `~/.codex/config.toml` の
`notify` があり、ターン終了時に外部プログラムを呼びます。その通知
（`agent-turn-complete`）には **`last-assistant-message` が含まれている**ので、
会話ログを解析するまでもなく本文が取れます。
さらに Codex 側にも `Stop` を含むフック機構があり、Claude Code とよく似た形をしています。
実装していないだけで、原理的な障害はありません。

設計の判断とその理由は [DESIGN.md](DESIGN.md) に書いてあります。
手を入れる前にそちらを読んでください。

---

## ライセンスと免責

**MIT License**（[LICENSE](LICENSE)）。個人・商用を問わず自由に使えます。
改変も再配布も歓迎します。ただし**無保証**です。
このソフトウェアの使用によって生じたいかなる損害についても、作者は責任を負いません。

nagara は AivisSpeech を**同梱もリンクもせず、別プロセスに HTTP で話しかけるだけ**です。
AivisSpeech Engine 本体は LGPL-3.0 ですが、クレジット表記は不要とされています。

**注意していただきたいのは音声モデルのほうです。** エンジンのライセンスとモデルのライセンスは
別物で、AivisHub のモデルは ACML / ACML-NC / CC0 などモデルごとに条件が違います
（`-NC` は非商用限定）。**利用するモデルの規約は各自でご確認ください。**
デモ動画や記事に音声を載せる場合は特に効いてきます。

このリポジトリのデモで使っている音声: **AivisSpeech まい / ノーマル 利用**

---
---

<a id="nagara-english"></a>

# nagara (English)

**A player app for macOS that reads anything aloud in a voice you actually chose.**

AI agent responses, web articles, novels — copy it, or pipe it in.
The name comes from *nagara-giki* (ながら聞き), Japanese for listening while doing something else.

```
nagara never reads your screen. It only reads text you hand it.
```

> **Note on language.** nagara is built around Japanese speech synthesis engines
> (AivisSpeech / VOICEVOX), so its user interface is in Japanese and it reads Japanese best.
> It will happily read text in other languages, but the voice models are Japanese ones.

---

## Why this exists

**1. I wanted to listen to long AI agent responses, not read them**

Claude Code's built-in narration speeds up as the text gets longer, and you cannot choose the voice.
**Codex has no audio playback at all** (as of September 2026; ChatGPT does).

**2. Every built-in reader sounds unmistakably like a robot**

Browsers have read-aloud features. But nobody wants to listen to the news in that voice.
**You should be able to listen to a novel in your browser the way you'd listen on Audible** —
except the voice ruins it.

And it isn't only AI output I want to hear. **I want to hear anything, in a voice I picked.**

**3. Existing tools just play. They aren't players**

There are several Claude Code text-to-speech tools. All of them stop at
"when the response finishes, make a sound." None of them let you
**stop, rewind, or change the speed.** For listening to long text in the background,
what you need is not a notification — it's a **player**.

**4. It should pile up quietly**

The thing that turned out to matter most: agent responses **queue up automatically**.
They don't play. By the time you think "I want to hear that one," it's already waiting for you.

---

## What it does / doesn't do

### Does

- Reads with any voice model you like (anything AivisSpeech or VOICEVOX can load)
- Play, pause, stop, **step back / forward one sentence**, adjust speed
- Queues agent responses and plays them **when you decide to listen**
- Reads selected text or your clipboard

### Doesn't

- Scan the screen, run OCR, or walk the accessibility tree. **This is not a screen reader**
- Speech recognition or conversation. For talking *to* your machine, see [nobetsu](https://github.com/pochang6/nobetsu)
- Speech synthesis itself. It asks AivisSpeech over HTTP; nothing is bundled or linked

It reads **only text explicitly handed to it**. Your menu bar and button labels
will never be read aloud.

**No macOS permissions are required** (no Input Monitoring, no Accessibility).

---

## Up and running in three minutes

**1. Install AivisSpeech** (if you don't have it)

Install [AivisSpeech](https://aivis-project.com/) and add at least one voice model.
**You do not need to keep it running** — nagara launches it in the background when needed.

**2. Build and install**

```bash
./build.sh
open /Applications/nagara.app
```

It looks for a code-signing certificate automatically. If there isn't one,
it stops and tells you how to make one (a one-time task).

**3. Connect it to Claude Code** (skip this if you don't need agent integration)

```bash
./install-claude.sh
```

This installs the Stop hook plus `/speak` and `/stop`. It registers in
`~/.claude/settings.json`, so it works **identically in the terminal and desktop versions**.

**4. Pick a voice**

Click the speech-bubble icon in the menu bar → **声** (Voice).
The list is fetched from AivisSpeech, so new models appear on their own.

**5. Listen**

Copy any text and press `⌃⌥C`. That's it.

---

## Shortcuts

| Action | Key |
|---|---|
| Play / pause | `⌃⌥P` |
| Faster (one step) | `⌃⌥→` |
| Slower (one step) | `⌃⌥←` |
| Back one sentence | `⌃⌥↑` |
| Forward one sentence | `⌃⌥↓` |
| Louder (one step) | `⌃⌥=` |
| Quieter (one step) | `⌃⌥-` |
| Stop | `⌃⌥.` |
| Read the clipboard | `⌃⌥C` |

`⌃` is Control, `⌥` is Option. **Left/right is speed, up/down moves through sentences,
`=` / `-` is volume.** Both speed and volume move one step at a time and stop at the
ends — they do not wrap around.

**You only need to remember two: `⌃⌥P` and `⌃⌥C`.** The rest are shown in the menu.

> `⌥⌘→` / `⌥⌘←` are deliberately avoided: Chrome, Safari and VS Code bind them to
> next/previous tab. Claiming them globally breaks tab switching everywhere.

---

## Three ways in

There is exactly one app, and it doesn't know where text comes from.
The entry points are thin scripts.

### 1. Agent responses (automatic)

Every time a response finishes, its body is handed to nagara. **Nothing plays.**
The menu bar icon just shows how many are waiting.

**The mechanism is Claude Code's Stop hook** — not a skill, not a rule file.
A shell script registered under `hooks.Stop` in `~/.claude/settings.json`
**pulls the last assistant message out of the conversation log (JSONL)** and POSTs it.
It does not scrape the terminal, so prompts, progress lines and tool output never leak in.

`./install-claude.sh` does the registration for you; `--uninstall` removes it.

### 2. CLI

```bash
nagara "text to read"        # queue it (silent)
echo "..." | nagara          # from stdin
nagara --now "read this now" # queue and play immediately

nagara play | pause | toggle | stop | back | next
nagara clipboard             # read the clipboard
nagara rate                  # one step faster
nagara rate 1.25             # set the speed
nagara volume                # one step louder
nagara volume 0.6            # set the volume (0.0-1.0)
nagara status                # current state
```

Anything that can emit text can drive it — cron jobs, your own scripts, anything.

### 3. Selected text

**`⌘C` then `⌃⌥C`.** This is the reliable path and **works in every app** —
web articles, PDFs, mail.

There is also a right-click → **"nagara で読む"** macOS Service, but
**it won't appear in some apps.** Electron apps (including the Claude Code desktop app)
draw their own context menus and don't include macOS Services.
Native AppKit text views — Safari, Mail, Notes, TextEdit — do show it.

### Slash commands

- `/speak` — read the last response
- `/stop` — stop

These are custom commands in `~/.claude/commands/*.md`. Note that it keeps talking
while you type, so **`⌃⌥.` is faster in practice**.

---

## Menu bar

The icon tells you the state. It's a speech bubble rather than a waveform so that it
stays distinguishable next to [nobetsu](https://github.com/pochang6/nobetsu).

| Icon | State |
|---|---|
| Speech bubble (outline) | Idle, nothing received |
| Speech bubble (filled) + number | Items waiting, not playing |
| Speaker | Playing |
| Pause symbol | Paused |

```
未再生 3 件  (3 waiting)
─────────────────────────
Play latest / Pause          ⌃⌥P
Stop                         ⌃⌥.
Back one sentence            ⌃⌥↑
Forward one sentence         ⌃⌥↓
─────────────────────────
Read the clipboard           ⌃⌥C
─────────────────────────
Speed  ▸ Faster ⌃⌥→ / Slower ⌃⌥← / 1.0 … 1.5
Volume ▸ Louder ⌃⌥= / Quieter ⌃⌥- / 20% … 100%
Voice  ▸ まい / コハク ▸ … / まお ▸ …
□ Auto-play
─────────────────────────
History ▸ last 15 (click to play)
─────────────────────────
AivisSpeech ▸ status / launch / quit / when done…
─────────────────────────
☑ Launch at login
Open settings file / Open log
Quit nagara
```

**Auto-play is off by default.** Being talked at after every response is annoying,
so "**received but silent**" is the normal state.

Playing something new while audio is running **switches to the new item**.

---

## Staying available

Three layers.

1. **Registered as a login item**, so it comes back after a reboot
   (registered on first launch; you can turn it off from the menu)
2. **The CLI starts it.** If `nagara ...` finds it down, it launches it
3. **The Stop hook starts it too** — but waits **at most three seconds**.
   An agent waiting on a hook is worse than a missed queue entry, so it gives up

`nagara status` reports `loginItem` and `version` so you can check.

---

## How AivisSpeech is handled

When it's needed, nagara launches it with `open -g -j` and waits for the models to load
(ten-odd seconds).

- **Once running, it stays running** (so you don't wait again on a busy day)
- But it is **quietly quit after 15 idle minutes** (so it doesn't squat all day)
  - "15 minutes" counts from the **last sentence synthesized**, and resets on every use
  - It never counts while playback is running or paused
- **If you quit it by hand, nagara doesn't fight you** — it just starts it again next time
- Only the engine **nagara itself started** is ever quit. One you opened is left alone
  - That claim is stored on disk by pid, so it survives a restart of nagara
- **The moment you start using AivisSpeech yourself, nagara lets go**

nagara launches the engine hidden, so a **window appearing or the app coming to the front**
means you have started using it. From then on nagara no longer owns that engine and will
not quit it, however idle it goes. **This is one-way — nagara never takes it back.**
It exists so the engine can't be pulled out from under you while you work in it.

> The flip side: **an engine whose window you once opened will never auto-quit again.**
> "Visible means in use" is an assumption, but AivisSpeech exposes no API for who is
> using it, so a proxy is all there is. The error is deliberately biased toward not
> quitting. Use "quit now" in the menu when you do want it gone.

The menu offers "keep running" and "quit when nagara quits" instead.

> **Known limitation**: AivisSpeech is an Electron app and brings its own window to the front
> on launch. nagara hides it as soon as it appears, but **a brief flash is unavoidable**.
> Removing it entirely requires the headless AivisSpeech-Engine distribution.

---

## Settings

`~/Library/Application Support/nagara/settings.json`

| Key | Default | Meaning |
|---|---|---|
| `speakerId` | `1431611904` | Voice style ID (まい / Normal) |
| `rate` | `1.0` | Current speed. **This becomes the default next launch** |
| `rateLadder` | `[1.0 … 1.5]` | Steps that `⌃⌥→` / `⌃⌥←` move through |
| `volume` | `0.8` | Current volume. **This becomes the default next launch** |
| `volumeLadder` | `[0.2 … 1.0]` | Steps that `⌃⌥=` / `⌃⌥-` move through |
| `autoPlay` | `false` | Play on arrival |
| `port` | `17371` | Ingest port. Binds to `127.0.0.1` only |
| `engineURL` | `http://127.0.0.1:10101` | Use `:50021` for VOICEVOX |
| `engineIdleQuitMinutes` | `15` | Idle minutes before quitting the engine (`0` = never) |
| `quitEngineOnExit` | `true` | Quit the engine when nagara quits |
| `hideEngineOnLaunch` | `true` | Push the engine window back down on launch |
| `skipCodeBlocks` | `true` | Skip fenced code blocks |
| `minimumLength` | `12` | Shorter responses are not queued |
| `historyLimit` | `30` | How many items to keep |

**Speed is limited to 1.0–1.5.** Slowing below 1.0 makes time-stretching artifacts
audible enough to ruin it. Add lower values to `rateLadder` by hand if you want them.

The log is at `~/Library/Logs/nagara.log`.

---

## Troubleshooting

**Check the log first.** Every hotkey press is recorded.

```bash
tail -f ~/Library/Logs/nagara.log
```

| Symptom | What to look for |
|---|---|
| Shortcut does nothing | Does `hotkey: …` appear? **If not, the key never arrived** (another app claimed it) |
| It reacts but there's no sound | Does anything follow `player: N文を読み込んだ`? Likely an engine-side problem |
| Nothing ever queues | Does `history: 受け取った …` appear? If not, the hook isn't running |
| No right-click item | That app is probably Electron-based. Use `⌘C` → `⌃⌥C` |
| It reads back "再生を始めました" | Check that the `nagara:internal` marker in `~/.claude/commands/speak.md` is intact |

`nagara status` shows whether the app is alive;
`curl -s http://127.0.0.1:10101/version` shows whether the engine is.

---

## Not there yet

- Seeking to an arbitrary position (you can only move one sentence at a time)
- Media keys and Control Center (no Now Playing support)
- **Codex integration** (the CLI and `⌃⌥C` already work with it)
- Avatar display

Codex looks straightforward. `~/.codex/config.toml` has a `notify` entry that runs an
external program at the end of a turn, and that `agent-turn-complete` payload
**contains `last-assistant-message`** — the body comes for free, with no log parsing.
Codex also has its own hook system including a `Stop` event, closely mirroring Claude Code's.
It simply hasn't been implemented yet; nothing blocks it in principle.

Design decisions and the reasoning behind them are in [DESIGN.md](DESIGN.md) (Japanese).
Please read it before changing things.

---

## License and disclaimer

**MIT License** ([LICENSE](LICENSE)). Free for personal and commercial use.
Modify and redistribute freely. Provided **as is, without warranty of any kind**;
the author accepts no liability for any damage arising from its use.

nagara **neither bundles nor links** AivisSpeech — it talks to a separate process over HTTP.
AivisSpeech Engine itself is LGPL-3.0, and its authors state that credit is not required.

**The thing to watch is the voice models, not the engine.** Model licenses are separate,
and AivisHub models vary — ACML, ACML-NC, CC0 and others (`-NC` means non-commercial only).
**Check the terms of whichever model you use.** This matters especially if you put the
audio into a demo video or an article.

Voice used in this repository's demos: **AivisSpeech まい / Normal**
