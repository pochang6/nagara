import AppKit

// メニューバーの常駐。設定はここから触れるものだけに絞り、残りは settings.json を直接開く。
//
// アイコンは状態がひと目で分かることを優先している。
// 「届いているが鳴っていない」が既定の状態なので、そこが分からないと使えない。
final class MenuBar: NSObject, NSMenuDelegate {

    private unowned let controller: Controller
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var keyMonitor: Any?

    init(controller: Controller) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        // view を持つ項目は action を持たないので、自動判定に任せると無効にされる。
        // 「自動再生」が灰色になってチェックも押せなくなったのはこれ。
        // 有効・無効はこちらで明示する（disabled() と isEnabled）
        menu.autoenablesItems = false
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

    // メニューを開いている間だけ、キーを自分で拾う。
    //
    // グローバルホットキーは Carbon の RegisterEventHotKey で、キー自体は横取りするのに、
    // メニューのトラッキング中はアプリまで届かない。ステータス項目のメニューは
    // キー等価物も拾わないので、開いている間は何を押しても無反応だった。
    // 開きっぱなしにした以上、ここが効かないのは不便すぎる
    func menuWillOpen(_ menu: NSMenu) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = MenuBar.action(for: event) else { return event }
            Log.write("menubar: 開いたまま \(action) を受けた")
            self.controller.perform(action)
            self.refreshOpenMenu()
            return nil
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 矢印は配列に左右されないよう keyCode で見る。それ以外は文字で見る
    private static func action(for event: NSEvent) -> Hotkeys.Action? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.option),
              !flags.contains(.command) else { return nil }
        switch event.keyCode {
        case 123: return .rateDown
        case 124: return .rateUp
        case 125: return .next
        case 126: return .back
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p": return .toggle
        case ".": return .stop
        case "c": return .clipboard
        case "=": return .volumeUp
        case "-": return .volumeDown
        default: return nil
        }
    }

    /// 開いたままの状態で中身が変わったときに、見えているところを描き直す。
    /// 速度や音量は先頭の1行にも出ているので、そこも合わせる
    func refreshOpenMenu() {
        menu.items.first?.title = statusLine()
        var menus: [NSMenu] = [menu]
        while let current = menus.popLast() {
            for entry in current.items {
                (entry.view as? StickyMenuItemView)?.needsDisplay = true
                if let child = entry.submenu { menus.append(child) }
            }
        }
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
        let back = item("1文戻る", #selector(backAction), key: Self.upArrow)
        back.isEnabled = controller.player.state != .idle
        menu.addItem(back)
        let next = item("1文進む", #selector(nextAction), key: Self.downArrow)
        next.isEnabled = controller.player.state != .idle
        menu.addItem(next)

        menu.addItem(.separator())
        menu.addItem(item("クリップボードを読む", #selector(clipboardAction), key: "c"))

        menu.addItem(.separator())
        menu.addItem(submenu("速度", build: rateMenu()))
        menu.addItem(submenu("音量", build: volumeMenu()))
        menu.addItem(submenu("声", build: speakerMenu()))

        menu.addItem(sticky(
            "自動再生",
            isOn: { [weak self] in self?.controller.settings.autoPlay ?? false },
            select: { [weak self] in self?.autoPlayAction() }))

        menu.addItem(.separator())
        menu.addItem(submenu("履歴", build: historyMenu()))

        menu.addItem(.separator())
        menu.addItem(submenu("AivisSpeech", build: engineMenu()))

        menu.addItem(.separator())
        menu.addItem(sticky(
            "ログイン時に起動",
            isOn: { LoginItem.isEnabled },
            select: { [weak self] in self?.loginItemAction() }))
        menu.addItem(item("設定ファイルを開く", #selector(openSettingsAction)))
        menu.addItem(item("ログを開く", #selector(openLogAction)))

        menu.addItem(.separator())
        menu.addItem(item("nagara を終了", #selector(quitAction), key: "q", modifiers: [.command]))
    }

    private func statusLine() -> String {
        switch controller.player.state {
        case .playing, .paused:
            let progress = controller.player.progress
            let label = controller.player.state == .playing ? "再生中" : "一時停止"
            return "\(label)  \(min(progress.index + 1, progress.total))/\(progress.total)　\(rateLabel(controller.player.rate))　\(volumeLabel(controller.player.volume))"
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
        let submenu = newMenu()
        submenu.addItem(item("速く", #selector(rateUpAction), key: Self.rightArrow))
        submenu.addItem(item("遅く", #selector(rateDownAction), key: Self.leftArrow))
        submenu.addItem(.separator())
        for rate in controller.settings.rateLadder {
            submenu.addItem(sticky(
                rateLabel(rate),
                isOn: { [weak self] in abs((self?.controller.player.rate ?? 0) - rate) < 0.01 },
                select: { [weak self] in self?.controller.setRate(rate) }))
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("選んだ速度が次回の既定になります"))
        return submenu
    }

    private func volumeLabel(_ volume: Float) -> String {
        "\(Int((volume * 100).rounded()))%"
    }

    private func volumeMenu() -> NSMenu {
        let submenu = newMenu()
        submenu.addItem(item("大きく", #selector(volumeUpAction), key: "="))
        submenu.addItem(item("小さく", #selector(volumeDownAction), key: "-"))
        submenu.addItem(.separator())
        for volume in controller.settings.volumeLadder {
            submenu.addItem(sticky(
                volumeLabel(volume),
                isOn: { [weak self] in abs((self?.controller.player.volume ?? 0) - volume) < 0.005 },
                select: { [weak self] in self?.controller.setVolume(volume) }))
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("選んだ音量が次回の既定になります"))
        return submenu
    }

    private func speakerMenu() -> NSMenu {
        let submenu = newMenu()
        guard !controller.speakers.isEmpty else {
            submenu.addItem(disabled("AivisSpeech に接続すると一覧が出ます"))
            submenu.addItem(item("いま読み込む", #selector(reloadSpeakersAction)))
            return submenu
        }
        // 一覧はハードコードしない。AivisSpeech にモデルを足せば勝手に増える
        for speaker in controller.speakers {
            if speaker.styles.count == 1, let style = speaker.styles.first {
                let label = "\(speaker.name) / \(style.name)"
                submenu.addItem(sticky(
                    speaker.name,
                    isOn: { [weak self] in self?.controller.settings.speakerId == style.id },
                    select: { [weak self] in self?.controller.setSpeaker(id: style.id, label: label) }))
                continue
            }
            let styles = newMenu()
            for style in speaker.styles {
                let label = "\(speaker.name) / \(style.name)"
                styles.addItem(sticky(
                    style.name,
                    isOn: { [weak self] in self?.controller.settings.speakerId == style.id },
                    select: { [weak self] in self?.controller.setSpeaker(id: style.id, label: label) }))
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
        let submenu = newMenu()
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
        let submenu = newMenu()
        let running = controller.aivis.isEngineRunning
        submenu.addItem(disabled(running ? "● 起動中" : "○ 停止中"))
        if running, !controller.aivis.launchedByUs {
            // 「時間が来ても閉じない」がバグに見えないように、理由をその場に出す
            submenu.addItem(disabled("　nagara のものではないので閉じません"))
        }
        submenu.addItem(.separator())
        if running {
            submenu.addItem(item("いま終了する", #selector(quitEngineAction)))
        } else {
            submenu.addItem(item("いま起動する", #selector(launchEngineAction)))
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("使い終わったら"))
        for policy in [Controller.EnginePolicy.keepRunning, .idleQuit, .quitOnExit] {
            // 待ち時間の段は1階層下に置く。上はこれまでどおりの3択のままにしたい。
            // ここに分を並べると、いちばん使う3択が段に埋もれる
            if policy == .idleQuit {
                // ここの submenu はローカル変数のほう。作る側はメソッド
                let entry = self.submenu(idleQuitTitle(), build: idleQuitMenu())
                entry.state = controller.enginePolicy == policy ? .on : .off
                submenu.addItem(entry)
                continue
            }
            submenu.addItem(sticky(
                policy.label,
                isOn: { [weak self] in self?.controller.enginePolicy == policy },
                select: { [weak self] in self?.controller.setEnginePolicy(policy) }))
        }
        return submenu
    }

    /// 選ばれているときだけ待ち時間を出す。
    /// 以前はいつでも分を出していたので、「起動したままにする」を選んだ拍子に
    /// 分が 0 になり、選んでもいない項目が「0分使わなければ閉じる」と名乗っていた
    private func idleQuitTitle() -> String {
        let minutes = controller.settings.engineIdleQuitMinutes
        guard controller.enginePolicy == .idleQuit, minutes > 0 else {
            return Controller.EnginePolicy.idleQuit.label
        }
        return "\(minutesLabel(minutes))使わなければ閉じる"
    }

    private func minutesLabel(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)分" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)時間" : "\(hours)時間\(rest)分"
    }

    private func idleQuitMenu() -> NSMenu {
        let submenu = newMenu()
        let ladder = controller.settings.engineIdleQuitLadder
        for minutes in (ladder.isEmpty ? [15] : ladder).sorted() {
            submenu.addItem(sticky(
                minutesLabel(minutes),
                isOn: { [weak self] in
                    self?.controller.enginePolicy == .idleQuit
                        && self?.controller.settings.engineIdleQuitMinutes == minutes
                },
                select: { [weak self] in self?.controller.setEngineIdleMinutes(minutes) }))
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("段は設定ファイルで足し引きできます"))
        return submenu
    }

    // MARK: - 部品

    // ショートカットはメニューの右側に薄く出す。忘れたときに確かめる場所が要る。
    // キー等価物を実際に設定することで、AppKit が標準の見た目で右寄せに描いてくれる。
    // ただし表示だけで、実際に効かせているのは menuWillOpen の監視のほう
    private func item(
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.control, .option]
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return entry
    }

    private static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    private static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    /// チェックの付く項目は、選んでもメニューを閉じない。
    ///
    /// 入れた直後に閉じられると、入ったのかどうかを確かめる場所が無い。
    /// もう一度開いて確かめるくらいなら、開いたままにして目で見たほうが早い。
    /// 閉じるのはメニューの外を押したときと esc のときだけでいい。
    /// 「停止」「ログを開く」のような1回きりの項目は今までどおり閉じる
    private func sticky(
        _ title: String,
        isOn: @escaping () -> Bool,
        select: @escaping () -> Void
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.view = StickyMenuItemView(title: title, isOn: isOn, select: { [weak self] in
            select()
            self?.refreshOpenMenu()
        })
        return entry
    }

    /// 部分メニューも自動判定を切る。理由は init と同じ
    private func newMenu() -> NSMenu {
        let created = NSMenu()
        created.autoenablesItems = false
        return created
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

    @objc private func volumeUpAction() {
        controller.setVolume(controller.player.stepVolume(1))
    }

    @objc private func volumeDownAction() {
        controller.setVolume(controller.player.stepVolume(-1))
    }

    @objc private func rateUpAction() {
        controller.setRate(controller.player.stepRate(1))
    }

    @objc private func rateDownAction() {
        controller.setRate(controller.player.stepRate(-1))
    }

    @objc private func nextAction() {
        controller.player.nextSentence()
    }

    @objc private func clipboardAction() {
        controller.speakClipboard()
    }

    @objc private func autoPlayAction() {
        controller.setAutoPlay(!controller.settings.autoPlay)
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

/// 選んでも閉じないメニュー項目の中身。
///
/// NSMenu は項目を選ぶと必ず閉じる。開いたままにする道は「項目に view を持たせる」しかない。
/// view を持つ項目は AppKit が勝手に閉じないので、閉じるかどうかをこちらで決められる。
/// 代わりに見た目は全部こちらで描くことになるので、対象はチェックの付く項目だけに絞っている。
///
/// 標準の項目と隣り合うため、字下げと高さは標準に寄せてある。
/// ここがずれると、同じメニューの中で行が揃わずに目立つ
final class StickyMenuItemView: NSView {

    private static let font = NSFont.menuFont(ofSize: 0)
    private static let titleLeading: CGFloat = 22
    private static let trailing: CGFloat = 24
    private static let rowHeight = max(20, ceil(NSFont.menuFont(ofSize: 0).boundingRectForFont.height) + 3)

    private let title: String
    private let isOn: () -> Bool
    private let select: () -> Void
    private var isInside = false

    init(title: String, isOn: @escaping () -> Bool, select: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.select = select
        let width = (title as NSString)
            .size(withAttributes: [.font: Self.font]).width + Self.titleLeading + Self.trailing
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: Self.rowHeight))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("使わない") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        needsDisplay = true
    }

    /// 選んでも閉じない。閉じるのはメニューの外を押したときと esc のとき（AppKit 任せ）
    override func mouseUp(with event: NSEvent) {
        guard enclosingMenuItem?.isEnabled ?? true else { return }
        select()
        // 選び直しは隣のチェックも動く。同じメニューと親をまとめて描き直す
        var menu = enclosingMenuItem?.menu
        while let current = menu {
            for entry in current.items {
                (entry.view as? StickyMenuItemView)?.needsDisplay = true
            }
            menu = current.supermenu
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let enabled = enclosingMenuItem?.isEnabled ?? true
        let highlighted = enabled && (isInside || enclosingMenuItem?.isHighlighted == true)

        if highlighted {
            // selectedMenuItemColor は 11.0 で非推奨。いまのメニューの選択色はアクセント色
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4
            ).fill()
        }

        let color: NSColor
        if !enabled {
            color = .disabledControlTextColor
        } else {
            color = highlighted ? .selectedMenuItemTextColor : .labelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: Self.titleLeading, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)

        guard isOn() else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.font.pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        check.draw(in: NSRect(
            x: 8,
            y: (bounds.height - check.size.height) / 2,
            width: check.size.width,
            height: check.size.height))
    }
}
