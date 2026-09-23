import AppKit
import Foundation

// nagara — Mac で AI エージェントのコメントを、自分好みの音声で聴くための Player。
//
// 画面は読まない（スクリーンリーダーではない）。投げ込まれたテキストだけを読む。
// 入口は3つ、本体はひとつ。詳しくは DESIGN.md を参照。

final class Controller {

    var settings: Settings
    let aivis: Aivis
    let player: Player
    let history: History
    private var ingest: Ingest?
    private let hotkeys = Hotkeys()
    private var servicesProvider: ServicesProvider?
    private var menuBar: MenuBar?
    private var idleTimer: Timer?

    private(set) var speakers: [Speaker] = []
    private(set) var unreadCount = 0
    /// 自動再生の順番待ち。鳴っている間に届いたものは割り込まず、ここで待つ（DESIGN.md 3.1節）
    private(set) var waiting: [Utterance] = []
    private var loadedItemID: UUID?
    private(set) var lastError: String?

    init() {
        Log.rotateIfNeeded()
        let settings = Settings.load()
        self.settings = settings
        self.aivis = Aivis(settings: settings)
        self.player = Player(aivis: aivis, settings: settings)
        self.history = History(settings: settings)
    }

    func start() {
        Log.write("nagara: 起動 (version \(Bundle.main.shortVersion))")

        player.rate = settings.rate
        player.volume = settings.volume
        player.onStateChange = { [weak self] state in
            self?.hotkeys.setEscapeStopEnabled(state == .playing)
            self?.refreshUI()
        }
        player.onProgress = { [weak self] _, _ in self?.refreshUI() }
        player.onError = { [weak self] message in
            self?.lastError = message
            self?.refreshUI()
        }
        player.onFinished = { [weak self] in self?.playNextWaiting() }
        player.onFailed = { [weak self] in self?.dropWaiting(reason: "エンジンを用意できない") }
        history.onChange = { [weak self] in self?.refreshUI() }

        let menuBar = MenuBar(controller: self)
        self.menuBar = menuBar

        let provider = ServicesProvider { [weak self] text in
            // 選択して読ませたのだから、これは黙って積まずにすぐ鳴らす
            self?.speak(text: text, source: "選択テキスト", autoplay: true, force: true)
        }
        servicesProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()

        startIngest()
        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.register()

        LoginItem.enableOnFirstRun()
        startIdleTimer()
        refreshUI()

        // 起動直後にエンジンへ触りにはいかない。使うときまで寝かせておく
        Task { await self.loadSpeakersIfPossible() }
    }

    func shutdown() {
        idleTimer?.invalidate()
        stop()
        hotkeys.unregister()
        ingest?.stop()
        aivis.quitIfWeLaunchedIt()
        Log.write("nagara: 終了")
    }

    // MARK: - 入口

    private func startIngest() {
        let ingest = Ingest(port: settings.port) { [weak self] command, reply in
            guard let self else {
                reply(["error": "終了しています"])
                return
            }
            self.handle(command, reply: reply)
        }
        do {
            try ingest.start()
            self.ingest = ingest
        } catch {
            Log.write("ingest: 開始できなかった \(error.localizedDescription)")
            lastError = "ポート \(settings.port) を使えませんでした"
        }
    }

    /// 読みの走査だけは engine に何度も聞くので、答えを待たせる。
    /// 残りは今までどおりその場で返す
    private func handle(_ command: Ingest.Command, reply: @escaping ([String: Any]) -> Void) {
        guard command.path == "/yomi/check" else {
            reply(handle(command))
            return
        }
        let text = command.body["text"] as? String ?? ""
        Task { [weak self] in
            let found = await self?.scanReadings(text) ?? []
            await MainActor.run {
                reply(["ok": true, "found": found.map(\.dictionary),
                       "pending": Yomi.load().pending.map(\.dictionary)])
            }
        }
    }

