import AppKit

// メニューバーの常駐。設定はここから触れるものだけに絞り、残りは settings.json を直接開く。
//
// アイコンは状態がひと目で分かることを優先している。
// 「届いているが鳴っていない」が既定の状態なので、そこが分からないと使えない。
final class MenuBar: NSObject, NSMenuDelegate {

    private unowned let controller: Controller
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(controller: Controller) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        refresh()
    }

    // MARK: - アイコン

    // アイコンは「読み上げ」だと分かる吹き出しを基本形にしている。
    // nobetsu が waveform 系を使っているので、そこと silhouette が被らないことを優先した。
    // メニューバーに2つ並んだときに見分けられないと、どちらの常駐か分からなくなる。
    private func symbolName() -> String {
        switch controller.player.state {
        case .playing: return "speaker.wave.2.fill"
        case .paused: return "pause.circle.fill"
        case .idle: return controller.unreadCount > 0 ? "text.bubble.fill" : "text.bubble"
        }
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        let name = symbolName()
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "nagara") {
            image.isTemplate = true
            button.image = image
        } else {
            // 記号が無い OS でも、姿が消えて行方不明になるよりはまし
            Log.write("menubar: シンボル \(name) が見つからない")
            button.image = nil
            button.title = "nagara"
            return
        }
        button.title = controller.unreadCount > 0 && controller.player.state == .idle
            ? " \(controller.unreadCount)" : ""
    }

    // MARK: - メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled(statusLine()))
        if let error = controller.lastError {
            menu.addItem(disabled("⚠︎ \(error)"))
        }
        menu.addItem(.separator())

        let playTitle: String
        switch controller.player.state {
        case .playing: playTitle = "一時停止"
        case .paused: playTitle = "再開"
        case .idle: playTitle = controller.history.latest == nil ? "再生（届いていません）" : "最新を再生"
        }
        let play = item(playTitle, #selector(toggleAction), key: "p")
        play.isEnabled = controller.history.latest != nil || controller.player.state != .idle
        menu.addItem(play)
        menu.addItem(item("停止", #selector(stopAction), key: "."))
        let back = item("1文戻る", #selector(backAction), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        back.isEnabled = controller.player.state != .idle
        menu.addItem(back)

        menu.addItem(.separator())
        menu.addItem(submenu("速度", build: rateMenu()))
        menu.addItem(submenu("声", build: speakerMenu()))

        let autoPlay = item("自動再生", #selector(autoPlayAction))
        autoPlay.state = controller.settings.autoPlay ? .on : .off
        menu.addItem(autoPlay)

        menu.addItem(.separator())
        menu.addItem(submenu("履歴", build: historyMenu()))

        menu.addItem(.separator())
        menu.addItem(submenu("AivisSpeech", build: engineMenu()))

        menu.addItem(.separator())
        let login = item("ログイン時に起動", #selector(loginItemAction))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("設定ファイルを開く", #selector(openSettingsAction)))
        menu.addItem(item("ログを開く", #selector(openLogAction)))

        menu.addItem(.separator())
        menu.addItem(item("nagara を終了", #selector(quitAction), key: "q"))
    }

    private func statusLine() -> String {
        switch controller.player.state {
        case .playing, .paused:
            let progress = controller.player.progress
            let label = controller.player.state == .playing ? "再生中" : "一時停止"
            return "\(label)  \(min(progress.index + 1, progress.total))/\(progress.total)　\(rateLabel(controller.player.rate))"
        case .idle:
            if controller.unreadCount > 0 { return "未再生 \(controller.unreadCount) 件" }
            return controller.history.latest == nil ? "待機中（まだ届いていません）" : "待機中"
        }
    }

    // 1.25 のような刻みを %.1f で出すと「1.3倍」になって嘘になる。
    // 必要なぶんだけ小数を見せる
    private func rateLabel(_ rate: Float) -> String {
        let hundredths = (rate * 100).rounded()
        let format = hundredths.truncatingRemainder(dividingBy: 10) == 0 ? "%.1f倍" : "%.2f倍"
        return String(format: format, rate)
    }

    private func rateMenu() -> NSMenu {
        let submenu = NSMenu()
        let cycle = controller.settings.rates
        // 細かく決め打ちしたい人のために段階を並べる。
        // ⌃⌥→ で回るのは短い候補だけなので、押しやすさは損なわれない
        for rate in controller.settings.rateLadder {
            var title = rateLabel(rate)
            if cycle.contains(where: { abs($0 - rate) < 0.001 }) { title += "  ·" }
            let entry = item(title, #selector(rateAction))
            entry.representedObject = rate
            entry.state = abs(controller.player.rate - rate) < 0.01 ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("· は ⌃⌥→ で回る候補"))
        submenu.addItem(disabled("選んだ速度が次回の既定になります"))
        return submenu
    }

    private func speakerMenu() -> NSMenu {
        let submenu = NSMenu()
        guard !controller.speakers.isEmpty else {
            submenu.addItem(disabled("AivisSpeech に接続すると一覧が出ます"))
            submenu.addItem(item("いま読み込む", #selector(reloadSpeakersAction)))
            return submenu
        }
        // 一覧はハードコードしない。AivisSpeech にモデルを足せば勝手に増える
        for speaker in controller.speakers {
            if speaker.styles.count == 1, let style = speaker.styles.first {
                let entry = item(speaker.name, #selector(speakerAction))
                entry.representedObject = SpeakerChoice(id: style.id, label: "\(speaker.name) / \(style.name)")
                entry.state = controller.settings.speakerId == style.id ? .on : .off
                submenu.addItem(entry)
                continue
            }
            let styles = NSMenu()
            for style in speaker.styles {
                let entry = item(style.name, #selector(speakerAction))
                entry.representedObject = SpeakerChoice(id: style.id, label: "\(speaker.name) / \(style.name)")
                entry.state = controller.settings.speakerId == style.id ? .on : .off
                styles.addItem(entry)
            }
            let parent = NSMenuItem(title: speaker.name, action: nil, keyEquivalent: "")
            parent.submenu = styles
            if speaker.styles.contains(where: { $0.id == controller.settings.speakerId }) {
                parent.state = .on
            }
            submenu.addItem(parent)
        }
        return submenu
    }

    private func historyMenu() -> NSMenu {
        let submenu = NSMenu()
        let items = controller.history.items
        guard !items.isEmpty else {
            submenu.addItem(disabled("まだ何も届いていません"))
            return submenu
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        for utterance in items.prefix(15) {
            let entry = item("\(formatter.string(from: utterance.receivedAt))  \(utterance.title)",
                             #selector(historyAction))
            entry.representedObject = utterance.id
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(item("履歴を消す", #selector(clearHistoryAction)))
        return submenu
    }

    private func engineMenu() -> NSMenu {
        let submenu = NSMenu()
        let running = controller.aivis.isEngineRunning
        submenu.addItem(disabled(running ? "● 起動中" : "○ 停止中"))
        submenu.addItem(.separator())
        if running {
            submenu.addItem(item("いま終了する", #selector(quitEngineAction)))
        } else {
            submenu.addItem(item("いま起動する", #selector(launchEngineAction)))
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("使い終わったら"))
        for policy in [Controller.EnginePolicy.keepRunning, .idleQuit, .quitOnExit] {
            var title = policy.label
            if policy == .idleQuit {
                title = "\(controller.settings.engineIdleQuitMinutes)分使わなければ閉じる"
            }
            let entry = item(title, #selector(enginePolicyAction))
            entry.representedObject = policy.rawValue
            entry.state = controller.enginePolicy == policy ? .on : .off
            submenu.addItem(entry)
        }
        return submenu
    }

    // MARK: - 部品

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        // ショートカットはグローバルホットキーで受けているので、メニュー側は表示しない
        entry.keyEquivalentModifierMask = []
        entry.keyEquivalent = ""
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func submenu(_ title: String, build: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = build
        return entry
    }

    // MARK: - 動作

    @objc private func toggleAction() { controller.toggle() }
    @objc private func stopAction() { controller.player.stop() }
    @objc private func backAction() { controller.player.previousSentence() }

    @objc private func rateAction(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Float else { return }
        controller.setRate(rate)
    }

    @objc private func autoPlayAction() {
        controller.setAutoPlay(!controller.settings.autoPlay)
    }

    @objc private func speakerAction(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SpeakerChoice else { return }
        controller.setSpeaker(id: choice.id, label: choice.label)
    }

    @objc private func reloadSpeakersAction() {
        controller.launchEngine()
    }

    @objc private func historyAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let utterance = controller.history.item(with: id) else { return }
        controller.play(item: utterance)
    }

    @objc private func clearHistoryAction() { controller.history.clear() }
    @objc private func launchEngineAction() { controller.launchEngine() }
    @objc private func quitEngineAction() { controller.quitEngine() }

    @objc private func enginePolicyAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let policy = Controller.EnginePolicy(rawValue: raw) else { return }
        controller.setEnginePolicy(policy)
    }

    @objc private func loginItemAction() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func openSettingsAction() {
        NSWorkspace.shared.open(Settings.fileURL)
    }

    @objc private func openLogAction() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}

/// representedObject に入れるための箱。タプルは Objective-C に渡せない
final class SpeakerChoice: NSObject {
    let id: Int
    let label: String
    init(id: Int, label: String) {
        self.id = id
        self.label = label
    }
}
