import AppKit

// 画面の中央に一瞬だけ出て、消える文字。
//
// 自動再生の ON/OFF をショートカットや CLI で切り替えたとき、切り替わった先が
// どこにも見えないのは困る。メニューを開けばチェックで分かるが、それでは
// ショートカットにした意味が無い。見た瞬間に読める大きさで出し、2秒で引っ込める。
//
// キーボードフォーカスは奪わない（nonactivating）。クリックも素通しする。
// 出ている間に本人が打っている文字が、こちらに吸われてはいけない
enum Toast {

    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var icon: NSImageView?
    private static var stack: NSStackView?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String? = nil, duration: TimeInterval = 2.0) {
        let panel = panel ?? makePanel()
        label?.stringValue = text
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            icon?.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
            icon?.isHidden = false
        } else {
            icon?.isHidden = true
        }
        // 文字の長さに合わせて窓の大きさを決める。窓の contentView は
        // autoresizing のままなので、中の stack から大きさを聞く
        let size = stack?.fittingSize.applying(insets: 22, 14) ?? NSSize(width: 220, height: 60)
        panel.setContentSize(size)

        // 本人が見ている画面の中央。マウスのある画面が一番それに近い
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrameOrigin(NSPoint(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2))

        hideWork?.cancel()
        // すでに出ているなら差し替えるだけ。消えかけを立て直す
        panel.alphaValue = panel.isVisible ? 1 : 0
        panel.orderFrontRegardless()
        Log.write("toast: \(text) \(NSStringFromRect(panel.frame)) visible=\(panel.isVisible)")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 黒ベースの透過。すりガラスにすると背景の色を拾って重たく見えたので、
        // 素の黒を薄く敷き、縁だけをうっすら白く引く。
        // ライトの画面では黒い箱として、ダークの画面では縁と影で浮いて見える。
        // 透過を強くしすぎると暗い画面で溶けるので、6割強で止めてある
        panel.appearance = NSAppearance(named: .darkAqua)

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        background.layer?.cornerRadius = 14
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        background.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 19, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
        ])

        panel.contentView = background
        self.panel = panel
        self.label = label
        self.icon = icon
        self.stack = stack
        return panel
    }
}

private extension NSSize {
    func applying(insets horizontal: CGFloat, _ vertical: CGFloat) -> NSSize {
        NSSize(width: ceil(width + horizontal * 2), height: ceil(height + vertical * 2))
    }
}