    private func handle(_ command: Ingest.Command) -> [String: Any] {
        switch command.path {
        case "/yomi/pending":
            let store = Yomi.load()
            return ["ok": true, "pending": store.pending.map(\.dictionary),
                    "ignored": store.ignored, "readingCheck": settings.readingCheck]
        case "/yomi/resolve":
            guard let surface = command.body["surface"] as? String else {
                return ["error": "surface がありません"]
            }
            let ignore = command.body["ignore"] as? Bool ?? false
            Yomi.resolve(surface: surface, ignore: ignore)
            Log.write("yomi: \(surface) を片付けた（\(ignore ? "見送り" : "登録済み")）")
            return ["ok": true, "pending": Yomi.load().pending.map(\.dictionary)]
        case "/speak":
            guard let text = command.body["text"] as? String else {
                return ["error": "text がありません"]
            }
            let source = command.body["source"] as? String ?? "api"
            let autoplay = command.body["autoplay"] as? Bool
            let accepted = speak(text: text, source: source, autoplay: autoplay)
            return ["ok": true, "queued": accepted, "unread": unreadCount]

        case "/play":
            playLatest()
            return status()
        case "/pause":
            player.pause()
            return status()
        case "/toggle":
            toggle()
            return status()
        case "/stop":
            stop()
            return status()
        case "/autoplay":
            if let enabled = command.body["enabled"] as? Bool {
                setAutoPlay(enabled, announce: true)
            } else {
                setAutoPlay(!settings.autoPlay, announce: true)
            }
            return status()
        case "/back":
            player.previousSentence()
            return status()
        case "/clipboard":
            speakClipboard()
            return status()
        case "/next":
            player.nextSentence()
            return status()
        case "/rate":
            if let rate = command.body["rate"] as? Double {
                setRate(Float(rate))
            } else if let step = command.body["step"] as? Int {
                setRate(player.stepRate(step))
            } else {
                setRate(player.stepRate(1))
            }
            return status()
        case "/volume":
            if let volume = command.body["volume"] as? Double {
                setVolume(Float(volume))
            } else if let step = command.body["step"] as? Int {
                setVolume(player.stepVolume(step))
            } else {
                setVolume(player.stepVolume(1))
            }
            return status()
        case "/status", "/":
            return status()
        default:
            return ["error": "知らない道です: \(command.path)"]
        }
    }

    var stateName: String {
        switch player.state {
        case .playing: return "playing"
        case .paused: return "paused"
        case .idle: return "idle"
        }
    }

    func status() -> [String: Any] {
        let progress = player.progress
        return [
            "ok": true,
            "state": stateName,
            "rate": (Double(player.rate) * 100).rounded() / 100,
            "volume": (Double(player.volume) * 100).rounded() / 100,
            "sentence": progress.index,
            "sentences": progress.total,
            "unread": unreadCount,
            "waiting": waiting.count,
            "autoPlay": settings.autoPlay,
            "speaker": settings.speakerLabel,
            "engineRunning": aivis.isEngineRunning,
            "loginItem": LoginItem.isEnabled,
            "version": Bundle.main.shortVersion,
            "audio": player.audioDiagnostics,
            "menuBar": menuBar?.diagnostics ?? [:],
            "escapeStopRegistered": hotkeys.escapeStopRegistered,
            "lastError": lastError as Any? ?? NSNull(),
        ]
    }

    // MARK: - 操作

    /// テキストを受け取る。既定では**鳴らさず積むだけ**。
    /// これが「応答のたびに喋られてうざい」を避けるための一番大事な既定値。
    ///
    /// 自動再生で鳴らす場合でも、すでに何か鳴っているなら割り込まず順番を待つ。
    /// 複数のエージェントが続けて返事をしたとき、前の応答が途中で切られるのは聴く側が困る。
    /// 本人が明示的に読ませたもの（選択テキスト・クリップボード・`--now`）だけは待たせない
    @discardableResult
    func speak(text: String, source: String, autoplay: Bool? = nil, force: Bool = false) -> Bool {
        guard let item = history.add(text: text, source: source, force: force) else { return false }
        unreadCount += 1
        let shouldPlay = autoplay ?? settings.autoPlay
        guard shouldPlay else {
            refreshUI()
            return true
        }
        let explicit = force || autoplay == true
        if !explicit, player.state != .idle {
            enqueue(item)
        } else {
            play(item: item)
        }
        return true
    }

    private func enqueue(_ item: Utterance) {
        // 同じ本文が二重に届くと history は既存の項目を返す。同じものを二度は待たせない
        guard !waiting.contains(where: { $0.id == item.id }),
              !(item.id == loadedItemID && player.state != .idle) else {
            refreshUI()
            return
        }
        waiting.append(item)
        Log.write("queue: 順番待ちに入れた [\(item.source)] \(item.title)（\(waiting.count)件）")
        refreshUI()
    }

    /// 読み終わったら、待っているものをすぐ続ける。間を空けないのは、
    /// 「終わった」と「次が始まった」の区別が耳で付くほうが、待たされるより自然だから
    private func playNextWaiting() {
        guard !waiting.isEmpty else {
            refreshUI()
            return
        }
        let next = waiting.removeFirst()
        Log.write("queue: 次を再生 [\(next.source)] \(next.title)（残り\(waiting.count)件）")
        play(item: next)
    }

