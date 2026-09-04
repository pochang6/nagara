import Carbon.HIToolbox
import Foundation

// グローバルショートカット。
//
// Carbon の RegisterEventHotKey を使う理由は、**許可が一切要らない**から。
// nobetsu が入力監視を必要としたのは ⌘ 単体の長押しを見張るためで、
// 修飾キーとの和音であればこの API で足りる。System Settings での許可作業がまるごと消える。
//
// ⌥⌘→ / ⌥⌘← は Chrome・Safari・VS Code が「次のタブ／前のタブ」に使っているので避けた。
// 奪うと全アプリでタブ切り替えが壊れる。⌃⌥ 系はほぼ空いている。
final class Hotkeys {

    // 速度は「回す」のをやめ、1段ずつ上げ下げにした。
    // 上げすぎたときに一周させられるのは、実際に使うと苦痛だった。
    enum Action: UInt32 {
        case toggle = 1     // ⌃⌥P  再生 / 一時停止
        case rateUp = 2     // ⌃⌥→  速く
        case rateDown = 3   // ⌃⌥←  遅く
        case back = 4       // ⌃⌥↑  1文戻る
        case next = 5       // ⌃⌥↓  1文進む
        case stop = 6       // ⌃⌥.  停止
        case clipboard = 7  // ⌃⌥C  クリップボードを読む
        case volumeUp = 8   // ⌃⌥=  大きく
        case volumeDown = 9 // ⌃⌥-  小さく
    }

    private static weak var current: Hotkeys?

    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    var onAction: ((Action) -> Void)?

    func register() {
        Hotkeys.current = self

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID)
                guard status == noErr, let action = Action(rawValue: hotKeyID.id) else { return noErr }
                DispatchQueue.main.async {
                    Hotkeys.current?.onAction?(action)
                }
                return noErr
            },
            1, &spec, nil, &handlerRef)

        let modifiers = UInt32(controlKey | optionKey)
        bind(keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers, action: .toggle)
        bind(keyCode: UInt32(kVK_RightArrow), modifiers: modifiers, action: .rateUp)
        bind(keyCode: UInt32(kVK_LeftArrow), modifiers: modifiers, action: .rateDown)
        bind(keyCode: UInt32(kVK_UpArrow), modifiers: modifiers, action: .back)
        bind(keyCode: UInt32(kVK_DownArrow), modifiers: modifiers, action: .next)
        bind(keyCode: UInt32(kVK_ANSI_Period), modifiers: modifiers, action: .stop)
        // Electron 製のアプリ（Claude Code のデスクトップ版もそう）は
        // コンテキストメニューを自前で描くので、macOS のサービスが載らない。
        // ⌘C でコピーしてから ⌃⌥C、という経路ならどこでも通る
        bind(keyCode: UInt32(kVK_ANSI_C), modifiers: modifiers, action: .clipboard)
        // 音量は矢印が埋まっているので = / -。システム音量の ⌥ 系とは当たらない
        bind(keyCode: UInt32(kVK_ANSI_Equal), modifiers: modifiers, action: .volumeUp)
        bind(keyCode: UInt32(kVK_ANSI_Minus), modifiers: modifiers, action: .volumeDown)

        Log.write("hotkeys: ⌃⌥P 再生 / ⌃⌥→ 速く / ⌃⌥← 遅く / ⌃⌥↑ 前の文 / ⌃⌥↓ 次の文 / ⌃⌥= 大きく / ⌃⌥- 小さく / ⌃⌥. 停止 / ⌃⌥C クリップボード")
    }

    func unregister() {
        for ref in refs where ref != nil {
            UnregisterEventHotKey(ref!)
        }
        refs.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func bind(keyCode: UInt32, modifiers: UInt32, action: Action) {
        var ref: EventHotKeyRef?
        // 'ngar' ―― このアプリのホットキーだと分かる 4 文字コード
        let id = EventHotKeyID(signature: OSType(0x6E67_6172), id: action.rawValue)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            // 他のアプリに先に取られていると失敗する。黙って諦めず記録は残す
            Log.write("hotkeys: 登録に失敗 (action=\(action), status=\(status))")
        }
    }
}
