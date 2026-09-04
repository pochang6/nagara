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
        player.onStateChange = { [weak self] _ in self?.refreshUI() }
        player.onProgress = { [weak self] _, _ in self?.refreshUI() }
        player.onError = { [weak self] message in
            self?.lastError = message
            self?.refreshUI()
        }
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
        player.stop()
        hotkeys.unregister()
        ingest?.stop()
        aivis.quitIfWeLaunchedIt()
        Log.write("nagara: 終了")
    }

    // MARK: - 入口

    private func startIngest() {
        let ingest = Ingest(port: settings.port) { [weak self] command in
            guard let self else { return ["error": "終了しています"] }
            return self.handle(command)
        }
        do {
            try ingest.start()
            self.ingest = ingest
        } catch {
            Log.write("ingest: 開始できなかった \(error.localizedDescription)")
            lastError = "ポート \(settings.port) を使えませんでした"
        }
    }

    private func handle(_ command: Ingest.Command) -> [String: Any] {
        switch command.path {
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
            player.stop()
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
            "autoPlay": settings.autoPlay,
            "speaker": settings.speakerLabel,
            "engineRunning": aivis.isEngineRunning,
            "loginItem": LoginItem.isEnabled,
            "version": Bundle.main.shortVersion,
        ]
    }

    // MARK: - 操作

    /// テキストを受け取る。既定では**鳴らさず積むだけ**。
    /// これが「応答のたびに喋られてうざい」を避けるための一番大事な既定値。
    @discardableResult
    func speak(text: String, source: String, autoplay: Bool? = nil, force: Bool = false) -> Bool {
        guard let item = history.add(text: text, source: source, force: force) else { return false }
        unreadCount += 1
        let shouldPlay = autoplay ?? settings.autoPlay
        if shouldPlay {
            play(item: item)
        } else {
            refreshUI()
        }
        return true
    }

    func playLatest() {
        if player.state == .paused, loadedItemID != nil {
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
    }

    func toggle() {
        switch player.state {
        case .playing:
            player.pause()
        case .paused:
            player.play()
        case .idle:
            playLatest()
        }
    }

    private var lastActionAt: [Hotkeys.Action: Date] = [:]

    private func perform(_ action: Hotkeys.Action) {
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
        case .stop: player.stop()
        case .clipboard: speakClipboard()
        case .volumeUp: setVolume(player.stepVolume(1))
        case .volumeDown: setVolume(player.stepVolume(-1))
        }
    }

    /// クリップボードの中身を読む。
    /// 右クリックのサービスが載らないアプリ（Electron 製など）でも、この経路なら通る
    func speakClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            // 黙って何も起きないのが一番困る。理由は必ず残す
            Log.write("clipboard: 文字列が入っていないので読めない")
            lastError = "クリップボードが空です"
            refreshUI()
            return
        }
        Log.write("clipboard: \(text.count)文字を読む")
        speak(text: text, source: "クリップボード", autoplay: true, force: true)
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

    func setAutoPlay(_ enabled: Bool) {
        settings.autoPlay = enabled
        persist()
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
