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

    enum Action: UInt32 {
        case toggle = 1     // ⌃⌥P  再生 / 一時停止
        case rate = 2       // ⌃⌥→  速度を回す
        case back = 3       // ⌃⌥←  1文戻る
        case stop = 4       // ⌃⌥.  停止
    }

    static let descriptions: [(Action, String)] = [
        (.toggle, "⌃⌥P"),
        (.rate, "⌃⌥→"),
        (.back, "⌃⌥←"),
        (.stop, "⌃⌥."),
    ]

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
        bind(keyCode: UInt32(kVK_RightArrow), modifiers: modifiers, action: .rate)
        bind(keyCode: UInt32(kVK_LeftArrow), modifiers: modifiers, action: .back)
        bind(keyCode: UInt32(kVK_ANSI_Period), modifiers: modifiers, action: .stop)

        Log.write("hotkeys: ⌃⌥P / ⌃⌥→ / ⌃⌥← / ⌃⌥. を登録した")
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