    private func dropWaiting(reason: String) {
        guard !waiting.isEmpty else { return }
        Log.write("queue: \(reason)ので順番待ち\(waiting.count)件を捨てた")
        waiting.removeAll()
        refreshUI()
    }

    /// 本人が止めたときの停止。いま鳴っているものだけでなく、順番待ちも空にする。
    ///
    /// 止めたということは「いまは音を出してはいけない」という状況で、
    /// 待っていたものが即座に続いたら Esc を何度も叩く羽目になる。
    /// ただし自動再生の設定はそのまま。これ以降に届くものは今までどおり鳴る
    func stop() {
        dropWaiting(reason: "止められた")
        player.stop()
    }

    func playLatest() {
        if player.state == .paused, loadedItemID != nil {
            lastError = nil
            player.play()
            return
        }
        guard let item = history.latest else {
            lastError = "まだ何も届いていません"
            refreshUI()
            return
        }
        play(item: item)
    }

    func play(item: Utterance) {
        lastError = nil
        loadedItemID = item.id
        unreadCount = 0
        player.load(text: item.text)
        player.play()
        guard settings.readingCheck else { return }
        // 読み終わるのを待たない。鳴らすほうが主で、こちらは裏で静かに走る
        Task { [weak self] in _ = await self?.scanReadings(item.text) }
    }

    /// 読む文章の中から、読みが怪しい語を拾って溜める。
    ///
    /// engine と macOS の読みが食い違ったものだけを候補にする。正解は決めない。
    /// 決めるのは AI エージェントか本人で、ここは指差すところまで
    func scanReadings(_ text: String) async -> [Yomi.Candidate] {
        let speakable = Sanitizer.speakable(from: text, skipCodeBlocks: settings.skipCodeBlocks)
        let speakerId = settings.speakerId
        var found: [Yomi.Candidate] = []
        for (word, context) in Yomi.words(in: speakable) {
            guard let guess = Yomi.macReading(word) else { continue }
            guard let engineReading = try? await aivis.reading(of: word, speakerId: speakerId),
                  Yomi.disagrees(engine: engineReading, guess: guess)
            else { continue }
            found.append(Yomi.Candidate(
                surface: word, engine: engineReading, guess: guess,
                context: context, seenAt: Date()))
        }
        return Yomi.append(found)
    }

    func toggle() {
        switch player.state {
        case .playing:
            player.pause()
        case .paused:
            lastError = nil
            player.play()
        case .idle:
            playLatest()
        }
    }

    private var lastActionAt: [Hotkeys.Action: Date] = [:]

    func perform(_ action: Hotkeys.Action) {
        // 押したのに何も起きない、が一番困る。届いたことは必ず記録する
        Log.write("hotkey: \(action)")
        // メニューを開いている間はグローバル側を黙らせていたが、
        // ステータス項目のメニューはキー等価物を拾わないので「開いている間は何も効かない」
        // という結果になった。抑止はやめ、二重発火だけを短く弾く
        if let previous = lastActionAt[action], Date().timeIntervalSince(previous) < 0.08 {
            Log.write("hotkey: \(action) は連打として捨てた")
            return
        }
        lastActionAt[action] = Date()
        switch action {
        case .toggle: toggle()
        case .rateUp: setRate(player.stepRate(1))
        case .rateDown: setRate(player.stepRate(-1))
        case .back: player.previousSentence()
        case .next: player.nextSentence()
        case .stop: stop()
        case .escapeStop:
            // 登録解除より前に届いたキー通知が、停止後に処理される場合がある。
            if player.state == .playing { stop() }
        case .autoPlayToggle: setAutoPlay(!settings.autoPlay, announce: true)
        case .clipboard: speakClipboard()
        case .volumeUp: setVolume(player.stepVolume(1))
        case .volumeDown: setVolume(player.stepVolume(-1))
        }
    }

    /// クリップボードの中身を読む。
    /// 右クリックのサービスが載らないアプリ（Electron 製など）でも、この経路なら通る
    func speakClipboard() {
        let pasteboard = NSPasteboard.general
        switch ClipboardReader.read(from: pasteboard) {
        case .success(let text):
            Log.write("clipboard: \(text.count)文字を読む")
            speak(text: text, source: "クリップボード", autoplay: true, force: true)
        case .failure(let error):
            // 本文は記録せず、次に調べられるよう形式とアクセス状態だけを残す。
            let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")
            Log.write("clipboard: \(error.message) (access=\(pasteboard.accessBehavior.rawValue), types=\(types))")
            lastError = error.message
            refreshUI()
        }
    }

    // MARK: - 設定

