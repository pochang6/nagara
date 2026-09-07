import AppKit

enum ClipboardReader {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func read(from pasteboard: NSPasteboard) -> Result<String, Failure> {
        // 書式付きテキストだけを提供するアプリでも、コピーした文章を読めるようにする。
        var text = pasteboard.string(forType: .string)
        if text == nil,
           let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String],
           !strings.isEmpty {
            text = strings.joined(separator: "\n")
        }
        if text == nil, let data = pasteboard.data(forType: .rtf) {
            text = NSAttributedString(rtf: data, documentAttributes: nil)?.string
        }
        if let text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(Failure(message: "コピーした内容に読む文字がありません"))
            }
            return .success(text)
        }

        // nil は空と同義ではない。権限拒否や読み取り失敗を「空」と断定しない。
        if pasteboard.accessBehavior == .alwaysDeny {
            return .failure(Failure(message: "クリップボードを取得できません。システム設定で nagara のペースト許可を確認してください"))
        }
        let types = pasteboard.types ?? []
        if !types.isEmpty, !types.contains(.string), !types.contains(.rtf),
           !pasteboard.canReadObject(forClasses: [NSString.self], options: nil) {
            return .failure(Failure(message: "コピーした内容をテキストとして読めません。文章を選んで ⌘C を押してください"))
        }
        return .failure(Failure(message: "クリップボードから文章を取得できません。⌘C でコピーし直し、ペーストの許可が出たら許可してください"))
    }
}
