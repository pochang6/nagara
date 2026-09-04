import AppKit

// 右クリック →「nagara で読む」。
//
// 画面を舐めるのではなく、選択されたところだけを受け取る。
// メニューバーやボタンのラベルが読み上げられないのは、あなたがそれを選択しないから。
final class ServicesProvider: NSObject {

    private let onText: (String) -> Void

    init(onText: @escaping (String) -> Void) {
        self.onText = onText
        super.init()
    }

    @objc func speakSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            error.pointee = "選択されたテキストがありません" as NSString
            return
        }
        Log.write("services: 選択テキストを受け取った (\(text.count)文字)")
        onText(text)
    }
}