    func setRate(_ rate: Float) {
        player.rate = rate
        settings.rate = rate
        persist()
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
        settings.volume = player.volume
        persist()
    }

    /// `announce` はメニュー以外から切り替えたとき。メニューはチェックで分かるが、
    /// ショートカットや CLI では切り替わった先が見えないので、画面の中央に一瞬だけ出す
    func setAutoPlay(_ enabled: Bool, announce: Bool = false) {
        let justEnabled = enabled && !settings.autoPlay
        settings.autoPlay = enabled
        Log.write("settings: 自動再生を \(enabled ? "ON" : "OFF") にした")
        persist()
        if announce {
            Toast.show(enabled ? "自動再生 ON" : "自動再生 OFF",
                       symbol: enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
        // 返答の到着直後に ON にしても、その返答を取り残さない。
        // 再生中・一時停止中は本人の操作を優先し、既読の履歴も読み直さない。
        // 通常の再生経路を通すことで、エンジンが寝ていれば起動してから読む。
        if justEnabled, unreadCount > 0, player.state == .idle {
            playLatest()
        }
    }

    func setSpeaker(id: Int, label: String) {
        settings.speakerId = id
        settings.speakerLabel = label
        persist()
        Log.write("settings: 声を \(label) にした")
        // 読んでいる途中なら、いまの文から新しい声で読み直す
        if player.state != .idle, let itemID = loadedItemID,
           let item = history.item(with: itemID) {
            play(item: item)
        }
    }

    /// エンジンを使い終わったあとの身の振り方。
    /// 既定は idleQuit＝一度起きたら置いておくが、しばらく使われなければ静かに落ちる
    enum EnginePolicy: Int {
        case keepRunning = 0
        case idleQuit = 1
        case quitOnExit = 2

        var label: String {
            switch self {
            case .keepRunning: return "起動したままにする"
            case .idleQuit: return "しばらく使わなければ閉じる"
            case .quitOnExit: return "nagara の終了時に閉じる"
            }
        }
    }

    var enginePolicy: EnginePolicy {
        if settings.engineIdleQuitMinutes > 0 { return .idleQuit }
        return settings.quitEngineOnExit ? .quitOnExit : .keepRunning
    }

    /// 待ち時間を選んで「しばらく使わなければ閉じる」にする。
    /// 分を選ぶこと自体がその方針を選ぶことなので、入口をひとつにまとめてある
    func setReadingCheck(_ enabled: Bool) {
        settings.readingCheck = enabled
        Log.write("settings: 読み間違いの見張りを \(enabled ? "オン" : "オフ") にした")
        persist()
    }

    func setEngineIdleMinutes(_ minutes: Int) {
        settings.engineIdleQuitMinutes = max(1, minutes)
        settings.quitEngineOnExit = true
        persist()
    }

    func setEnginePolicy(_ policy: EnginePolicy) {
        switch policy {
        case .keepRunning:
            settings.engineIdleQuitMinutes = 0
            settings.quitEngineOnExit = false
        case .idleQuit:
            settings.engineIdleQuitMinutes = max(1, settings.engineIdleQuitMinutes == 0 ? 15 : settings.engineIdleQuitMinutes)
            settings.quitEngineOnExit = true
        case .quitOnExit:
            settings.engineIdleQuitMinutes = 0
            settings.quitEngineOnExit = true
        }
        persist()
    }

    private func persist() {
        settings.save()
        aivis.update(settings: settings)
        player.update(settings: settings)
        history.update(settings: settings)
        refreshUI()
    }

    // MARK: - エンジン

    func loadSpeakersIfPossible() async {
        guard await aivis.isUp() else { return }
        if let list = try? await aivis.speakers() {
            await MainActor.run {
                self.speakers = list
                self.refreshUI()
            }
        }
    }

    func launchEngine() {
        Task {
            try? await aivis.ensureRunning()
            await loadSpeakersIfPossible()
        }
    }

    func quitEngine() {
        aivis.quit()
        refreshUI()
    }

    /// 一度起きたエンジンは置いておく。ただし使われないまま時間が経てば静かに落とす。
    /// 起動のたびに8秒待つのも、一日中居座られるのも避けたい、という折り合い
    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.player.state == .idle else { return }
            if self.aivis.quitIfIdle() { self.refreshUI() }
        }
    }

    func refreshUI() {
        menuBar?.refresh()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = Controller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}

@main
enum Nagara {
    // run() が返るまで生き続ける必要があるので、デリゲートは static に持つ
    private static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        // Dock にもメニューバー（アプリ側）にも出さない。常駐はステータス項目だけ
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
